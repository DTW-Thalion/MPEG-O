# FQZCOMP Acceleration — libttio_rans + Multi-Block Wire Format

**Status**: approved design, pending implementation plan  
**Author**: Claude (brainstorming subagent), 2026-04-30  
**Predecessor**: M94.Z (CRAM-mimic rANS-Nx16, codec id=12, wire magic `M94Z`)  
**Removes**: M94 v1 FQZCOMP_NX16 (codec id=10, wire magic `FQZN`) — no legacy
files exist  

---

## 0. Motivation

M94.Z (`FQZCOMP_NX16_Z`, codec id=12) already achieves correct byte-exact
encoding across Python/Java/ObjC using CRAM 3.1's rANS-Nx16 discipline: static
frequency tables, 16-bit renormalization, 4-way interleaved states. Current
throughput via Cython is ~50 MB/s — adequate for 10 MiB test payloads (~0.2s)
but not for production-scale 100 GB BAM file encodings, which would take
~34 minutes.

The original M94 v1 codec (`FQZCOMP_NX16`, codec id=10) uses adaptive per-symbol
frequency updates and SplitMix64 context hashing, making it inherently serial
at ~0.16 MB/s. It is 300× slower than M94.Z with no wire-format advantage. Since
no `.tio` files have been produced with this codec in the wild, it can be
removed entirely.

This design accelerates M94.Z to 2–5 GB/s effective throughput at 100 GB scale
by:

1. Porting the rANS hot loops to a C library (`libttio_rans`) with SIMD kernels
   (AVX2 / SSE4.1 / scalar fallback)
2. Adding multi-block wire format (V2) for thread-pool parallelism
3. Replacing O(log 256) decode binary search with O(1) precomputed decode tables
4. Removing FQZCOMP_NX16 entirely (~4500 lines across 3 languages)

Target: 100 GB BAM → TTI-O quality encoding in ~20–50 seconds.

---

## 1. Architecture

### 1.1 libttio_rans — Shared C Library

A standalone C library containing the rANS encode/decode hot loops. Built with
CMake. No runtime dependencies beyond pthreads.

**SIMD dispatch**: Runtime `cpuid` check selects the fastest available kernel:

```
AVX2 (256-bit)  →  SSE4.1 (128-bit)  →  scalar C fallback
```

Each variant lives in its own `.c` file compiled with the appropriate
`-mavx2` / `-msse4.1` flags. A thin dispatcher (function pointer table
initialized once at load time) routes calls to the best kernel.

**Thread pool**: A fixed-size `pthread` worker pool (default: `nproc` threads,
configurable) processes blocks in parallel. The pool is created once per
process and reused across calls.

### 1.2 Multi-Block Wire Format (M94Z V2)

The current M94Z V1 format encodes all reads as a single block. V2 splits the
input into fixed-size blocks (default 64K reads per block), each independently
encodable/decodable.

```
V2 Container Layout:
┌──────────────────────────────────────────┐
│ magic: "M94Z"  (4 bytes)                │
│ version: 2     (1 byte)                 │
│ block_count: N (varint)                 │
│ reads_per_block: 65536 (varint)         │
│ context_params: {qbits, pbits, dbits,   │
│                  sloc} (4 bytes)         │
├──────────────────────────────────────────┤
│ Block 0:                                │
│   compressed_size (4 bytes, LE)         │
│   [freq tables + rANS bitstream]        │
├──────────────────────────────────────────┤
│ Block 1:                                │
│   compressed_size (4 bytes, LE)         │
│   [freq tables + rANS bitstream]        │
├──────────────────────────────────────────┤
│ ...                                     │
├──────────────────────────────────────────┤
│ Block N-1:                              │
│   compressed_size (4 bytes, LE)         │
│   [freq tables + rANS bitstream]        │
└──────────────────────────────────────────┘
```

**Backwards compatibility**: V2 decoder reads V1 streams (single block, version
byte = 1). V1 decoders reject V2 streams with a clear error.

### 1.3 Decode Table Optimization

Current decode uses `bisect_right` (Python) or equivalent binary search to find
the symbol for a given rANS slot — O(log 256) per symbol per context.

Replace with a precomputed lookup table per context:

```c
uint8_t dtab[NUM_CONTEXTS][T];  // T = 4096
```

For each context `c` and slot value `s` in `[0, T)`, `dtab[c][s]` gives the
symbol directly — O(1) per decode step. The table is built once per block from
the frequency tables (~4 KB per context × number of active contexts).

---

## 2. FQZCOMP_NX16 Removal

FQZCOMP_NX16 (codec id=10) is removed entirely. No migration path is needed
because no `.tio` files with this codec exist in the wild.

### 2.1 Files to Delete

**Python** (~2200 lines):
- `python/src/ttio/codecs/fqzcomp_nx16.py` (1159 lines)
- `python/src/ttio/codecs/_fqzcomp_nx16/` (entire directory)
  - `_fqzcomp_nx16.pyx` (1158 lines)
  - Supporting files (`__init__.py`, etc.)

**Java** (~1100 lines):
- `java/src/main/java/.../codecs/FqzcompNx16.java` (1077 lines)

**Objective-C** (~1100 lines):
- `objc/Source/Codecs/TTIOFqzcompNx16.h`
- `objc/Source/Codecs/TTIOFqzcompNx16.m` (~1063 lines)

**Test fixtures** (~7 files):
- `python/tests/fixtures/codecs/fqzcomp_nx16_{a..h}.bin`

**Benchmark harnesses** (lines referencing `fqzcomp_nx16`):
- `tools/perf/profile_python_full.py`
- `tools/perf/ProfileHarnessFull.java`
- `tools/perf/profile_objc_full.m`
- `tools/perf/baseline.json`

### 2.2 Code Updates (NX16 → NX16_Z Default Swap)

**Python**:
- `python/src/ttio/genomic/_default_codecs.py`: Change
  `"qualities": Compression.FQZCOMP_NX16` → `Compression.FQZCOMP_NX16_Z`
- `python/src/ttio/enums.py`: Remove `FQZCOMP_NX16 = 10` enum member
- `python/src/ttio/genomic_run.py`: Remove codec_id=10 decode branch

**Java**:
- `java/src/main/java/.../SpectralDataset.java` line ~1108: Change
  `qualCodec = Enums.Compression.FQZCOMP_NX16` → `FQZCOMP_NX16_Z`
- `java/src/main/java/.../Enums.java`: Remove `FQZCOMP_NX16(10)` enum member
- `java/src/main/java/.../GenomicRun.java`: Remove codec_id=10 decode branch

**Objective-C**:
- `objc/Source/TTIOSpectralDataset.m`: Change default quality codec to NX16_Z
- `objc/Source/TTIOEnums.h`: Remove `TTIOCompressionFqzcompNx16 = 10`
- `objc/Source/TTIOGenomicRun.m`: Remove codec_id=10 decode branch

---

## 3. C Library API

```c
#include <stdint.h>
#include <stddef.h>

/* ── Constants ──────────────────────────────────────────────────────── */

#define TTIO_RANS_L       (1u << 15)    /* 32768  — state lower bound   */
#define TTIO_RANS_B_BITS  16            /* 16-bit renorm chunks         */
#define TTIO_RANS_B       (1u << 16)    /* 65536                        */
#define TTIO_RANS_T       (1u << 12)    /* 4096   — freq table total    */
#define TTIO_RANS_STREAMS 4             /* interleaved state count      */

/* ── Error codes ────────────────────────────────────────────────────── */

#define TTIO_RANS_OK           0
#define TTIO_RANS_ERR_PARAM   -1
#define TTIO_RANS_ERR_ALLOC   -2
#define TTIO_RANS_ERR_CORRUPT -3

/* ── Opaque handle for thread pool ──────────────────────────────────── */

typedef struct ttio_rans_pool ttio_rans_pool;

/* ── Single-block API (used internally and by single-threaded callers) */

int ttio_rans_encode_block(
    const uint8_t  *symbols,       /* input symbol array                */
    const uint16_t *contexts,      /* per-symbol context ids            */
    size_t          n_symbols,     /* symbol count                      */
    uint16_t        n_contexts,    /* max context id + 1                */
    const uint32_t (*freq)[256],   /* freq[ctx][sym], sum per ctx = T   */
    uint8_t        *out,           /* output buffer (caller-allocated)  */
    size_t         *out_len        /* in: buffer size, out: bytes used  */
);

int ttio_rans_decode_block(
    const uint8_t  *compressed,    /* input compressed bytes            */
    size_t          comp_len,      /* compressed length                 */
    uint16_t        n_contexts,    /* max context id + 1                */
    const uint32_t (*freq)[256],   /* freq[ctx][sym], sum per ctx = T   */
    const uint32_t (*cum)[256],    /* cum[ctx][sym]  cumulative freqs   */
    uint8_t        *symbols,       /* output buffer (caller-allocated)  */
    size_t          n_symbols      /* expected symbol count             */
);

/* ── Multi-block API (thread pool) ──────────────────────────────────── */

ttio_rans_pool *ttio_rans_pool_create(int n_threads);
    /* n_threads <= 0 → use nproc */

int ttio_rans_encode_mt(
    ttio_rans_pool *pool,
    const uint8_t  *symbols,
    const uint16_t *contexts,
    size_t          n_symbols,
    uint16_t        n_contexts,
    size_t          reads_per_block, /* 0 → default 65536             */
    const size_t   *read_lengths,   /* per-read lengths for blocking  */
    size_t          n_reads,
    uint8_t        *out,
    size_t         *out_len
);

int ttio_rans_decode_mt(
    ttio_rans_pool *pool,
    const uint8_t  *compressed,
    size_t          comp_len,
    uint8_t        *symbols,
    size_t         *n_symbols       /* in: buffer size, out: decoded   */
);

void ttio_rans_pool_destroy(ttio_rans_pool *pool);
```

The frequency table construction and context computation remain in the
calling language (Python/Java/ObjC). Only the rANS encode/decode hot loops
and thread management are in C.

---

## 4. Language Integration

### 4.1 Python — ctypes FFI

```python
import ctypes

_lib = None  # lazy-loaded

def _load_native():
    global _lib
    if _lib is not None:
        return _lib
    for name in ("libttio_rans.so", "libttio_rans.dylib", "ttio_rans.dll"):
        try:
            _lib = ctypes.CDLL(name)
            return _lib
        except OSError:
            continue
    return None
```

Three-tier fallback in `fqzcomp_nx16_z.py`:

```python
_HAVE_NATIVE_LIB = _load_native() is not None
_HAVE_C_EXTENSION = ...  # existing Cython check

def _encode_rans_block(...):
    if _HAVE_NATIVE_LIB:
        return _encode_via_native(...)
    if _HAVE_C_EXTENSION:
        return _encode_via_cython(...)
    return _encode_pure_python(...)
```

### 4.2 Java — JNI

```java
public class TtioRansNative {
    static {
        try {
            System.loadLibrary("ttio_rans_jni");
        } catch (UnsatisfiedLinkError e) {
            // fall back to pure Java
        }
    }

    public static native int encodeBlock(
        byte[] symbols, short[] contexts, int nContexts,
        int[][] freq, byte[] out, int[] outLen);

    public static native int decodeBlock(
        byte[] compressed, int nContexts,
        int[][] freq, int[][] cum,
        byte[] symbols, int nSymbols);
}
```

A JNI wrapper (`ttio_rans_jni.c`) bridges Java arrays to the C API.
CMake builds the JNI shared library as an optional target
(`-DTTIO_RANS_BUILD_JNI=ON`).

### 4.3 Objective-C — Direct C Linkage

```objc
// TTIOFqzcompNx16Z.m — direct #include, no FFI overhead
#include "ttio_rans.h"

- (NSData *)encodeQualities:(NSArray<NSData *> *)qualities
                readLengths:(NSArray<NSNumber *> *)readLengths
               revcompFlags:(NSArray<NSNumber *> *)revcompFlags {
    // ... context computation in ObjC ...
    ttio_rans_pool *pool = ttio_rans_pool_create(0);
    int rc = ttio_rans_encode_mt(pool, syms, ctxs, n, nCtx,
                                  0, lens, nReads, out, &outLen);
    ttio_rans_pool_destroy(pool);
    // ...
}
```

Since ObjC is a strict superset of C, `libttio_rans` links directly —
no JNI wrapper or ctypes bridge needed.

---

## 5. Build System

### 5.1 CMake Layout

```
native/
├── CMakeLists.txt
├── include/
│   └── ttio_rans.h
├── src/
│   ├── rans_core.c          # shared helpers, freq table builder
│   ├── rans_encode_scalar.c # scalar encode kernel
│   ├── rans_encode_sse41.c  # SSE4.1 encode kernel (-msse4.1)
│   ├── rans_encode_avx2.c   # AVX2 encode kernel (-mavx2)
│   ├── rans_decode_scalar.c # scalar decode kernel + dtab
│   ├── rans_decode_sse41.c  # SSE4.1 decode kernel
│   ├── rans_decode_avx2.c   # AVX2 decode kernel
│   ├── dispatch.c           # cpuid + function pointer init
│   ├── threadpool.c         # pthread worker pool
│   └── ttio_rans_jni.c      # JNI bridge (optional)
├── tests/
│   ├── test_roundtrip.c
│   ├── test_thread_safety.c
│   └── test_conformance.c
└── bench/
    └── bench_throughput.c
```

### 5.2 Per-File SIMD Compile Flags

```cmake
add_library(ttio_rans SHARED
    src/rans_core.c
    src/rans_encode_scalar.c
    src/rans_decode_scalar.c
    src/dispatch.c
    src/threadpool.c
)

# SIMD variants — compiled with target-specific flags
if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64")
    target_sources(ttio_rans PRIVATE
        src/rans_encode_sse41.c
        src/rans_decode_sse41.c
        src/rans_encode_avx2.c
        src/rans_decode_avx2.c
    )
    set_source_files_properties(
        src/rans_encode_sse41.c src/rans_decode_sse41.c
        PROPERTIES COMPILE_FLAGS "-msse4.1"
    )
    set_source_files_properties(
        src/rans_encode_avx2.c src/rans_decode_avx2.c
        PROPERTIES COMPILE_FLAGS "-mavx2"
    )
endif()

# Optional JNI target
option(TTIO_RANS_BUILD_JNI "Build JNI wrapper" OFF)
if(TTIO_RANS_BUILD_JNI)
    find_package(JNI REQUIRED)
    add_library(ttio_rans_jni SHARED src/ttio_rans_jni.c)
    target_link_libraries(ttio_rans_jni ttio_rans JNI::JNI)
endif()
```

### 5.3 Platform Notes

- **Linux (WSL, CI)**: GCC/Clang, pthreads, standard CMake build
- **macOS**: Clang, pthreads; Apple Silicon builds scalar + NEON (future)
- **Windows (MSYS2)**: GCC via MSYS2 ucrt64, pthreads-w32

---

## 6. Testing Strategy

### 6.1 C-Level Tests

- **Round-trip**: Random quality strings of varying lengths and distributions.
  Encode → decode, verify byte-exact match.
- **Thread safety**: Concurrent encode/decode from multiple threads sharing
  the same pool. Verify no data races (run under ThreadSanitizer).
- **Edge cases**: Empty input, single symbol, single read, max-context-id,
  block boundary alignment.

### 6.2 Cross-Language Conformance

The existing M94.Z conformance fixtures (`fqzcomp_nx16_z_*.bin`) verify that
Python, Java, and ObjC produce byte-identical compressed output for the same
input. With `libttio_rans`:

- Native-accelerated encode in each language must produce the same bytes as
  the pure-Python reference.
- V2 (multi-block) output must decode correctly from any language.
- V1 streams must still decode correctly through the V2 decoder path.

### 6.3 Performance Gate

Extend `test_m95_throughput.py` (or add a companion `test_m94z_throughput.py`)
with a hard floor:

- **Native library loaded**: encode ≥ 200 MB/s, decode ≥ 200 MB/s (single-thread)
- **Multi-threaded** (4+ cores): encode ≥ 1 GB/s effective
- **Cython fallback**: encode ≥ 30 MB/s (existing baseline)
- **Pure Python fallback**: no floor (correctness only)

### 6.4 Benchmark Integration

Update `tools/perf/` harnesses to:
- Remove all `fqzcomp_nx16` entries
- Report `fqzcomp_nx16_z` throughput with native/Cython/pure annotation
- Add multi-threaded throughput metrics

---

## 7. Scope Boundaries

### In Scope
- `libttio_rans` C library with SIMD encode/decode kernels
- pthread thread pool for multi-block parallelism
- Multi-block V2 wire format (backwards-compatible with V1)
- O(1) decode tables
- Runtime SIMD dispatch (AVX2 → SSE4.1 → scalar)
- Python ctypes, Java JNI, ObjC direct linkage
- Complete FQZCOMP_NX16 removal (all 3 languages)
- Default codec swap (NX16 → NX16_Z)
- Updated tests, fixtures, and benchmarks

### Out of Scope
- ARM NEON kernels (future — Apple Silicon, Graviton)
- GPU / CUDA acceleration (serial rANS dependency chain makes this impractical)
- Adaptive frequency models (the static-per-block M94.Z model is retained)
- Changes to context computation (qbits/pbits/dbits/sloc stay in Python/Java/ObjC)
- Changes to the frequency table normalization algorithm
- Compression ratio improvements (this is a speed project, not a ratio project)
