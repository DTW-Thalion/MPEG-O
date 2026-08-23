# TTI-O M94.Z — FQZCOMP_NX16_Z Codec (CRAM-Mimic)

> **Status:** shipped. Applies to genomic-`qualities` channels; codec
> id `12`, magic `M94Z`. All three reference implementations (Python,
> Objective-C, Java) produce byte-identical encoded streams.
>
> **v1.0 reset — current state.** Only the **V4** wire format (version
> byte `4`, CRAM 3.1 `fqzcomp_qual` port) is live. The native
> `libttio_rans` library is **required** for top-level encode/decode in
> all three languages — there is no pure-Python or Cython fallback. The
> earlier V1 (pure-language static rANS), V2 (native-body) and V3
> (adaptive Range Coder) formats were removed: their encoders/decoders
> are gone and `decode_with_metadata` rejects V1/V2/V3 blobs with a
> migration error. The V1/V2/V3 wire-format and algorithm sections below
> are retained as historical record; they no longer describe a path the
> current code can produce or read. See `python/src/ttio/codecs/`
> `fqzcomp_nx16_z.py` for the live V4-only surface.

This document specifies the FQZCOMP_NX16_Z codec used by TTI-O for
lossless quality-score compression in v1.0. It is a clean-room
implementation of CRAM 3.1's `rANS-Nx16` discipline (htscodecs master).

The combination of static-per-block freq tables, 16-bit renormalisation,
and a fixed power-of-two total `T = 4096` makes byte-pairing
mathematically exact (see §8 below for why the prior M94.X prototype
failed and how M94.Z's invariant fixes it). The codec compute on chr22
lean is ~4% of the full-pipeline wall-clock.

---

## 1. Historical note (V1–V3, removed in the v1.0 reset)

Earlier drafts of this codec shipped three now-removed wire formats:
**V1** (a pure-language static-per-block bit-pack rANS-Nx16 with a
build-then-emit freq-table pass), **V2** (a `libttio_rans` native
rANS body), and **V3** (an adaptive Range Coder body). They were
removed in the v1.0 reset: the V1/V2/V3 encoders and decoders are
gone, and `decode_with_metadata` now rejects any blob whose version
byte is 1, 2, or 3 with a migration error. The detailed V1–V3
algorithm, context-model, normalisation, wire-format, conformance-
fixture, and performance material that used to live here has been
removed; recover it from git history (pre-v1.0 revisions of this
file) if you need to inspect a legacy blob. The byte-pairing
rationale that motivated M94.Z's fixed `T = 4096` / 16-bit
renormalisation invariant is preserved in §8 below because the live
V4 path inherits the same numeric discipline.

Everything below describes the **live V4 wire format only**.

---

## 2. Wire format (codec id 12)

The only on-disk shape produced or read by the current code is the
**V4** format (magic `M94Z`, codec id `12`, version byte `4`):
a CRAM 3.1 `fqzcomp_qual` byte-compatible inner body wrapped by an
M94.Z outer header. The encoder is auto-tuning and byte-equal with
htscodecs on all 4 benchmark corpora. V4 is the default — and only —
format when `_HAVE_NATIVE_LIB` is true; the native `libttio_rans`
library is required (there is no pure-language fallback). Blobs
carrying the removed version bytes 1, 2, or 3 are rejected at decode
with a migration error.

All multi-byte integers little-endian.

### V4 (version byte = 4, CRAM 3.1 fqzcomp_qual port — Stage 2 / 2026-05-02)

V4 replaces V3's bit-pack adaptive context model with a CRAM 3.1
fqzcomp_qual byte-compatible port (clean-room from htscodecs SHA
`7dd27f4`, header-read-only — no source carried over). The outer M94.Z
header preserves V3's framing pattern; the inner body is a
CRAM-byte-compatible blob produced by `ttio_fqzcomp_qual_compress`
(an auto-tuning encoder that picks the smaller of 5 fixed presets per
block).

```
[Codec header]
  magic                : 4 bytes  "M94Z"
  version              : uint8    = 4
  flags                : uint8    (bit 0 = has_cram_body, MUST be 1;
                                   bits 4..5 = pad_count; rest reserved)
  num_qualities        : uint64   LE
  num_reads            : uint64   LE
  rlt_compressed_len   : uint32   LE   (= R)
  read_length_table    : R bytes  zlib(deflate(uint32[num_reads] LE))
  cram_body_len        : uint32   LE   (= C)
  cram_body            : C bytes  CRAM 3.1 fqzcomp_qual blob
```

Total = `30 + R + C` bytes. Header fixed prefix is 26 bytes (magic 4
+ version 1 + flags 1 + num_qualities 8 + num_reads 8 + R 4); the
4-byte `cram_body_len` lives at offset `26 + R`.

Distinguishing features of the V4 layout:
- `num_reads` is `uint64` (matches CRAM fqzcomp_qual's per-read
  metadata layout).
- There are no context-params, freq-tables, or sparse-ID fields —
  the CRAM body is self-describing (its own header carries the model
  strategy and per-context state).
- The body is a single contiguous CRAM blob (no lane-split, no
  separate state vectors).

V4 is the encoded format when `_HAVE_NATIVE_LIB` is true
(`libttio_rans` is loaded), which is required — there is no
pure-language fallback.

V4 byte-equality with htscodecs is guaranteed across all 4 benchmark
corpora (chr22 NA12878 100bp WGS, NA12878 WES, HG002 Illumina 2×250,
HG002 PacBio HiFi). See
`docs/benchmarks/2026-05-02-m94z-v4-stage2-results.md` for per-corpus
B/qual numbers and the encode-wall comparison.

### V4 in Java and Objective-C (Stage 3 / 2026-05-03)

V4 reaches feature parity across all 3 reference implementations:

| Language | V4 path | Native gate |
|---|---|---|
| Python | `ctypes` -> `libttio_rans` | `_HAVE_NATIVE_LIB` |
| Java | JNI -> `libttio_rans_jni` -> `libttio_rans` | `TtioRansNative.isAvailable()` |
| Objective-C | direct link -> `libttio_rans` | `TTIO_HAS_NATIVE_RANS` (always in this build) |

All three languages produce **byte-identical** V4 output across the 4
benchmark corpora: each one wraps the same deterministic
`ttio_m94z_v4_encode` C entry point, so divergence is impossible by
construction. The cross-language gates that guarantee this:

- `python/tests/integration/test_m94z_v4_byte_exact.py` — Python <-> htscodecs
- `java/.../FqzcompNx16ZV4ByteExactTest.java` — Java <-> Python
- `objc/Tests/TestM94ZV4ByteExact.m` — ObjC <-> Python
- `python/tests/integration/test_m94z_v4_cross_language.py` — full Python ↔ Java ↔ ObjC matrix (4 corpora x 3 languages)

### Flags byte layout

```
bit  0   : has_cram_body      (MUST be 1 in V4)
bits 1..3: reserved           (must be 0)
bits 4..5: pad_count          (0..3 zero bytes appended to last 4-way row)
bits 6..7: reserved           (must be 0)
```

### Read-length table

The per-read length array is encoded as a flat little-endian
`uint32[num_reads]` and zlib-deflated. The decoder inflates and
unpacks. The wire format does **not** carry `revcomp_flags`; they must
be supplied at decode time from sibling pipeline metadata.

---

## 3. Cross-language conformance contract

The Python implementation in
`python/src/ttio/codecs/fqzcomp_nx16_z.py` is the spec of record. The
V4 wire-level conformance is anchored to byte-equality with the
htscodecs CRAM 3.1 `fqzcomp_qual` reference across the four benchmark
corpora (chr22 NA12878 100bp WGS, NA12878 WES, HG002 Illumina 2×250,
HG002 PacBio HiFi). Each implementation encodes the same input and
verifies bytes-equal to the htscodecs output, and decodes back to the
original input. The cross-language gates are listed under "V4 in Java
and Objective-C" above.

> The earlier static-fixture conformance table (`m94z_a..h.bin`) and
> its md5 vectors described the removed V1 pure-language wire format;
> they were dropped in the v1.0 reset along with the V1/V2/V3 codecs.
> Recover them from git history if you need to inspect a legacy blob.

---

## 4. Performance

Per-language throughput numbers for the removed V1/V2 pure-language and
native-body paths have been dropped — they no longer describe code that
runs. V4 delegates entirely to `libttio_rans`'s CRAM 3.1
`fqzcomp_qual` core; for current encode/decode wall-clock figures see
`docs/benchmarks/2026-05-02-m94z-v4-stage2-results.md` and the
pipeline comparison in §4.2 below.

The C decode kernel itself runs at ~107 MiB/s on a 10 MB qualities
block. (Historical V1/V2 wrapper-overhead analysis was removed with
those paths; the figure is retained here only as a rough native-core
reference.) The C plumbing is proven
byte-exact via `native/tests/test_m94z_decode.c`. See
`docs/native-rans-library.md §4.1` for the full function signature
and parity test.

### 4.2 Pipeline wall-clock comparison (chr22 lean)

Full-pipeline TTI-O write/read on `chr22.lean.mapped.bam` (145 MiB,
1.77 M reads, single-threaded, all codecs enabled, M94.Z on
`qualities`):

| Codec stack                        | Encode wall   | Decode wall   |
|------------------------------------|--------------:|--------------:|
| M94 v1 (`FQZCOMP_NX16`, id 10)     |    **18 min** |   **24.6 min** |
| M94.Z (`FQZCOMP_NX16_Z`, id 12)    |   **48.77 s** |  **141.66 s** |
| CRAM 3.1 reference (htscodecs)     |    **3.03 s** |    **1.63 s** |

M94.Z is ~22x faster than M94 v1 at encode and ~10x faster at decode
for the full TTI-O pipeline on this corpus. Against CRAM 3.1's
hand-tuned reference the gap is ~16x at encode and ~87x at decode —
but the codec compute itself is now ~4% of the TTI-O pipeline wall;
the remaining ~95% is M93 REF_DIFF, the HDF5 framework, and the other
non-Cython codecs in the stack.

The codec was the bottleneck in v1.1.x (>90% of pipeline wall under
M94 v1); it is no longer. Further pipeline-wide work (M93 + other
codec acceleration) is tracked as M94.X / M94.Y / M95 / M96 follow-ups.

---

## 5. Public API

### Python

```python
from ttio.codecs.fqzcomp_nx16_z import encode, decode_with_metadata

encoded: bytes = encode(
    qualities=b"......",          # raw Phred quality bytes (ASCII +33)
    read_lengths=[100, 100, ...], # one per read
    revcomp_flags=[0, 1, 0, ...], # 0 = forward, 1 = reverse-complement
)

qualities, read_lengths, revcomp_flags_used = decode_with_metadata(
    encoded,
    revcomp_flags=[0, 1, 0, ...],   # MUST match encode-time flags
)
```

When the codec is selected via
`signal_codec_overrides["qualities"] = Compression.FQZCOMP_NX16_Z`
on a `WrittenGenomicRun`, the M86 pipeline derives `read_lengths`
from `run.lengths` and `revcomp_flags` from `run.flags[i] & 16`.

The module's `__all__` exports exactly `encode`,
`decode_with_metadata`, `get_backend_name`, `MAGIC`, and
`VERSION_V4_FQZCOMP`. (The V1-era diagnostic symbols `L`, `B_BITS`,
`B`, `T`, `T_BITS`, `NUM_STREAMS`, `X_MAX_PREFACTOR`, `m94z_context`,
`normalise_to_total`, `cumulative`, `ContextParams`, `CodecHeader`,
etc. were removed with the V1/V2/V3 pure-language paths in the v1.0
reset; the live codec is a thin wrapper over `libttio_rans`'s V4
core.)

### Objective-C

```objc
NSError *error = nil;

NSData *encoded = [TTIOFqzcompNx16Z
    encodeWithQualities:qualities
            readLengths:readLengths
           revcompFlags:revcompFlags
                  error:&error];

NSDictionary *result = [TTIOFqzcompNx16Z decodeData:encoded
                                        revcompFlags:revcompFlags
                                               error:&error];
NSData *qualities = result[@"qualities"];
NSArray<NSNumber *> *readLengths = result[@"readLengths"];

// Convenience: forward-only decode
NSDictionary *fwd = [TTIOFqzcompNx16Z decodeData:encoded error:&error];
```

### Java

```java
byte[] encoded = FqzcompNx16Z.encode(qualities, readLengths, revcompFlags);
FqzcompNx16Z.DecodeResult result = FqzcompNx16Z.decode(encoded, revcompFlags);
byte[] qualities = result.qualities();
int[]  readLengths = result.readLengths();
```

The `ContextParams` Java record is exposed as a public type for callers
that want to override defaults (none currently does in the M86 pipeline).

---

## 6. Binding decisions

The decisions below extend the M94 v1 series (§80d-§80h) and are
numbered §90a-§90e to keep the codec-spec § sequence contiguous.

| #     | Decision                                                                                                                                                                                                                                                                                              | Rationale                                                                                                                                                                                  |
|-------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| §90a  | M94.Z uses **static-per-block freq tables** (build pass + frozen encode pass). M94 v1's per-symbol adaptive `+16 / halve-with-floor-1` is NOT carried forward.                                                                                                                                       | Matches CRAM 3.1 `rANS-Nx16` proper; lifts the per-symbol normalisation cost out of the hot loop; ~15-25x speedup over M94 v1. Compression-ratio delta vs adaptive is small in practice (<5% on chr22 lean).            |
| §90b  | M94.Z gets a **new magic** `M94Z` and a **new codec id** `12`. M94 v1 (`FQZN`, codec id 10) stays in the codebase.                                                                                                                                                                                    | Backwards compatibility with M94 v1 fixtures and in-flight files is non-negotiable; new files written under the v1.5 default codec stack use M94.Z.                                       |
| §90c  | **16-bit renormalisation** (`B = 16`, `b = 2^16`). M94 v1 used 8-bit (`B = 8`).                                                                                                                                                                                                                       | 16-bit emit halves the per-step pop count in expectation and — together with §90d — makes byte-pairing mathematically guaranteed (see §8). M94.X failed at 8-bit due to byte-pairing slip. |
| §90d  | `T = 4096` **fixed** (12-bit shift). `T` divides `b * L = 2^31` exactly (`2^31 / 2^12 = 2^19`).                                                                                                                                                                                                        | `floor(b*L / T)` is integer-exact, eliminating the rounding term that broke M94.X. Variable-T was attempted as Path 2 in M94.X and is now retired.                                          |
| §90e  | **Bit-pack context model** (`sloc=14, qbits=12, pbits=2, dbits=0`). M94 v1 used SplitMix64.                                                                                                                                                                                                           | ~5 ops/symbol vs ~20 ops/symbol for SplitMix64; CRAM-style packing is reversible and collision-free by construction. Compression delta vs SplitMix64 is small; defer the `dtab` channel to M94.Z+. |

---

## 7. Limitations and follow-ups

- **No SIMD intrinsics yet.** M94.Z runs scalar 4-way interleaved
  rANS in all three languages. Adding `N = 32` SIMD-friendly mode
  (per CRAM `rANS_static4x16pr.c`'s `N32` flag) is tracked as
  M94.Z+. The current scalar path lands within ~2x of CRAM 3.1
  reference op-count on synthetic input; adding SIMD closes most of
  the remaining gap.
- **The codec is no longer the pipeline bottleneck.** End-to-end
  chr22 wall-clock is now ~96% non-codec work: M93 REF_DIFF
  encode/decode, the HDF5 read/write framework, and other non-Cython
  codecs in the v1.5 default stack. The remaining ~95% of pipeline
  wall is the natural target for M94.X / M94.Y / M95 / M96
  acceleration work.
- **Reverse-complement flags are not carried in the wire format.**
  The decoder must receive `revcomp_flags` from the M86 pipeline
  (typically `run.flags[i] & 16`). This is symmetric with M93
  REF_DIFF needing CIGAR/positions plumbing.

---

## 8. Why M94.Z

M94 v1 ships byte-exact across Python / ObjC / Java but spends ~600
ops/symbol because it (a) recomputes per-symbol rescaling of
`count[256]` to `M = 4096` on every step, (b) uses 8-bit
renormalisation, and (c) carries SplitMix64 in its inner loop.

The first attempt at fixing this was **M94.X Path 2**: variable-T
rANS with 8-bit renormalisation. It failed sporadically on chr22 lean
at `n_reads in {1150, 3300, 4000}` due to encoder-emit / decoder-pull
slip. Root cause: at `B = 8` the per-step `floor(b*L / T)` rounding
error scales with `T` (up to `~T = 2^20` for non-power-of-2 totals),
while the chunk size is only `b = 256`. A single boundary case can
shift the pop count by thousands of chunks.

**M94.Z's three-way fix:**

1. `T = 4096 = 2^12`, **power of 2 dividing `b * L = 2^31` exactly**.
   `floor(b*L / T)` is integer-exact (`2^31 / 2^12 = 2^19`,
   no remainder). `x_max` is exact.
2. `B = 16` (not 8). Even if `T` were not a perfect divisor (which it
   is), the per-step error `b*L mod T < T = 4096` would be much
   smaller than chunk size `b = 65536`. 16x margin.
3. `T` is **fixed per block**, not mutated per-symbol. Mutations
   between symbols would require re-quantising freqs, which is the
   complexity that broke M94.X. M94.Z's "adaptation" happens in the
   build pass only, before any encode.

The design spec §2 contains the formal byte-pairing proof.

---

References:

- Bonfield 2022, "htscodecs: bit-stream packing for CRAM",
  *Bioinformatics* 38(17):4187 — fqzcomp-Nx16 / rANS-Nx16 reference
  algorithm.
- CRAM 3.1 spec (samtools.github.io/hts-specs/CRAMv3.1.pdf) §3.5
  — context model and slice structure inspiration.
- Duda 2014, arXiv:1311.2540 — base rANS algorithm (M83 dependency).
- htscodecs source (read for understanding only — no verbatim copy):
  `rANS_word.h`, `rANS_static4x16pr.c`, `fqzcomp_qual.c`.

Per Binding Decision §66, all implementations are clean-room from
the published literature. No htslib / tools-Java / fqzcomp-reference
source consulted.
