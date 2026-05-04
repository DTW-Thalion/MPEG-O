# TTI-O M94 — FQZCOMP_NX16 Codec

> **REMOVED in v1.0.** FQZCOMP_NX16 (the M94 v1 codec at slot 10)
> was removed before v1.0 shipped. The `qualities` channel uses
> [FQZCOMP_NX16_Z](fqzcomp_nx16_z.md) (codec id 12, V4 internal
> flavour — a CRAM 3.1 fqzcomp_qual port) as the only supported
> quality-score encoding. This document is retained as historical
> reference for the M94 algorithm.

> **Historical status:** an early v1.2.0 (M94) clean-room
> implementation. Codec id 10; never shipped to a public release
> and superseded by FQZCOMP_NX16_Z (id 12) which proved to match
> CRAM 3.1 byte counts more closely.

This document specifies the FQZCOMP_NX16 codec used by TTI-O for
lossless quality-score compression. It is a clean-room
implementation of the fqzcomp-Nx16 algorithm published by Bonfield
(2022), which is the default lossless quality codec in CRAM 3.1.

The codec combines a context-modeled adaptive frequency model with
4-way interleaved rANS for SIMD-friendly parallelism. It targets
~50% the size of M83's `RANS_ORDER0` on real Phred quality streams
and matches CRAM 3.1 byte counts within the noise floor on standard
Illumina inputs.

---

## 1. Algorithm

For each quality byte `q[i]` in the input, the encoder:

1. **Builds a context vector** from `(prev_q[0..2], position_bucket,
   revcomp_flag, length_bucket)` describing the local quality
   environment at index `i`.
2. **Hashes the context vector** to a 12-bit context index (4096
   possible contexts).
3. **Encodes `q[i]` against the context's adaptive frequency table**
   using rANS, with the table normalised to sum-`M=4096` per symbol.
4. **Updates the freq table** by `+16` on the encoded symbol;
   halves all entries with floor `1` when any entry exceeds `4096`.

Symbols are split round-robin into 4 substreams (`i % 4`) so four
independent rANS encoders run in lock-step. Output bytes are
interleaved at byte granularity, with a 16-byte length prefix
identifying the substream sizes.

The decoder mirrors the state machine exactly: same context vectors,
same freq-table updates, same M-normalisation, same rANS state
ordering.

### Context vector

| Field | Bits | Source |
|---|---|---|
| `prev_q[0]` | 8 | quality byte 1 position back in this read (`0` at start) |
| `prev_q[1]` | 8 | quality byte 2 positions back (`0` at start) |
| `prev_q[2]` | 8 | quality byte 3 positions back (`0` at start) |
| `position_bucket` | 4 | `min(15, (pos * 16) / read_length)`, clamped |
| `revcomp_flag` | 1 | SAM REVERSE bit (bit 16 of `flags`), per read |
| `length_bucket` | 3 | first index `i` where `read_length ≤ boundary[i]`, with boundaries `(50, 100, 150, 200, 300, 1000, 10000)` |

### Context hash (SplitMix64)

The 64-bit context key is built as:

```
bits  0.. 7 : prev_q[0]
bits  8..15 : prev_q[1]
bits 16..23 : prev_q[2]
bits 24..27 : position_bucket
bit  28     : revcomp_flag
bits 29..31 : length_bucket
bits 32..63 : context_hash_seed (default 0xC0FFEE)
```

Then SplitMix64 finalisation:

```
key ^= key >> 33
key  = (key * 0xff51afd7ed558ccd) & MASK64
key ^= key >> 33
key  = (key * 0xc4ceb9fe1a85ec53) & MASK64
key ^= key >> 33
return key & ((1 << context_table_size_log2) - 1)
```

Default `context_table_size_log2 = 12` (4096 contexts).

### Adaptive freq update + M-normalisation

Each context maintains a 256-entry uint16 count table, initialised
to all `1`s (sum = 256).

After encoding/decoding symbol `s` in context `c`:

```
c.freq[s] += 16            # LEARNING_RATE
if c.freq[s] > 4096:       # MAX_COUNT
    for k in 0..255:
        c.freq[k] = max(1, c.freq[k] >> 1)
```

For rANS encoding, the count table is normalised to sum exactly to
`M = 4096` per symbol via M83's existing `_normalise_freqs`
algorithm (§78 binding decision). The renormalisation tie-break
order is descending count + ascending symbol for `delta > 0`,
ascending count + ascending symbol for `delta < 0`, round-robin
until balanced.

---

## 2. Wire format (codec id 10)

```
[Codec header, 54 + L bytes total]
  magic                : 4 bytes  "FQZN"
  version              : uint8    = 1
  flags                : uint8    (see Flags byte layout below)
  num_qualities        : uint64   LE
  num_reads            : uint32   LE
  rlt_compressed_len   : uint32   LE   (= L)
  read_length_table    : L bytes  rANS_ORDER0(uint32[num_reads] LE)
  context_model_params : 16 bytes (see Params layout below)
  state_init[4]        : 4 × uint32 LE  (initial rANS states)

[Body]
  substream_lengths    : 16 bytes — 4 × uint32 LE byte counts
  interleaved_bytes    : round-robin output from the four parallel
                         rANS encoders (zero-padded to equalise
                         substream lengths)

[Trailer, 16 bytes]
  state_final[4]       : 4 × uint32 LE  (final rANS states)
```

### Flags byte layout

```
bit 0: has_revcomp_context   (1 = SAM REVERSE bit affects context hash)
bit 1: has_pos_context       (1 = position-within-read affects context)
bit 2: has_length_context    (1 = read-length bucket affects context)
bit 3: has_prev_q_context    (1 = up-to-3 previous qualities affect context)
bits 4-5: padding_count      (0..3 zero bytes appended to last 4-way row)
bits 6-7: reserved           (must be 0 in v1)
```

### Context-model-params layout (16 bytes)

```
context_table_size_log2 : uint8   (default 12 → 4096 contexts)
learning_rate           : uint8   (default 16)
max_count               : uint16  LE (default 4096)
freq_table_init         : uint8   (0 = uniform/all-ones)
context_hash_seed       : uint32  LE (default 0xC0FFEE)
reserved                : uint8[7] (must be 0)
```

### Padding

When `num_qualities % 4 != 0`, the last 1-3 substreams are zero-
padded to equalise lengths. Padding symbols use the all-zero
context vector — `fqzn_context_hash(0, 0, 0, 0, 0, 0, seed)` — and
are dropped at decode based on `num_qualities`.

### revcomp_flags trajectory at decode

The wire format does **not** carry `revcomp_flags`. The decoder
must receive them from the M86 pipeline (typically derived from
`run.flags[i] & 16`, the SAM REVERSE bit). This is symmetric with
M93 REF_DIFF needing CIGAR/positions plumbing.

---

## 3. Cross-language conformance contract

The Python implementation in `python/src/ttio/codecs/fqzcomp_nx16.py`
is the spec of record. The eight fixtures under
`python/tests/fixtures/codecs/fqzcomp_nx16_*.bin` are the wire-level
conformance test vectors:

| Fixture | Inputs | Coverage |
|---------|--------|----------|
| `fqzcomp_nx16_a.bin` | 100 reads × 100bp, all Q40 (`b"I" * 10000`), all forward | Highest-redundancy stream — exercises near-zero-entropy rANS body |
| `fqzcomp_nx16_b.bin` | 100 reads × 100bp, typical Illumina profile (Q30 mean, Q20-Q40 range, deterministic seed `0xBEEF`) | Real-world Illumina shape |
| `fqzcomp_nx16_c.bin` | 50 reads × 100bp, PacBio HiFi profile (Q40 majority, Q30-Q60 range) | Long-read / high-quality regime |
| `fqzcomp_nx16_d.bin` | 4 reads × 100bp (minimum valid input) | Smallest viable fixture |
| `fqzcomp_nx16_e.bin` | 1M reads × 100bp, all Q30 (large-volume validation) | 53× compression ratio confirmed |
| `fqzcomp_nx16_f.bin` | 100 reads × 100bp, 80% reverse-complement flag set | Revcomp-context exercise |
| `fqzcomp_nx16_g.bin` | Input crafted to fire renormalisation at exactly step 4097 | Renormalisation-boundary correctness |
| `fqzcomp_nx16_h.bin` | Input that drives one context to freq-table saturation | Saturation behaviour |

Each implementation:

- Loads the fixtures from a known location relative to its tests.
- Encodes the same input data and verifies bytes-equal to the
  fixture (encoder conformance).
- Decodes the fixture and verifies bytes-equal to the original
  input (decoder conformance).

Implementations:

- Python — `python/tests/fixtures/codecs/`
- Objective-C — `objc/Tests/Fixtures/codecs/` (verbatim copies)
- Java — `java/src/test/resources/ttio/codecs/` (verbatim copies)

`md5sum` of each fixture in all three locations must match.

Fixture (e) (1.9 MB compressed from 100 MB raw) is gated to a slow-
test profile in each language:

- Python: `pytest -m slow` (default deselects)
- ObjC: `TTIO_RUN_SLOW_TESTS=1` env var
- Java: `mvn test -Dtest=FqzcompNx16UnitTest#fixtureE` (excluded by default)

---

## 4. Performance

Per-language soft targets:

| Language | Encode (target) | Encode (observed) | Decode | Notes |
|----------|-----------------|-------------------|--------|-------|
| Python (Cython) | ≥ 30 MB/s | **0.19 MB/s** ⚠ | (similar) | M-normalisation per symbol still dominates; vectorisation deferred to **M94.X** (REQUIRED follow-up — see WORKPLAN Phase 9) |
| Objective-C | ≥ 100 MB/s | hits target | hits target | Native C inner loop; no PyObject boundary |
| Java | ≥ 60 MB/s | hits target | hits target | `long`-typed unsigned-uint32 emulation via `& 0xFFFFFFFFL` |

The Python regression gate sits at 0.1 MB/s as a safeguard against
catastrophic regressions (NOT the spec target). The 30 MB/s spec
target is reachable via Cython-vectorised `normaliseFreqs` per
M94.X plan.

ObjC + Java native implementations produce byte-identical output
to the Python reference but at hundreds-of-MB/s throughput.

---

## 5. Public API

### Python

```python
from ttio.codecs.fqzcomp_nx16 import encode, decode_with_metadata

encoded: bytes = encode(
    qualities=b"......",          # raw Phred quality bytes (ASCII +33)
    read_lengths=[100, 100, ...], # one per read
    revcomp_flags=[0, 1, 0, ...], # 0 = forward, 1 = reverse-complement
)

result = decode_with_metadata(encoded, revcomp_flags=[0, 1, 0, ...])
qualities = result.qualities
read_lengths = result.read_lengths
```

When the codec is selected via `signal_codec_overrides[
"qualities"] = Compression.FQZCOMP_NX16` on a `WrittenGenomicRun`,
the M86 pipeline derives `read_lengths` from `run.lengths` and
`revcomp_flags` from `run.flags[i] & 16`.

### Objective-C

```objc
NSData *encoded = [TTIOFqzcompNx16
    encodeWithQualities:qualities
            readLengths:readLengths
           revcompFlags:revcompFlags
                  error:&error];

NSDictionary *result = [TTIOFqzcompNx16 decodeData:encoded error:&error];
NSData *qualities = result[@"qualities"];
NSArray<NSNumber *> *readLengths = result[@"readLengths"];
```

### Java

```java
byte[] encoded = FqzcompNx16.encode(qualities, readLengths, revcompFlags);
FqzcompNx16.DecodeResult result = FqzcompNx16.decode(encoded);
byte[] qualities = result.qualities();
int[] readLengths = result.readLengths();
```

---

## 6. Binding decisions

| # | Decision | Rationale |
|---|---|---|
| §80d | FQZCOMP_NX16 context model uses (prev_q[0..2], position_bucket, revcomp_flag, length_bucket); deterministic adaptive freq-table renormalisation at 4096 max-count boundary, halve-with-floor-1. | Matches CRAM 3.1 default fqzcomp parameters; deterministic across implementations. |
| §80e | FQZCOMP_NX16 Python implementation links to a Cython C extension; ObjC + Java implementations are native. | Pure Python is impractical (~30 min on chr22 fixture vs ~5s native); accepted build-deps cost. |
| §80f | FQZCOMP_NX16 wire-format header is **54 + L** bytes (field-by-field sum), not the design spec's "50 + L" estimate. | Field-by-field arithmetic is the source of truth; fixed during M94 Phase 1 implementation. |
| §80g | FQZCOMP_NX16 body includes a **16-byte substream-length prefix** (4 × uint32 LE) before the round-robin interleaved bytes. | Disambiguates de-interleaving when substream lengths differ; not in the original design spec text but pinned during Phase 1 Python implementation. |
| §80h | Auto-default for `qualities → FQZCOMP_NX16` is gated on **v1.5 candidacy** (run already uses REF_DIFF or has any v1.5 explicit override). | Preserves M82 byte-parity for fixture-based regression tests; relaxation of strict Q5a=B (approved 2026-04-29). |

See `docs/superpowers/specs/2026-04-28-m93-m94-m95-codec-design.md`
§3 M94 + §6 + §12 for the full design discussion.

---

## 7. Limitations and follow-ups (v1.2)

- **Python encoder at 0.19 MB/s — REQUIRED follow-up M94.X.** v1.2.0
  release prep blocked until Python encode hits the 30 MB/s spec
  target. Path: vectorise `normaliseFreqs` in Cython. Tracked in
  WORKPLAN Phase 9 as a release-prep blocker, not a deferred item.
- **No 4-way SIMD vectorisation** in any implementation yet — the
  Nx16 4-way interleaving is structurally present, but actual SIMD
  (SSE/AVX) intrinsics are not used. Pure scalar 4-way state
  machines hit the spec's native-language throughput targets
  comfortably; SIMD is an M94.Y optimisation.
- **Fixture (f) byte-exact gate ObjC-side** requires Python's
  MT19937 revcomp_flags trajectory to be a sidecar file
  (`fqzcomp_nx16_f.flags`) — currently covered by smoke decode-
  with-zero-flags test. Java tests exercise this byte-exact via
  `PyRandom.java`.

References:
- Bonfield 2022, "htscodecs: bit-stream packing for CRAM",
  *Bioinformatics* 38(17):4187 — fqzcomp-Nx16 reference algorithm.
- CRAM 3.1 spec (samtools.github.io/hts-specs/CRAMv3.1.pdf) §3.5
  — context model and slice structure inspiration.
- Duda 2014, arXiv:1311.2540 — base rANS algorithm (M83 dependency).

Per Binding Decision §66, all implementations are clean-room from
the published literature. No htslib / tools-Java / fqzcomp-reference
source consulted.
