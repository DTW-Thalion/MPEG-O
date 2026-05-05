# `libttio_rans` — Native rANS Acceleration Library

> **Status:** required at runtime in v1.0.0. Set
> `TTIO_RANS_LIB_PATH` or place `libttio_rans.{so,dylib,jni}` on the
> loader search path. All v1.0 genomic-run write/read paths (codec ids
> 4-7 + 11-15) call into this library; without it, genomic codec
> dispatch raises an error at write time and rejects compressed
> channels at read time.

This document describes the native C library at `native/` that
provides SIMD-accelerated rANS encode/decode kernels plus the v2
codec C kernels (`ref_diff_v2`, `mate_info_v2`, `name_tok_v2`,
`fqzcomp_qual` V4). The library is consumed by:

- **Python** via `ctypes` (loader in
  `python/src/ttio/codecs/fqzcomp_nx16_z.py`).
- **Java** via JNI (`native/src/ttio_rans_jni.c` +
  `java/src/main/java/global/thalion/ttio/codecs/TtioRansNative.java`).
- **Objective-C** via direct `__has_include("ttio_rans.h")` linkage
  in `objc/Source/Codecs/TTIOFqzcompNx16Z.m`.

The library is **not** required for default operation — V1 streams
are produced and consumed by every language binding without it. A
file written under V1 by any language reads on every language
without `libttio_rans`.

---

## 1. Architecture

### 1.1 Public API surface (`native/include/ttio_rans.h`)

```c
/* Single-block encode/decode (no caller-managed pool). */
int ttio_rans_encode_block(
    const uint8_t  *symbols,
    const uint16_t *contexts,
    size_t          n_symbols,
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    uint8_t        *out,
    size_t         *out_len);

int ttio_rans_decode_block(
    const uint8_t  *compressed,
    size_t          comp_len,
    const uint16_t *contexts,
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    const uint32_t (*cum)[256],
    const uint8_t  (*dtab)[TTIO_RANS_T],
    uint8_t        *symbols,
    size_t          n_symbols);

/* Streaming context-resolver decode: caller supplies a callback to
 * compute each position's context, unblocking codecs whose context
 * depends on previously-decoded symbols (M94.Z context model). */
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
    void                       *user_data);

/* M94.Z decode with inline context derivation (Task #81, 2026-05-01).
 * Replaces the per-symbol callback round-trip of
 * ttio_rans_decode_block_streaming for the M94.Z codec — bakes the
 * (prev_q ring + position bucket + revcomp) → context formula
 * directly into native code, byte-for-byte against the Python and
 * Java references. */
typedef struct {
    uint32_t qbits;
    uint32_t pbits;
    uint32_t sloc;
} ttio_m94z_params;

int ttio_rans_decode_block_m94z(
    const uint8_t            *compressed,
    size_t                    comp_len,
    uint16_t                  n_contexts,
    const uint32_t          (*freq)[256],
    const uint32_t          (*cum)[256],
    const uint8_t           (*dtab)[TTIO_RANS_T],
    const ttio_m94z_params   *params,
    const uint16_t           *ctx_remap,    /* sparse->dense, len 1<<sloc */
    const uint32_t           *read_lengths,
    size_t                    n_reads,
    const uint8_t            *revcomp_flags,
    uint16_t                  pad_ctx_dense,
    uint8_t                  *symbols,
    size_t                    n_symbols);

/* Multi-block V2 wire format with thread-pool parallelism. */
ttio_rans_pool *ttio_rans_pool_create(int n_threads);
int ttio_rans_encode_mt(...);
int ttio_rans_decode_mt(...);
void ttio_rans_pool_destroy(ttio_rans_pool *pool);

/* Diagnostics. */
const char *ttio_rans_kernel_name(void);  /* "scalar" | "sse4.1" | "avx2" */

/* Decode-table helper. */
int ttio_rans_build_decode_table(
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    const uint32_t (*cum)[256],
    uint8_t        (*dtab)[TTIO_RANS_T]);
```

The constants pinning the rANS state machine match the M94.Z
reference exactly:

| Constant | Value | Notes |
|---|---|---|
| `TTIO_RANS_L` | `2^15` (`32768`) | Lower bound for rANS state. |
| `TTIO_RANS_B_BITS` | `16` | Renormalization base width (16-bit chunks). |
| `TTIO_RANS_T` | `2^12` (`4096`) | Frequency-table resolution. `T \| b·L` exactly (`T = 2^12 \| 2^31`), which is the byte-pairing invariant M94.Z relies on. |
| `TTIO_RANS_STREAMS` | `4` | 4-way interleaved rANS. |
| `TTIO_RANS_X_MAX_PREFACTOR` | `524288` | `(L >> T_BITS) << B_BITS`. |

### 1.2 Implementation files

| File | Role |
|---|---|
| `native/src/rans_core.c` | Decode-table builder, common helpers. |
| `native/src/rans_encode_scalar.c` | Reference scalar encode kernel. |
| `native/src/rans_decode_scalar.c` | Reference scalar decode kernel. |
| `native/src/rans_decode_streaming.c` | Streaming-context decoder (callback-driven). |
| `native/src/rans_decode_m94z.c` | M94.Z decoder with inline context derivation — eliminates the per-symbol callback round-trip in `decode_streaming` for the M94.Z codec specifically. |
| `native/src/rans_encode_sse41.c`, `..._avx2.c` | SIMD encode kernels — currently delegate to scalar with `-msse4.1` / `-mavx2` so gcc auto-vectorises. Hand-rolled `__m128i` prototypes were 55 % slower than auto-vec; documented as `TODO(Task 18)`. |
| `native/src/rans_decode_sse41.c`, `..._avx2.c` | Same for decode. |
| `native/src/dispatch.c` | Runtime cpuid detection + function-pointer dispatch. Selects AVX2 → SSE4.1 → scalar at library load via `__attribute__((constructor))`. |
| `native/src/threadpool.c` | Fixed-size pthread pool with submit/wait/destroy. Used by the V2 multi-block encoder/decoder. |
| `native/src/wire_format.c` | V2 multi-block container serialisation. |
| `native/src/ttio_rans_jni.c` | Java JNI bridge (built only when `TTIO_RANS_BUILD_JNI=ON`). |

### 1.3 Build

```bash
cd native
mkdir -p _build && cd _build
cmake ..
make -j$(nproc)
```

The CMake build supports three options:

| Option | Default | Purpose |
|---|---|---|
| `TTIO_RANS_BUILD_JNI` | `OFF` | Build `libttio_rans_jni.so` for Java JNI consumption. |
| `TTIO_RANS_ENABLE_TSAN` | `OFF` | Build a parallel `libttio_rans_tsan` + `test_thread_safety_tsan` target with `-fsanitize=thread`. |

Per-file SIMD flags are applied via
`set_source_files_properties(... PROPERTIES COMPILE_FLAGS "-msse4.1")` /
`-mavx2"`. The dispatch table is then resolved at library load time
based on the CPU's reported feature flags.

### 1.4 Test surface

`ctest` registers four suites (run in build dir):

| Test | Sub-tests | Coverage |
|---|---:|---|
| `roundtrip` | 17 | Scalar encode/decode with multi-context and edge-case inputs. |
| `thread_safety` | 5 | Concurrent encodes through a shared pool. TSAN target verifies under sanitiser. |
| `v2_format` | 7 | V2 multi-block container encode + decode + V1 backwards-compatibility decode. |
| `streaming` | 8 | Streaming-context decoder parity vs. regular decoder. |
| `m94z_decode` | 1 | M94.Z inline-context decoder parity vs. streaming-callback path on a 1000-symbol / 10-read input. |

30 sub-tests total, 0 warnings under `-Wall -Wextra -Wpedantic`.

---

## 2. Throughput

Measured on a 10 MiB synthetic Q20–Q40 quality stream, AVX2 host
(gcc 13, `-O3`, single thread):

| Kernel selected | Encode | Decode |
|---|---:|---:|
| `avx2` | ~510 MiB/s | ~605 MiB/s |
| `sse4.1` | ~440 MiB/s | ~520 MiB/s |
| `scalar` | ~340 MiB/s | ~410 MiB/s |

For comparison, the Cython M94.Z encoder runs at ~145 MiB/s on the
same machine. The native AVX2 path is **~3.5× faster than Cython at
the rANS layer**.

End-to-end M94.Z encode wall (chr22 lean, 1.77 M reads × 100 bp,
~145 MiB raw qualities) is *not* dominated by the rANS layer in
either path — the M94.Z context-model build pass and the HDF5
framework dominate. V2 native encode end-to-end is currently
slightly *slower* than V1 Cython because the per-symbol callback in
the streaming decoder swamps the C decode gain (chicken-and-egg
with the M94.Z context model derivation).

---

## 3. V2 dispatch

When a language binding has `libttio_rans` available AND the caller
opts in, the encoder writes M94.Z V2 streams (version byte = 2)
whose body is the raw `ttio_rans_encode_block` output. The decoder
detects the version byte:

* **V1 (default)** — pure-language decode (Cython / pure-Java /
  pure-ObjC) using the canonical four-substream layout.
* **V2** — pure-language decode through the M94.Z context model with
  a custom forward-walk parser of the libttio_rans body. Native
  decode is wired via `ttio_rans_decode_block_streaming` but is
  off by default (callback overhead exceeds the C decode gain;
  see §4).

Opt-in:

| Binding | Mechanism | Default |
|---|---|---|
| Python | `encode(qualities, ..., prefer_native=True)` or `TTIO_M94Z_USE_NATIVE=1` env | V1 |
| Java | `FqzcompNx16Z.encode(..., new EncodeOptions().preferNative(true))` or env var | V1 |
| ObjC | `[TTIOFqzcompNx16Z encodeWithQualities:... options:@{@"preferNative": @YES} error:&err]` or env var | V1 |

V1 streams round-trip identically across all three languages
without requiring `libttio_rans`. V2 streams require either
`libttio_rans` (for native encode) OR the pure-language V2 decoder
in `fqzcomp_nx16_z.py` / `FqzcompNx16Z.java` /
`TTIOFqzcompNx16Z.m` (added 2026-04-30).

---

## 4. Streaming-context API

The M94.Z context for position `i` depends on `q[0..i-1]` (the
prev_q ring), making the contexts vector unknown at decode time.
`ttio_rans_decode_block_streaming` accepts a caller-supplied
resolver:

```c
typedef uint16_t (*ttio_rans_context_resolver)(
    void *user_data,
    size_t i,
    uint8_t prev_sym
);
```

The decoder calls `resolver(user_data, i, prev_sym)` before
decoding each symbol; the caller maintains the prev_q ring inside
the callback. The streaming path is general and unblocks any
codec whose context depends on previously-decoded symbols.

Per-symbol callback overhead (Python `CFUNCTYPE`: ~6–8 µs/call;
JNI `CallIntMethod`: ~10–15 µs/call) dominates the C decode gain
in practice, so the streaming path is wired but **superseded by
the M94.Z inline-context decoder** for the only codec that needed
it. The streaming path is kept as infrastructure for future
context-models that are not amenable to a fixed C implementation.

### 4.1 M94.Z inline-context decoder (Task #81, 2026-05-01)

`ttio_rans_decode_block_m94z` implements the M94.Z context formula
directly in C, byte-for-byte against the
`ttio.codecs.fqzcomp_nx16_z` and
`global.thalion.ttio.codecs.FqzcompNx16Z` references. The forward
decode loop never leaves native code — no callback, no FFI
round-trip per symbol. The caller passes the read metadata
(`read_lengths[]`, `revcomp_flags[]`) and a sparse→dense context
remap table (`ctx_remap[]` of length `1 << sloc`); the function
synthesises the context for each position inline using the same
prev_q ring + position-bucket + revcomp logic as the
pure-language decoders.

Throughput: the C decode kernel itself runs at ~107 MiB/s on a
10 MB qualities block (vs ~96 MiB/s for the Cython M94.Z
decoder). End-to-end Python V2 decode is currently still
dominated by metadata-setup overhead in the wrapper (read-length
table decode, freq blob decompress) — closing that gap is a
follow-up. Java JNI and ObjC linkage to this entry point are
deferred; Python is the load-bearing decode path for V2 native.

Parity test: `native/tests/test_m94z_decode.c` round-trips a
1000-symbol / 10-read input through both the streaming-callback
path and the new inline-context path, asserting byte-equality.
Registered as ctest suite `m94z_decode`.

---

## 5. Discovery and loading

### 5.1 Python (ctypes)

`fqzcomp_nx16_z.py` searches in this order:

1. `$TTIO_RANS_LIB_PATH` — explicit file path or directory.
2. Bare `libttio_rans.so` / `libttio_rans.dylib` / `ttio_rans.dll`
   (`LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH` / Windows `PATH`).
3. `ctypes.util.find_library("ttio_rans")`.

If the library is unreachable, `_HAVE_NATIVE_LIB = False` and the
codec silently falls back to the Cython / pure-Python path. No
warning is logged — the V1 path is the supported default.

Introspection:

```python
from ttio.codecs.fqzcomp_nx16_z import get_backend_name
print(get_backend_name())  # "native-avx2" | "cython" | "pure-python"
```

### 5.2 Java (JNI)

`TtioRansNative` calls `System.loadLibrary("ttio_rans_jni")` in its
static initialiser. If the JNI shim isn't on `java.library.path`,
`isAvailable()` returns `false` and the codec falls back to
pure-Java.

Maven Surefire hard-codes `java.library.path` via the
`hdf5.native.path` property. To inject the libttio_rans build
directory:

```bash
mvn test -Dhdf5.native.path=/usr/lib/x86_64-linux-gnu/jni:/usr/lib/x86_64-linux-gnu/hdf5/serial:$HOME/TTI-O/native/_build
```

Introspection: `FqzcompNx16Z.getBackendName()` returns
`"native-<kernel>"` / `"pure-java"`.

### 5.3 Objective-C (direct linkage)

`objc/Source/GNUmakefile.preamble` and
`objc/Tests/GNUmakefile.preamble` conditionally add
`-I../../native/include`, `-L../../native/_build`, and
`-lttio_rans` when both `native/_build/libttio_rans.so` and
`native/include/ttio_rans.h` are present. The header is included
via `__has_include("ttio_rans.h")` so the build is graceful when
the native lib is absent.

Introspection: `[TTIOFqzcompNx16Z backendName]` returns
`@"native-<kernel>"` / `@"pure-objc"`.

---

## 6. Limitations and follow-ups

- **SIMD encode kernels** still delegate to scalar with auto-vec.
  Hand-rolled `__m128i` versions tested at 55 % slower than gcc 13's
  auto-vectoriser. AVX-512 `VPGATHERDD` may unblock further gains
  (deferred — not available on dev hardware).
- **V2 native decode** requires a streaming-context callback. With
  Python ctypes / Java JNI / ObjC blocks the per-symbol callback
  overhead exceeds the C decode gain. Moving M94.Z context
  derivation into C is the unlocking work.
- **Multi-block V2 wire format** at the libttio_rans layer is
  separate from the M94.Z V2 wire format (which uses single-block
  `ttio_rans_encode_block` output as its body). The multi-block
  container is exercised by `test_v2_format` but not yet wired into
  the M94.Z codec — follow-up.
- **No stream support for non-x86_64.** Dispatch is x86_64-only;
  arm64 falls through to scalar.

---

## 7. References

- Plan: `docs/superpowers/plans/2026-04-30-fqzcomp-acceleration.md`
- Spec: `docs/superpowers/specs/2026-04-30-fqzcomp-acceleration-design.md`
- Codec doc: `docs/codecs/fqzcomp_nx16_z.md` §2 V2 wire format.
- M94.Z spec: `docs/superpowers/specs/2026-04-29-m94z-cram-mimic-design.md`.
- Source (~3500 lines C, MIT-style internal license): `native/src/`.
