/*
 * dispatch.c — Runtime SIMD dispatch for TTI-O rANS kernels.
 *
 * At library load time a constructor probes cpuid for AVX2 / SSE4.1 and
 * sets two function pointers (encode_impl, decode_impl).  The public
 * entry points `ttio_rans_encode_block` and `ttio_rans_decode_block`
 * are thin wrappers that call those pointers.
 *
 * Selection priority: AVX2 → SSE4.1 → scalar.
 *
 * Copyright (c) 2026 Thalion Global.  All rights reserved.
 */

#include "ttio_rans.h"
#include "rans_internal.h"

#include <stddef.h>

#if defined(__x86_64__) || defined(_M_X64) || defined(__amd64__)
#  define TTIO_RANS_X86 1
#else
#  define TTIO_RANS_X86 0
#endif

#if TTIO_RANS_X86
#  if defined(_MSC_VER)
#    include <intrin.h>
#  else
#    include <cpuid.h>
#  endif
#endif

/* ── kernel name string set by the resolver ────────────────────────── */

static const char *g_kernel_name = "scalar";

const char *ttio_rans_kernel_name(void)
{
    return g_kernel_name;
}

/* ── function pointers (initialised by constructor / lazy fallback) ── */

static ttio_rans_encode_fn g_encode_impl = NULL;
static ttio_rans_decode_fn g_decode_impl = NULL;

/* ── cpuid feature detection (x86-64 only) ─────────────────────────── */

#if TTIO_RANS_X86

/* Result bits we care about. */
typedef struct {
    int has_sse41;
    int has_avx;     /* required for OS XSAVE checks below */
    int has_osxsave;
    int has_avx2;
} ttio_x86_features;

#if defined(_MSC_VER)
static void ttio_cpuid(int leaf, int subleaf, unsigned int regs[4])
{
    __cpuidex((int *)regs, leaf, subleaf);
}
static unsigned long long ttio_xgetbv(void)
{
    return _xgetbv(0);
}
#else
static void ttio_cpuid(int leaf, int subleaf, unsigned int regs[4])
{
    __cpuid_count(leaf, subleaf, regs[0], regs[1], regs[2], regs[3]);
}
static unsigned long long ttio_xgetbv(void)
{
    /* xgetbv with ECX=0 */
    unsigned int eax, edx;
    __asm__ volatile (".byte 0x0f, 0x01, 0xd0"
                       : "=a"(eax), "=d"(edx) : "c"(0));
    return ((unsigned long long)edx << 32) | eax;
}
#endif

static void ttio_detect_features(ttio_x86_features *f)
{
    unsigned int regs[4] = {0,0,0,0};
    f->has_sse41 = 0;
    f->has_avx = 0;
    f->has_osxsave = 0;
    f->has_avx2 = 0;

    /* Highest standard leaf */
    ttio_cpuid(0, 0, regs);
    unsigned int max_leaf = regs[0];
    if (max_leaf < 1) return;

    /* Leaf 1: ECX bit 19 = SSE4.1, bit 27 = OSXSAVE, bit 28 = AVX */
    ttio_cpuid(1, 0, regs);
    f->has_sse41   = (regs[2] & (1u << 19)) != 0;
    f->has_osxsave = (regs[2] & (1u << 27)) != 0;
    f->has_avx     = (regs[2] & (1u << 28)) != 0;

    /* OS must have enabled XMM (bit 1) and YMM (bit 2) state save. */
    int os_avx_ok = 0;
    if (f->has_osxsave && f->has_avx) {
        unsigned long long xcr0 = ttio_xgetbv();
        os_avx_ok = ((xcr0 & 0x6) == 0x6);
    }

    /* Leaf 7, sub-leaf 0: EBX bit 5 = AVX2 */
    if (max_leaf >= 7) {
        ttio_cpuid(7, 0, regs);
        if (os_avx_ok && (regs[1] & (1u << 5)))
            f->has_avx2 = 1;
    }
}

#endif /* TTIO_RANS_X86 */

/* ── resolver ──────────────────────────────────────────────────────── */

static void ttio_rans_resolve(void)
{
    /* Default: scalar. */
    g_encode_impl = _ttio_rans_encode_block_scalar;
    g_decode_impl = _ttio_rans_decode_block_scalar;
    g_kernel_name = "scalar";

#if TTIO_RANS_X86
    ttio_x86_features feats;
    ttio_detect_features(&feats);

    if (feats.has_avx2) {
        g_encode_impl = _ttio_rans_encode_block_avx2;
        g_decode_impl = _ttio_rans_decode_block_avx2;
        g_kernel_name = "avx2";
    } else if (feats.has_sse41) {
        g_encode_impl = _ttio_rans_encode_block_sse41;
        g_decode_impl = _ttio_rans_decode_block_sse41;
        g_kernel_name = "sse4.1";
    }
#endif
}

/* ── library-load constructor ──────────────────────────────────────── */

#if defined(__GNUC__) || defined(__clang__)
__attribute__((constructor))
static void ttio_rans_ctor(void)
{
    ttio_rans_resolve();
}
#elif defined(_MSC_VER)
/* MSVC: use a CRT init slot.  Falls back to lazy init in wrappers. */
#  pragma section(".CRT$XCU", read)
static void __cdecl ttio_rans_ctor(void) { ttio_rans_resolve(); }
__declspec(allocate(".CRT$XCU")) void (__cdecl *ttio_rans_ctor_)(void) = ttio_rans_ctor;
#endif

/* ── public API wrappers ───────────────────────────────────────────── */

/* Lazy-init guard for environments where the constructor did not fire
 * (static linkage on some toolchains).  Cheap branch in the wrapper. */
static inline void ttio_rans_ensure_resolved(void)
{
    if (g_encode_impl == NULL || g_decode_impl == NULL)
        ttio_rans_resolve();
}

int ttio_rans_encode_block(
    const uint8_t  *symbols,
    const uint16_t *contexts,
    size_t          n_symbols,
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    uint8_t        *out,
    size_t         *out_len)
{
    ttio_rans_ensure_resolved();
    return g_encode_impl(symbols, contexts, n_symbols, n_contexts, freq, out, out_len);
}

int ttio_rans_decode_block(
    const uint8_t  *compressed,
    size_t          comp_len,
    const uint16_t *contexts,
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    const uint32_t (*cum)[256],
    const uint8_t  (*dtab)[TTIO_RANS_T],
    uint8_t        *symbols,
    size_t          n_symbols)
{
    ttio_rans_ensure_resolved();
    return g_decode_impl(compressed, comp_len, contexts, n_contexts,
                         freq, cum, dtab, symbols, n_symbols);
}
