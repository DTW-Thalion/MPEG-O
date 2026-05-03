# TTI-O M94.Z — FQZCOMP_NX16_Z Codec (CRAM-Mimic)

> **Status:** shipping in v1.2.0 (M94.Z). Reference implementation in
> Python (Cython-accelerated), normative implementation in
> Objective-C, parity implementation in Java. All three produce
> byte-identical encoded streams for the seven canonical conformance
> vectors. Applies to genomic-`qualities` channels; codec id `12`.

This document specifies the FQZCOMP_NX16_Z codec used by TTI-O for
lossless quality-score compression starting with v1.2.0. It is a
clean-room implementation of CRAM 3.1's `rANS-Nx16` discipline (htscodecs
master), built to the design spec at
`docs/superpowers/specs/2026-04-29-m94z-cram-mimic-design.md`.

M94.Z runs alongside M94 v1 (`FQZCOMP_NX16`, codec id `10`); both codecs
are kept in the codebase. M94 v1 fixtures decode unchanged; new files
written under the v1.5 default codec stack use M94.Z (id `12`) on the
`qualities` channel. The two codecs share neither magic nor wire format.

The combination of static-per-block freq tables, 16-bit renormalisation,
and a fixed power-of-two total `T = 4096` makes byte-pairing
mathematically exact (see §8 below for why the prior M94.X attempt
failed and how M94.Z's invariant fixes it). The codec compute on chr22
lean is now ~4% of the full-pipeline wall-clock (down from ~93% under
M94 v1), and the M94.Z encode itself is ~22x faster end-to-end.

---

## 1. Algorithm

For each quality byte `q[i]` in the input, the encoder runs a two-pass
build-then-emit cycle per block:

1. **Build pass.** Walk the input forward computing each per-symbol
   context (see "Context vector" below) and accumulating raw counts
   into `raw_count[ctx][256]` for every active context.
2. **Normalise pass.** For each active context, normalise
   `raw_count[]` to `freq[]` summing exactly to `T = 4096`,
   preserving `freq[s] >= 1` wherever `raw_count[s] >= 1`. Compute
   the cumulative `cum[]` once. Both arrays are held constant for
   the duration of the rANS pass.
3. **Encode pass.** Walk the input again emitting symbols against the
   frozen freq tables using rANS-Nx16:
   - `L = 2^15`, `B = 16` (16-bit renormalisation chunks),
     `b = 2^16`, `b * L = 2^31`.
   - `T = 4096` fixed (12-bit shift). `T` divides `b * L` exactly
     (`2^31 / 2^12 = 2^19`), so `x_max = (b*L/T) * f` is integer-exact
     and rounding-free.
   - 4-way interleaved rANS states (`N = 4`): symbols are split
     round-robin into substreams (`i % 4`) so four independent rANS
     encoders run in lock-step.
   - Per-symbol step: `x_out = (x / f) * T + (x mod f) + cum[s]` after
     pre-renormalisation.

The decoder mirrors the build pass via a recovered freq table (shipped
in the header) and the encode pass run in reverse order.

Unlike M94 v1, which adapted its freq table per-symbol with `+16` /
halve, **M94.Z holds the freq table fixed for the entire block**. This
matches CRAM 3.1's `rANS-Nx16` proper. The cost of "adapting" is paid
once up front in the build pass; the encode-pass hot loop has no table
mutation and ~25-40 ops/symbol vs ~600 ops/symbol in M94 v1.

### Context vector

CRAM-style bit-pack. No SplitMix64 hash. The 16-bit context value is
assembled by OR-ing three disjoint bit fields:

| Field            | Bits | Source                                             |
|------------------|------|----------------------------------------------------|
| `prev_q`         | 12   | sliding window of last quality symbols (`qbits=12`) |
| `position_bucket`| 2    | coarse position-in-read, `pbits=2` (4 buckets)     |
| `revcomp_flag`   | 1    | SAM REVERSE bit (bit 16 of `flags`), per read      |

```
ctx = (prev_q & ((1 << qbits) - 1))
    | ((pos_bucket & ((1 << pbits) - 1)) << qbits)
    | ((revcomp & 1) << (qbits + pbits))
ctx &= (1 << sloc) - 1
```

Default `sloc = 14` -> `2^14 = 16384`-entry context table. The
`prev_q` window slides by `shift = max(1, qbits // 3)` bits per symbol
and accepts the low `shift` bits of each new quality byte:

```
prev_q = ((prev_q << shift) | (sym & ((1 << shift) - 1))) & ((1 << qbits) - 1)
```

`prev_q` resets to 0 at the start of every read, mirroring M94 v1.

`position_bucket` is `min(2^pbits - 1, (pos * 2^pbits) // read_length)`.

### Static-per-block normalisation

Standard "normalise to total" (htscodecs' `normalise_freq` shape):

```
Given raw_count[256] with sum S; produce freq[256] with sum exactly T:
  1. If S == 0: trivial — set freq[0] = T, others 0.
  2. Compute scale = T / S.
  3. freq[s] = max(1, round(raw_count[s] * scale)) where raw_count[s] > 0.
  4. freq[s] = 0 for raw_count[s] == 0.
  5. While sum(freq) > T: decrement the largest freq[s] (>= 2).
  6. While sum(freq) < T: increment the largest freq[s].
```

Edge cases: single-symbol contexts (`freq[s] = T`, all others 0) and
empty contexts (deferred to the caller as a pad-only context) are both
allowed.

### Padding

When `num_qualities % 4 != 0`, the last 1-3 substreams are zero-padded
to equalise lengths. Padding symbols use the all-zero context vector
(`m94z_context(0, 0, 0)`) and are dropped at decode based on
`num_qualities`. The pad count travels in the header `flags` byte
(bits 4-5), not as a separate field.

---

## 2. Wire format (codec id 12)

Four on-disk shapes share the magic `M94Z` and codec id `12`,
distinguished by the version byte:

* **Version 1** (canonical for v1.5 pre-Stage-2 files) — pure-language
  rANS body laid out as four contiguous substreams. Produced by
  Cython-accelerated Python, pure-Java, and pure-ObjC encoders.
* **Version 2** (opt-in via `prefer_native` / `TTIO_M94Z_USE_NATIVE`,
  added 2026-04-30) — `libttio_rans` byte layout
  `[4×states LE][4×lane_sizes LE][per-lane data]`. Faster encode at
  the rANS layer; decode currently runs in pure language
  due to chicken-and-egg context derivation, see §7. V1 readers
  reject the version byte cleanly.
* **Version 3** (added 2026-05-02) — adaptive Range Coder body, no
  freq-tables sidecar. V3 was the L2/Phase-B.2 infrastructure
  precursor to V4 and stays as the no-native-lib fallback.
* **Version 4** (default when `_HAVE_NATIVE_LIB`, added 2026-05-02
  Stage 2) — CRAM 3.1 fqzcomp_qual byte-compatible inner body wrapped
  by an M94.Z outer header. Auto-tuning encoder; byte-equal with
  htscodecs on all 4 benchmark corpora. **This is the default for
  files written under v1.5 with the native library loaded.**

All multi-byte integers little-endian.

### V1 (version byte = 1)

```
[Codec header]
  magic                : 4 bytes  "M94Z"
  version              : uint8    = 1
  flags                : uint8    (see Flags byte layout below)
  num_qualities        : uint64   LE
  num_reads            : uint32   LE
  rlt_compressed_len   : uint32   LE   (= R)
  context_params       : 8 bytes  (see Context-params layout below)
  freq_tables_compressed_len : uint32 LE  (= F)
  read_length_table    : R bytes  zlib(deflate(uint32[num_reads] LE))
  freq_tables_blob     : F bytes  zlib(deflate(freq table blob))
  state_init[4]        : 4 x uint32 LE  (initial rANS states)

[Body]
  substream_lengths    : 16 bytes — 4 x uint32 LE byte counts
  interleaved_streams  : per-substream concatenation of LE 16-bit
                         renorm chunks emitted by each of the four
                         rANS encoders (NOT round-robin at the byte
                         level — each substream is a contiguous run)

[Trailer, 16 bytes]
  state_final[4]       : 4 x uint32 LE  (final rANS states)
```

Header fixed prefix is 34 bytes (magic 4 + version 1 + flags 1 +
num_qualities 8 + num_reads 4 + rlt_compressed_len 4 +
context_params 8 + freq_tables_compressed_len 4); total header size is
`34 + R + F + 16`.

### V2 (version byte = 2, libttio_rans native body)

```
[Codec header]
  magic                : 4 bytes  "M94Z"
  version              : uint8    = 2
  flags                : uint8
  num_qualities        : uint64   LE
  num_reads            : uint32   LE
  rlt_compressed_len   : uint32   LE   (= R)
  context_params       : 8 bytes
  freq_tables_compressed_len : uint32 LE  (= F)
  read_length_table    : R bytes  zlib(deflate(uint32[num_reads] LE))
  freq_tables_blob     : F bytes  zlib(deflate(freq table blob))

[Body — output of ttio_rans_encode_block]
  state_final[4]       : 4 x uint32 LE
  lane_sizes[4]        : 4 x uint32 LE
  lane_0_data          : lane_sizes[0] bytes (16-bit LE renorm chunks)
  lane_1_data          : lane_sizes[1] bytes
  lane_2_data          : lane_sizes[2] bytes
  lane_3_data          : lane_sizes[3] bytes

[No trailer]
```

V2 omits the V1 header's `state_init[4]` suffix and the V1 trailer
(states are embedded in the body). The freq-table contents and
read-length table are unchanged — the M94.Z framing stays the same;
only the rANS bitstream layout differs. Sparse context IDs are
remapped to a dense `[0, n_active)` range for the C call but the
freq-tables blob retains the ORIGINAL sparse IDs so V2 decode can
rebuild contexts using the unchanged context model.

### V3 (version byte = 3, adaptive Range Coder)

V3 replaces V1/V2's static-per-block bit-pack rANS with an adaptive
Range Coder (Subbotin 32-bit RC, carry-propagation idiom). Per-context
frequency tables update as symbols are emitted; no freq-tables sidecar
is shipped. V3 was added 2026-05-02 to close the per-block freq-table
overhead gap on small inputs.

```
[Codec header]
  magic                : 4 bytes  "M94Z"
  version              : uint8    = 3
  flags                : uint8    (pad_count in bits 4..5; rest reserved)
  num_qualities        : uint64   LE
  num_reads            : uint32   LE
  rlt_compressed_len   : uint32   LE   (= R)
  context_params       : 8 bytes  (qbits/pbits/dbits/sloc + reserved)
  read_length_table    : R bytes  zlib(deflate(uint32[num_reads] LE))

[Body — Range Coder output]
  n_active             : uint32   LE   (count of contexts seen)
  sparse_ids           : n_active × uint16 LE  (sorted ascending)
  lane_lengths         : 4 × uint32 LE
  lane_streams         : per-lane RC byte streams concatenated
```

V3 omits the freq-tables blob (the RC adapts on the fly); it omits
`state_init`/`state_final` (RC has no rANS-style state-range
invariant). The context formula is identical to V1/V2 (`prev_q ×
position_bucket × revcomp`, sloc=14 by default). On chr22 the V3
encoded body is 0.393 B/qual vs V1's 0.395 B/qual — the freq-tables
sidecar amortises to nothing at scale, so V3 is strictly an
infrastructure step that prepares the entropy-coder layer for the
richer context model used by V4.

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

V4 differs from V3's outer shape on three points:
- `num_reads` widens from `uint32` to `uint64` (matches CRAM
  fqzcomp_qual's per-read metadata layout).
- Context-params/freq-tables/sparse-IDs are absent — the CRAM body
  is self-describing (its own header carries the model strategy and
  per-context state).
- Body is a single contiguous CRAM blob (no lane-split, no separate
  state vectors).

V4 is the **default** encoded format when `_HAVE_NATIVE_LIB` is true
(`libttio_rans` is loaded). V3 stays as the no-native-lib fallback
and the read-compat path for legacy files. V1/V2 read-compat
unchanged.

V4 byte-equality with htscodecs is guaranteed across all 4 benchmark
corpora (chr22 NA12878 100bp WGS, NA12878 WES, HG002 Illumina 2×250,
HG002 PacBio HiFi). See
`docs/benchmarks/2026-05-02-m94z-v4-stage2-results.md` for per-corpus
B/qual numbers and the encode-wall comparison vs V3.

### Flags byte layout

```
bits 0..3: reserved          (must be 0 in v1)
bits 4..5: pad_count          (0..3 zero bytes appended to last 4-way row)
bits 6..7: reserved          (must be 0 in v1)
```

There is no codec feature flag in M94.Z's flags byte: context-model
features are conveyed via `context_params` instead.

### Context-params layout (8 bytes)

```
qbits    : uint8   (default 12)
pbits    : uint8   (default 2)
dbits    : uint8   (default 0  — delta channel, reserved for v2)
sloc     : uint8   (default 14)
reserved : uint8[4] (must be 0)
```

A reader rejects any blob with `qbits + pbits + dbits + 1 > sloc` (the
context bit fields would overlap their mask) or with `sloc > 16`.

### Freq tables blob (after deflate inflation)

```
n_active_contexts : uint32 LE
for each active context (sorted ascending by ctx id):
  ctx_id          : uint32 LE
  freq[256]       : 256 x uint16 LE  (sum exactly to T = 4096)
```

A "padding-only" context is included if and only if it appears in the
context sequence (i.e. `num_qualities` is not a multiple of 4 OR the
zero context is hit by a real symbol). The encoder enumerates active
contexts ascending and the decoder walks them in the same order — the
sort is not just a serialisation convention, it is part of the byte
contract.

### Read-length table

The per-read length array is encoded as a flat little-endian
`uint32[num_reads]` and zlib-deflated. The decoder inflates and
unpacks. The wire format does **not** carry `revcomp_flags`; they must
be supplied at decode time from sibling pipeline metadata, mirroring
M94 v1's behaviour.

---

## 3. Cross-language conformance contract

The Python implementation in
`python/src/ttio/codecs/fqzcomp_nx16_z.py` is the spec of record.
Seven fixtures under `python/tests/fixtures/codecs/m94z_*.bin` are the
wire-level conformance test vectors; each is committed verbatim into
ObjC and Java fixture trees and the three md5sums must match.

| Fixture       | Inputs                                                                                         | md5                                | Bytes |
|---------------|------------------------------------------------------------------------------------------------|------------------------------------|------:|
| `m94z_a.bin`  | 100 reads x 100bp, all Q40 (`b"I" * 10000`), all forward                                       | `4b0d7df77528908b5c605ab56241c4e5` |   177 |
| `m94z_b.bin`  | 100 reads x 100bp, typical Illumina profile (Q30 mean, Q20-Q40 range, seed `0xBEEF`)           | `93c2a977b2b4b165720004527b2bb7fe` | 49945 |
| `m94z_c.bin`  | 50 reads x 100bp, PacBio HiFi profile (Q40 majority, Q30-Q60 range, seed `0xCAFE`)             | `1e0f76df7ea9163cb3a4ec913994ad17` |  9559 |
| `m94z_d.bin`  | 4 reads x 100bp, mixed revcomp `[0,1,0,1]`, seed `0xDEAD` (smallest valid 4-way input)         | `100654f4010307379dcae1d6363e5595` |  2864 |
| `m94z_f.bin`  | 100 reads x 100bp, 80% reverse-complement, seed `0xF00D` (revcomp-context exercise)            | `f72e2cd7341e84539d1dd7359ff71b44` | 50163 |
| `m94z_g.bin`  | 1 read x 5000bp all Q35 (high-redundancy single-read renormalisation exercise)                 | `9c890fe43877ba26419296cfff8a7ff4` |   171 |
| `m94z_h.bin`  | 1 read x 50000bp all Q40 (single-symbol saturation)                                            | `4643e6fb0d86dd7a7a870ba63922ad03` |   172 |

There is no "fixture (e)" in M94.Z (the M94 v1 large-volume slow-test
fixture has not been ported across; perf validation uses the chr22
benchmark at `tools/benchmarks/` instead).

Each implementation:

- Loads the fixtures from a known location relative to its tests.
- Encodes the same input data and verifies bytes-equal to the fixture
  (encoder conformance).
- Decodes the fixture and verifies bytes-equal to the original input
  (decoder conformance).

Implementations:

- Python — `python/tests/fixtures/codecs/`
- Objective-C — `objc/Tests/Fixtures/codecs/` (verbatim copies)
- Java — `java/src/test/resources/ttio/codecs/` (verbatim copies)

Fixtures (a) and (h) are degenerate by design (all-Q40 bodies); their
small encoded sizes reflect M94.Z's near-zero-entropy body — the
single dominant context is encoded as a freq table of mostly zeros.

---

## 4. Performance

### 4.1 Per-language throughput

Measured on a synthetic 100 K reads x 100bp Q20-Q40 corpus (10 MB raw
input) on the project Linux/AMD64 development host:

| Language        | Encode (MB/s) | Decode (MB/s) | Notes                                                  |
|-----------------|--------------:|--------------:|--------------------------------------------------------|
| Objective-C     |        **52** |        **30** | Inline-C hot loop in the `.m` file; `NS_DURING` guards outside loop body |
| Python (Cython) |        **50** |        **17** | End-to-end including wire-format pack/unpack; Cython kernel alone is ~95/50 |
| Java            |        **33** |        **14** | `long`-typed unsigned-uint32 emulation via `& 0xFFFFFFFFL` |

ObjC and Python (Cython) are within measurement noise on encode; ObjC
leads on decode because it avoids the Python wrapper's wire-format
serialisation overhead (freq-table zlib, struct.pack header assembly).
The Cython kernel alone (no wire-format) measures ~95/50 MB/s, but the
end-to-end `ttio` API includes ~50% encode and ~66% decode overhead
from `_serialize_freq_tables_from_arrays` (zlib), `_pack_wire_format`,
and `_decode_freq_tables` (zlib.decompress + struct.unpack). Java's
gap is due to jagged 2D context arrays and per-symbol cumulative-sum
recomputation. SIMD intrinsics (N=32, AVX2/NEON) are out of scope for
v1 and tracked as M94.Z+ follow-ups.

> **Measurement correction (2026-04-30):** Earlier versions of this
> table reported Python (Cython) at 145/94 MB/s. Those numbers
> reflected the Cython kernel in isolation, not the end-to-end `ttio`
> API that applications actually call. The table now reports end-to-end
> throughput for all three languages on the same hardware.

### 4.1.1 Java encode hot-loop optimisations (Task #78, 2026-05-01)

Two changes in `FqzcompNx16Z.encode` pass 2 lifted Java warm-state
encode from ~25 MB/s to ~34 MB/s on the 10 MB `FqzcompNx16ZPerfTest`
input:

* Per-stream chunk buffers as `short[]` instead of `byte[]` — each
  16-bit renorm step is a single `short` store, replacing two byte
  stores plus the `+=2` length increment. The reverse step packs
  `short[] -> byte[]` in 16-bit LE pairs at the very end.
* `qualities` is pre-padded to `nPadded` with zero tail bytes, so the
  hot loop reads `qPadded[i] & 0xFF` unconditionally — drops the
  `(i < n) ? qualities[i] : 0` branch from every iteration.

The flat `ctxCap*256` packed-table experiment was tried and rejected:
its warm-state gain didn't justify the 32 MB cold-allocation regression
in the cold-path perf harness.

### 4.1.2 Native V2 decode entry — `ttio_rans_decode_block_m94z` (Task #81, 2026-05-01)

The libttio_rans library now exposes
`ttio_rans_decode_block_m94z(...)` — a V2-decode entry point with the
M94.Z context formula (prev_q ring + position bucket + revcomp) baked
inline into C. Replaces the per-symbol `ctypes.CFUNCTYPE` callback
round-trip that previously made the streaming-decode path slower than
the pure-language decoder.

The C decode kernel itself runs at ~107 MiB/s on a 10 MB qualities
block (vs ~96 MiB/s for the Cython M94.Z decoder). End-to-end Python
V2 decode throughput is currently still bottlenecked by metadata-setup
overhead in `_decode_v2_via_native_streaming` (read-length table
zlib-decode, freq-tables blob decompression) — ~110 ms of wrapper
work on top of the 93 ms C kernel for a 10 MB block. Closing that
wrapper gap is a follow-up; the C plumbing is in place and proven
byte-exact via `native/tests/test_m94z_decode.c`.

Java JNI and ObjC linkage to the new entry point are intentionally
deferred — Python is the load-bearing decode path for V2 native, and
proving the C plumbing in one binding first keeps the change
reviewable. See `docs/native-rans-library.md §4.1` for the full
function signature and parity test.

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

The public symbols `MAGIC`, `VERSION`, `L`, `B_BITS`, `B`, `T`,
`T_BITS`, `NUM_STREAMS`, `X_MAX_PREFACTOR`, `m94z_context`,
`position_bucket_pbits`, `normalise_to_total`, `cumulative`, and
`ContextParams` / `CodecHeader` are exported for tests and
diagnostics; the encode/decode functions above are the load-bearing
surface.

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

See `docs/superpowers/specs/2026-04-29-m94z-cram-mimic-design.md`
sections 1-5 for the full design discussion and the byte-pairing proof.

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
- **ObjC decoder cache-fit.** The ObjC decode path is currently
  ~3x slower than the Python (Cython) decode path on the same
  fixtures. The hot loop is functionally identical; the gap is
  attributed to working-set fit and method-dispatch overhead.
  Tracked as a follow-on perf milestone.
- **Reverse-complement flags are not carried in the wire format.**
  The decoder must receive `revcomp_flags` from the M86 pipeline
  (typically `run.flags[i] & 16`). This is symmetric with M94 v1 and
  with M93 REF_DIFF needing CIGAR/positions plumbing.

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

The design spec at
`docs/superpowers/specs/2026-04-29-m94z-cram-mimic-design.md` §2
contains the formal byte-pairing proof.

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
