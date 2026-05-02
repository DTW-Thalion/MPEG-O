#ifndef TTIO_RANS_H
#define TTIO_RANS_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TTIO_RANS_L       (1u << 15)
#define TTIO_RANS_B_BITS  16
#define TTIO_RANS_B       (1u << 16)
#define TTIO_RANS_B_MASK  (TTIO_RANS_B - 1)
#define TTIO_RANS_T       (1u << 12)
#define TTIO_RANS_T_BITS  12
#define TTIO_RANS_T_MASK  (TTIO_RANS_T - 1)
#define TTIO_RANS_STREAMS 4
#define TTIO_RANS_X_MAX_PREFACTOR  ((TTIO_RANS_L >> TTIO_RANS_T_BITS) << TTIO_RANS_B_BITS)

#define TTIO_RANS_OK           0
#define TTIO_RANS_ERR_PARAM   -1
#define TTIO_RANS_ERR_ALLOC   -2
#define TTIO_RANS_ERR_CORRUPT -3

typedef struct ttio_rans_pool ttio_rans_pool;

int ttio_rans_encode_block(
    const uint8_t  *symbols,
    const uint16_t *contexts,
    size_t          n_symbols,
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    uint8_t        *out,
    size_t         *out_len
);

int ttio_rans_decode_block(
    const uint8_t  *compressed,
    size_t          comp_len,
    const uint16_t *contexts,
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    const uint32_t (*cum)[256],
    const uint8_t  (*dtab)[TTIO_RANS_T],
    uint8_t        *symbols,
    size_t          n_symbols
);

/*
 * Caller-provided context resolver.
 *
 * Called before decoding each symbol.  Receives:
 *   user_data : opaque pointer passed at decode time
 *   i         : current symbol index (0-based, in range [0, n_symbols))
 *   prev_sym  : the symbol just decoded (or 0 for i==0)
 * Returns the context ID for position i.
 *
 * Must be deterministic and side-effect free except for the caller's
 * own bookkeeping.  Must not return a context >= n_contexts; doing so
 * causes ttio_rans_decode_block_streaming to return TTIO_RANS_ERR_PARAM.
 */
typedef uint16_t (*ttio_rans_context_resolver)(
    void    *user_data,
    size_t   i,
    uint8_t  prev_sym
);

/*
 * Decode a block with on-the-fly context derivation.
 *
 * Same compressed-byte layout as ttio_rans_decode_block.  Calls
 * `resolver(user_data, i, prev_sym)` to obtain the context for each
 * position before decoding it.  Intended for codecs whose context
 * depends on previously decoded symbols (e.g. M94.Z order-1 cascades),
 * where the contexts[] array is unavailable up front.
 *
 * Note: the streaming decoder is scalar-only — it is bottlenecked by
 * the per-symbol callback, so SIMD acceleration would not help.
 */
int ttio_rans_decode_block_streaming(
    const uint8_t              *compressed,
    size_t                      comp_len,
    uint16_t                    n_contexts,
    const uint32_t            (*freq)[256],
    const uint32_t            (*cum)[256],
    const uint8_t             (*dtab)[TTIO_RANS_T],
    uint8_t                    *symbols,
    size_t                      n_symbols,
    ttio_rans_context_resolver  resolver,
    void                       *user_data
);

/*
 * M94.Z context-derivation parameters — mirrors the Python
 * ``ContextParams`` and Java ``ContextParams`` records used by the
 * pure-language reference implementations.  Defaults are
 * qbits=12, pbits=2, sloc=14 (see DEFAULT_QBITS / DEFAULT_PBITS /
 * DEFAULT_SLOC in fqzcomp_nx16_z.py and FqzcompNx16Z.java).
 */
typedef struct {
    uint32_t qbits;
    uint32_t pbits;
    uint32_t sloc;
} ttio_m94z_params;

/*
 * Decode a V2 block whose contexts follow the M94.Z scheme, with the
 * context derivation done inline in C.
 *
 * Replaces the per-symbol cross-language callback path of
 * `ttio_rans_decode_block_streaming` for the M94.Z codec — the JNI/
 * ctypes/objc round-trip per symbol made that approach slower than
 * the pure-language decoder.  By baking the (prev_q ring + position
 * bucket + revcomp) → context formula directly into C, the entire
 * decode loop runs without leaving native code.
 *
 * Inputs:
 *   compressed / comp_len  — same V2 byte layout as
 *                            `ttio_rans_decode_block`
 *   n_contexts             — number of dense contexts in freq/cum/dtab
 *   freq / cum / dtab      — per-DENSE-context frequency tables
 *   params                 — qbits / pbits / sloc (CRAM-Nx16 discipline)
 *   ctx_remap              — optional sparse→dense map of length
 *                            `1u << params->sloc`.  NULL means identity
 *                            (each sparse ctx == its dense index).  Any
 *                            sparse ctx not present in the active set
 *                            should map to `pad_ctx_dense` (typically 0).
 *   read_lengths           — uint32 lengths of each read, total ==
 *                            n_symbols
 *   n_reads                — number of entries in read_lengths /
 *                            revcomp_flags
 *   revcomp_flags          — 0/1 reverse-complement flag per read
 *   pad_ctx_dense          — dense ctx ID assigned to padding positions
 *                            (i >= n_symbols) and any sparse->dense miss
 *
 * Outputs:
 *   symbols  — decoded bytes, length n_symbols
 *
 * Returns TTIO_RANS_OK on success.
 */
int ttio_rans_decode_block_m94z(
    const uint8_t            *compressed,
    size_t                    comp_len,
    uint16_t                  n_contexts,
    const uint32_t          (*freq)[256],
    const uint32_t          (*cum)[256],
    const uint8_t           (*dtab)[TTIO_RANS_T],
    const ttio_m94z_params   *params,
    const uint16_t           *ctx_remap,
    const uint32_t           *read_lengths,
    size_t                    n_reads,
    const uint8_t            *revcomp_flags,
    uint16_t                  pad_ctx_dense,
    uint8_t                  *symbols,
    size_t                    n_symbols
);

int ttio_rans_build_decode_table(
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    const uint32_t (*cum)[256],
    uint8_t        (*dtab)[TTIO_RANS_T]
);

/*
 * L2 (Task #82 Phase B.2, 2026-05-01): adaptive M94.Z (CRAM-mimic).
 *
 * Per-symbol adaptive freq updates: count[sym] += STEP, halve when
 * T > T_max - STEP. T_max = 65519, STEP = 16. Encoder maintains
 * the freq tables internally; decoder rebuilds them via the same
 * update rules. Wire format omits the freq-tables sidecar.
 *
 * See docs/superpowers/specs/2026-05-01-l2-m94z-adaptive-design.md
 * for the byte-pairing proof and wire format spec.
 */

#define TTIO_RANS_ADAPTIVE_STEP     16u
#define TTIO_RANS_ADAPTIVE_T_MAX    65519u

int ttio_rans_encode_block_adaptive(
    const uint8_t  *symbols,         /* n_symbols quality bytes      */
    const uint16_t *contexts,        /* n_symbols dense ctx indices  */
    size_t          n_symbols,
    uint16_t        n_contexts,      /* dense context count          */
    uint16_t        max_sym,         /* active range [0, max_sym)    */
    uint8_t        *out,             /* output buffer                */
    size_t         *out_len);        /* in: cap; out: actual         */

int ttio_rans_decode_block_adaptive_m94z(
    const uint8_t           *compressed,
    size_t                   comp_len,
    uint16_t                 n_contexts,
    uint16_t                 max_sym,
    const ttio_m94z_params  *params,
    const uint16_t          *ctx_remap,        /* len 1<<sloc        */
    const uint32_t          *read_lengths,
    size_t                   n_reads,
    const uint8_t           *revcomp_flags,
    uint16_t                 pad_ctx_dense,
    uint8_t                 *symbols,
    size_t                   n_symbols);

ttio_rans_pool *ttio_rans_pool_create(int n_threads);

int ttio_rans_encode_mt(
    ttio_rans_pool *pool,
    const uint8_t  *symbols,
    const uint16_t *contexts,
    size_t          n_symbols,
    uint16_t        n_contexts,
    size_t          reads_per_block,
    const size_t   *read_lengths,
    size_t          n_reads,
    uint8_t        *out,
    size_t         *out_len
);

int ttio_rans_decode_mt(
    ttio_rans_pool *pool,
    const uint8_t  *compressed,
    size_t          comp_len,
    uint8_t        *symbols,
    size_t         *n_symbols
);

void ttio_rans_pool_destroy(ttio_rans_pool *pool);

/* Diagnostic: name of the kernel selected at library-load time by cpuid
 * dispatch.  Returns a pointer to a static string — one of
 * "scalar", "sse4.1", "avx2".  Never returns NULL. */
const char *ttio_rans_kernel_name(void);

/* M94.Z V4: CRAM 3.1 fqzcomp port. See native/src/m94z_v4_wire.h
 * + native/src/fqzcomp_qual.h for details. The V4 outer wire format
 * wraps a CRAM-byte-compatible fqzcomp body with an M94.Z header
 * (magic "M94Z", version=4) so codec layers can dispatch on version.
 *
 * Encode:
 *   qual_in        — n_qualities bytes (Phred-33 ASCII)
 *   read_lengths   — n_reads uint32 (sum must equal n_qualities)
 *   flags          — n_reads bytes (bit 4 = SAM_REVERSE)
 *   strategy_hint  — -1 = auto-tune, 0..4 = preset
 *   pad_count      — 0..3 (V3 pad-count convention, packed in flags)
 *   out, *out_len  — caller-owned buffer + capacity-in/length-out
 *
 * Decode:
 *   read_lengths   — caller-allocated, n_reads entries; populated
 *                    from the V4 header's deflated RLT
 *   flags          — n_reads bytes (must match those used at encode)
 *   out_qual       — caller-owned, n_qualities bytes
 */
int ttio_m94z_v4_encode(
    const uint8_t  *qual_in,
    size_t          n_qualities,
    const uint32_t *read_lengths,
    size_t          n_reads,
    const uint8_t  *flags,
    int             strategy_hint,
    uint8_t         pad_count,
    uint8_t        *out,
    size_t         *out_len);

int ttio_m94z_v4_decode(
    const uint8_t  *in,
    size_t          in_len,
    uint32_t       *read_lengths,
    size_t          n_reads,
    const uint8_t  *flags,
    uint8_t        *out_qual,
    size_t          n_qualities);

#ifdef __cplusplus
}
#endif

#endif /* TTIO_RANS_H */
