# REF_DIFF v2 — bit-packed substitutions + IN/SC bases (TTI-O #11 channel 2)

> **Status (2026-05-03).** Brainstormed 2026-05-03 immediately after
> the mate_info v2 (#11 channel 1) cycle shipped at HEAD `1308542`.
> Second channel of the WORKPLAN #11 codec engineering pass. Mirrors
> the mate_info v2 cycle's shape: shared-C-kernel pattern, soft
> wire-format addition, opt-out flag, 4-layer validation.

> **WORKPLAN entry:** Task #11 — codec engineering pass, channel 2
> (REF_DIFF v2).

> **Out of scope:**
> - `sequences_unmapped` routing (deferred from M93 — separate cycle;
>   no chr22 ratio impact since lean+mapped fixture has no unmapped reads)
> - Per-ref-context substitution model (CRAM-style position-conditioned BS) —
>   marginal additional gain for meaningful complexity
> - REF_DIFF v2 encoding-only perf tuning (correctness + ratio first,
>   per V4 Stage 2 / mate_info v2 precedent)
> - NameTokenized v2 (#11 channel 3) — separate cycle

## 0. Why this spec exists

After v1.7 shipped (HEAD `1308542`, mate_info v2), the chr22
NA12878 lean+mapped file is approximately 226 MB (down from 234 MB
v1.6). Per-channel breakdown shows the `sequences` channel still
holds 11.34 MB encoded via REF_DIFF v1 (codec id 9). The v1
algorithm spends 8 bits per substitution base and 8 bits per
insertion/soft-clip base — 4× the entropy required since bases are
drawn from {A, C, G, T} most of the time.

CRAM 3.1 packs substitution bases as 2-bit indices (BS substream)
and 2-bit-packs insertion/soft-clip bases (IN, SC substreams),
reducing the per-base overhead by 6 bits each.

**REF_DIFF v2 ports the relevant CRAM substream taxonomy** (BS, IN,
SC) onto our existing slice-based wire format. Match flags retain
the v1 single-bit encoding (a stream that's >99% zero on Illumina
data; rANS-O0 already near-optimal). N-bases (rare) escape to a
sparse fifth substream.

Estimated savings on chr22: **3-5 MB** (sequences channel
11.34 MB → 6-8 MB target).

## 1. Goal

Add a new compression codec id `REF_DIFF_V2 = 14` and a new on-disk
layout `signal_channels/sequences/refdiff_v2` that encodes the
sequence diff stream as a 5-substream blob (match-flag, BS, IN, SC,
ESC). Default ON in v1.8 with an opt-out flag. Saves ≥2 MB on chr22
NA12878 lean+mapped (target 3-5 MB).

## 2. Non-goals

- **External byte-equality with CRAM.** CRAM's REF_DIFF analogue is
  the SH/BS/IN/SC substream cluster spread across its slice
  container. We borrow CRAM's substream **taxonomy**, not its
  bit-level layout. Cross-language byte-exactness is enforced
  Python ↔ Java ↔ ObjC only.
- **Per-position substitution context** (CRAM's BS conditioned on
  ref_base). Per the L2 V3 / mate_info v2 lesson, per-position
  context modelling at chr22 scale gives marginal entropy gain over
  static frequency tables; not worth the complexity for v1.8.
- **Backward compatibility for v1.7 readers on v1.8 files.** Soft
  wire-format addition: v1.7 readers fail on v1.8 files with a clear
  "unknown compression id 14" error. Users who need v1.7 round-trip
  must opt out of the v1.8 default.
- **Re-engineering the cigar parser.** v1's cigar parser is correct
  and well-tested; reuse it.

## 3. Design summary

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Wire-format strategy | Soft addition: new codec id `REF_DIFF_V2 = 14` alongside v1 streams | Mirrors mate_info v2 cycle; clean migration |
| Internal model | 4-substream + 1-escape decomposition (Flag / BS / IN / SC + ESC) | Each substream's distribution differs qualitatively; per-substream rANS-O0 model wins (mate_info v2 lesson) |
| Linkage | Shared C kernel (`native/src/ref_diff_v2.{c,h}`) wrapped by Python ctypes + Java JNI + ObjC direct link | Templated by mate_info v2; eliminates cross-language ratio drift |
| Substream entropy coders | rANS-O0 via `ttio_rans_o0_encode/decode` (added in mate_info v2 cycle for shared use) | No new entropy coder code; reuses byte-exact infrastructure |
| HDF5 layout | Single uint8 blob at new path `signal_channels/sequences/refdiff_v2`; v1 layout untouched | Mirrors mate_info v2 dispatch shape |
| Default activation | v1.8 default ON; opt-out flag `opt_disable_ref_diff_v2: bool = False` | Captures savings immediately |
| Validation | Phase 0 invariants doc + parameterized stress test + v1↔v2 oracle + cross-language byte-exact gate (4 corpora × 3 languages) | Same shape as mate_info v2 |

## 4. Wire format

### 4.1 Codec id and on-disk path

- Compression enum entry: `REF_DIFF_V2 = 14` (next free id after
  `MATE_INLINE_V2 = 13`).
- HDF5 path: `signal_channels/sequences/refdiff_v2` (uint8 1-D
  dataset, no HDF5 filter, `@compression = 14`).

### 4.2 Inputs at encode time

The encoder takes the same inputs as REF_DIFF v1, plus the standard
slice configuration. Reads are processed slice by slice (default
10,000 reads per slice, matching v1).

| Input | Type | Source |
|-------|------|--------|
| `sequences[]` | `uint8` (concatenated ACGTN ASCII) | per-record sequence bytes |
| `offsets[]` | `uint64` (n_reads + 1 entries) | per-record start in sequences[] |
| `positions[]` | `int64` (1-based) | per-read reference position |
| `cigar_strings[]` | UTF-8 `char *` | per-read CIGAR string |
| `reference[]` | `uint8` (ACGTN) | reference chromosome bytes |
| `reads_per_slice` | `uint64` (default 10000) | slice granularity |

### 4.3 Outer container layout

The outer container header is byte-compatible with REF_DIFF v1 except
for the magic (4 bytes) and codec id:

```
[MAGIC      "RDF2"   ]   4 bytes
[VERSION    0x01     ]   1 byte
[RESERVED            ]   3 bytes  (must be 0)
[NUM_SLICES          ]   4 bytes  u32 LE
[TOTAL_READS         ]   8 bytes  u64 LE
[REFERENCE_MD5       ]  16 bytes
[REFERENCE_URI_LEN   ]   2 bytes  u16 LE
[REFERENCE_URI       ]   N bytes  UTF-8

[SLICE_INDEX            num_slices × 32 bytes — same layout as v1]
  for each slice:
    body_offset      : u64 LE
    body_length      : u32 LE
    first_position   : i64 LE
    last_position    : i64 LE
    num_reads        : u32 LE

[SLICE_BODIES           variable]
```

Outer header overhead: `38 + len(reference_uri)` bytes (matches v1).

### 4.4 Slice body layout (NEW)

Each slice body in v2 contains a 24-byte sub-header plus 5
rANS-O0-encoded substreams:

```
[FLAG_LEN  u32 LE]   bytes in FLAG substream (after rANS-O0)
[BS_LEN    u32 LE]   bytes in BS substream
[IN_LEN    u32 LE]   bytes in IN substream
[SC_LEN    u32 LE]   bytes in SC substream
[ESC_LEN   u32 LE]   bytes in ESC substream
[RESERVED  u32 LE]   must be 0

[FLAG substream    FLAG_LEN bytes]
[BS   substream    BS_LEN   bytes]
[IN   substream    IN_LEN   bytes]
[SC   substream    SC_LEN   bytes]
[ESC  substream    ESC_LEN  bytes]
```

Per-slice header overhead: 24 bytes.

### 4.5 FLAG substream

For each cigar M / = / X op base (in read order, then slice order),
emit one byte: `0` if `read_base == ref_base`, `1` otherwise. The
literal byte stream is then rANS-O0 encoded.

For Illumina data the stream is ~99% zero bytes; rANS-O0 reaches
near-Shannon entropy.

Length of decoded FLAG = total `M`/`=`/`X` bases across the slice.

### 4.6 BS substream (substitution bases)

For each FLAG byte `1` (in stream order), emit a 2-bit code for the
read base: `A=0, C=1, G=2, T=3`. Codes are packed 4 per byte,
LSB-first within the byte. Padding bits at the end of the final byte
are zero.

**Case normalisation:** the encoder upper-cases the read base before
classification (matches v1 REF_DIFF behaviour). Lowercase acgt are
treated as their uppercase equivalents.

**Non-ACGT escape:** if the read base is `N`, `n`, or any other
non-ACGT byte after upper-casing, emit code `0` (placeholder) in BS
and record an ESC entry (§4.9). The decoder uses ESC to override.

The packed byte stream is then rANS-O0 encoded.

### 4.7 IN substream (insertion bases)

For each cigar `I` op base (in read order, then slice order), emit
a 2-bit code for the inserted base. Same packing rules as BS.
N-base escape via ESC (§4.9).

The packed byte stream is then rANS-O0 encoded.

### 4.8 SC substream (soft-clip bases)

For each cigar `S` op base, emit a 2-bit code. Same packing rules.
N-escape via ESC.

rANS-O0 encoded.

### 4.9 ESC substream (N-base escape)

For each non-ACGT base in BS, IN, or SC, append an ESC entry:

```
[STREAM_ID  1 byte]    0 = BS, 1 = IN, 2 = SC, 3+ = reserved (decoder rejects)
[INDEX     varint]     0-based BASE index within that substream — the
                       Nth base position (NOT byte position) where the
                       value should be overridden. For BS, this is the
                       Nth FLAG=1 base; for IN/SC, the Nth base in
                       that substream's logical order.
[LITERAL   1 byte]     the original base byte (typically 'N'; preserved
                       case-as-written)
```

Concatenated ESC entries (in encounter order) → rANS-O0 encoded.

The decoder walks ESC in the same encounter order during slice
decode, applying each override at the matching (stream_id, index)
base position. The encoder must emit ESC entries with monotonically
non-decreasing (stream_id, index) tuples; the decoder verifies this
ordering and rejects out-of-order entries with `TTIO_RANS_ERR_CORRUPT`.

### 4.10 CIGAR op handling summary (unchanged from v1)

| Op | Read advances | Ref advances | Payload |
|----|---------------|--------------|---------|
| M / = / X | +1 each | +1 each | 1 FLAG byte per base; 2 BS bits per FLAG=1 (N → ESC) |
| I | +N | 0 | 2 IN bits per base (N → ESC) |
| S | +N | 0 | 2 SC bits per base (N → ESC) |
| D / N(cigar) | 0 | +N | none |
| H / P | 0 | 0 | none |

Unmapped reads (cigar `*`) cannot be REF_DIFF-encoded — same as v1.
The existing M93 fallback (BASE_PACK) applies to v2 unchanged;
proper unmapped-read routing through `sequences_unmapped` is a
separate (still-deferred) task.

## 5. Phase 0 invariants

The Phase 0 deliverable is this written invariants list plus a
stress-test C program that validates each invariant exhaustively.
No production code is written before Phase 0 lands.

| ID | Invariant | Test |
|----|-----------|------|
| I1 | **2-bit ACGT bijectivity:** the encode mapping `{A=0, C=1, G=2, T=3}` and its inverse are exactly inverse for the 4 ACGT inputs. | Direct enumeration. |
| I2 | **ESC length conservation:** decoder consumes exactly one ESC entry per non-ACGT base across (BS, IN, SC). Under-count or over-count rejected with `TTIO_RANS_ERR_ESC_LENGTH_MISMATCH`. | Synthetic slices with deliberately tampered ESC counts. |
| I3 | **End-to-end lossless:** for any input `(sequences, offsets, positions, cigars, reference)`, `decode(encode(...))` returns the original `sequences` exactly. | 1000 synthetic random valid slices; round-trip + equality. |
| I4 | **ESC stream_id range:** decoder rejects any ESC entry with `stream_id >= 3` with `TTIO_RANS_ERR_RESERVED_ESC_STREAM`. | Synthetic ESC stream containing stream_id=3; assert decoder error. |
| I5 | **N-fallback round-trip:** read sequences containing `N` bases at substitution / insertion / soft-clip positions round-trip exactly via the ESC path. | 100 synthetic reads with N-heavy patterns. |
| I6 | **CIGAR parser parity with v1:** for any cigar string, the v2 parser produces the same per-op counts as v1's `_CIGAR_OP_RE`-based parser. | Cross-validate against the v1 Python parser on 1000 random + canonical cigar strings. |

The stress test parameterizes: `n_reads ∈ {1, 100, 10_000}` ×
pattern ∈ {all-perfect-match, sub-heavy (~5% subs), ins-heavy
(~5% ins), soft-clip-heavy (10% softclip), N-heavy (10% N), mixed}.
~18 round-trips with full equality assertion.

## 6. C library API

### 6.1 New kernel: `native/src/ref_diff_v2.{c,h}`

Sized comparably to `mate_info_v2.c` (~700 lines). Reuses
`ttio_rans_o0_encode/decode` for substream entropy.

### 6.2 Public entry points (added to `native/include/ttio_rans.h`)

```c
typedef struct {
    const uint8_t  *sequences;       // concatenated ACGTN bytes
    const uint64_t *offsets;         // n_reads + 1 entries
    const int64_t  *positions;       // 1-based reference position
    const char    **cigar_strings;   // per-read CIGAR
    uint64_t        n_reads;
    const uint8_t  *reference;
    uint64_t        reference_length;
    uint64_t        reads_per_slice;
    const uint8_t  *reference_md5;   // 16 bytes
    const char     *reference_uri;
} ttio_ref_diff_v2_input;

size_t ttio_ref_diff_v2_max_encoded_size(uint64_t n_reads, uint64_t total_bases);

int ttio_ref_diff_v2_encode(
    const ttio_ref_diff_v2_input *in,
    uint8_t *out,
    size_t  *out_len);

int ttio_ref_diff_v2_decode(
    const uint8_t  *encoded, size_t encoded_size,
    const int64_t  *positions,
    const char    **cigar_strings,
    uint64_t        n_reads,
    const uint8_t  *reference, uint64_t reference_length,
    uint8_t        *out_sequences,
    uint64_t       *out_offsets);
```

Returns 0 on success; negative `TTIO_RANS_ERR_*` on framing, length,
or reserved-value violations.

New error codes (added to `native/include/ttio_rans.h`):
- `TTIO_RANS_ERR_ESC_LENGTH_MISMATCH = -6`
- `TTIO_RANS_ERR_RESERVED_ESC_STREAM = -7`

### 6.3 ctests

- `test_ref_diff_v2_invariants.c` — one assertion per invariant
  I1-I6 from §5
- `test_ref_diff_v2_stress.c` — parameterized round-trip across
  18 (n_reads, pattern) combinations
- `test_ref_diff_v2_chr22_fixture.c` — end-to-end test on a
  pre-extracted chr22 sub-sample (e.g. 10K reads)

## 7. Language bindings

Mirror the mate_info v2 / V4 Stage 2 pattern.

### 7.1 Python — `python/src/ttio/codecs/ref_diff_v2.py`

ctypes wrapper following `mate_info_v2.py`'s shape (lazy-load
`libttio_rans.so` from `TTIO_RANS_LIB_PATH`).

```python
def encode(
    sequences: np.ndarray,
    offsets: np.ndarray,
    positions: np.ndarray,
    cigar_strings: list[str],
    reference: bytes,
    reference_md5: bytes,
    reference_uri: str,
    reads_per_slice: int = 10_000,
) -> bytes: ...

def decode(
    encoded: bytes,
    positions: np.ndarray,
    cigar_strings: list[str],
    n_reads: int,
    reference: bytes,
) -> tuple[np.ndarray, np.ndarray]:  # (sequences, offsets)
    ...
```

### 7.2 Java — `RefDiffV2.java` + `TtioRansNative.encodeRefDiffV2/decodeRefDiffV2`

Mirrors `MateInfoV2.java` shape exactly. JNI bridge in
`native/src/ttio_rans_jni.c`.

CLI tool: `java/src/main/java/global/thalion/ttio/tools/RefDiffV2Cli.java`
(takes pre-extracted typed-array .bin files like `MateInfoV2Cli`).

### 7.3 ObjC — `objc/Source/Codecs/TTIORefDiffV2.{h,m}`

Direct link to `ttio_ref_diff_v2_encode/_decode`. CLI tool:
`objc/Tools/TtioRefDiffV2Cli.m`.

## 8. Writer/reader dispatch

### 8.1 Writer

New flag `WrittenGenomicRun.opt_disable_ref_diff_v2: bool = False` in
all three languages.

Writer logic in the sequences-channel writer (currently
`_write_sequences_ref_diff` in Python `spectral_dataset.py`):

- If `opt_disable_ref_diff_v2 == True` OR the native lib is
  unavailable OR the sequences channel falls back to BASE_PACK
  (no reference) → use existing v1 REF_DIFF (or BASE_PACK) path.
- Otherwise → call `ref_diff_v2.encode(...)`, write resulting bytes
  as `signal_channels/sequences/refdiff_v2` uint8 dataset with
  `@compression = 14`.

`signal_codec_overrides[sequences]` set to `REF_DIFF` (the v1 codec)
remains valid AND triggers the v2 path when the flag is False —
i.e. v1 enum value still selects "the current REF_DIFF codec",
which v1.8+ resolves to v2. To force v1 wire format, the user sets
`opt_disable_ref_diff_v2 = True`.

### 8.2 Reader

In `GenomicRun.read_sequences` (or equivalent), check for
`signal_channels/sequences/refdiff_v2` first.

- If present: read uint8 blob, call `ref_diff_v2.decode(blob,
  positions, cigar_strings, n_reads, reference)`.
- If absent: fall through to existing v1 REF_DIFF path or
  BASE_PACK.

A v1.7 reader on a v1.8 file: encounters `refdiff_v2` dataset with
`@compression = 14`, doesn't recognize the codec id, raises a clear
error: "unknown compression id 14 in
signal_channels/sequences/refdiff_v2 — file written by TTI-O v1.8+;
upgrade reader."

## 9. Validation

### 9.1 Layer 1 — Phase 0 invariants (C)

See §5. Native ctests in `native/tests/`.

### 9.2 Layer 2 — v1↔v2 oracle (Python)

`python/tests/integration/test_ref_diff_v2_v1_oracle.py` — for
each corpus:

- Encode via v1 (set `opt_disable_ref_diff_v2 = True`), decode → `seq_v1`.
- Encode via v2 (default), decode → `seq_v2`.
- Assert `seq_v1 == seq_v2 == original_sequences` per record.

### 9.3 Layer 3 — cross-language byte-exact

`python/tests/integration/test_ref_diff_v2_cross_language.py` —
for each corpus × language, encode through that language's CLI,
assert byte-identical encoded blob across {Python, Java, ObjC}.

4 corpora × 3 languages = **12 byte-exact assertions**.

### 9.4 Layer 4 — chr22 ratio gate

`python/tests/integration/test_ref_diff_v2_compression_gate.py` —
chr22 NA12878 lean+mapped end-to-end:

- v1 baseline → expect ~226 MB total (post-mate_info-v2).
- v2 default → expect ~222-223 MB (savings target: 3-5 MB on the
  sequences channel).
- **Hard gate:** if savings < 2 MB, fail.

### 9.5 Test corpora

Same 4 corpora as mate_info v2 (per-corpus N-rates and softclip
densities will differ — important because v2 wins are concentrated
in the sub/IN/SC streams):

- chr22 NA12878 100bp WGS — typical Illumina, low softclip
- NA12878 WES (chr22, ~95bp) — capture-protocol softclip
- HG002 Illumina 2×250 — long-read Illumina, more softclip
- HG002 PacBio HiFi — long reads, high indel rate, higher N% (sequence
  errors map to N in some pipelines)

## 10. Phase plan

| Phase | Scope | Output | Gate |
|-------|-------|--------|------|
| 0 | Spec & invariants doc | This document | User approval |
| 1 | C kernel + 6 invariant ctests + parameterized stress ctest | `native/src/ref_diff_v2.{c,h}`; `native/tests/test_ref_diff_v2_*.c` | All ctests + stress test pass |
| 2 | Python ctypes wrapper + v1↔v2 oracle test | `python/src/ttio/codecs/ref_diff_v2.py`; `test_ref_diff_v2_v1_oracle.py` | Oracle test green on all 4 corpora |
| 3 | Java JNI binding + CLI tool + round-trip test | `RefDiffV2.java`; JNI funcs; `RefDiffV2Cli.java` | Round-trip green; CLI emits valid blob |
| 4 | ObjC direct link + CLI tool + round-trip test | `TTIORefDiffV2.{h,m}`; `TtioRefDiffV2Cli.m` | Round-trip green; CLI emits valid blob |
| 5 | Cross-language byte-exact gate | `test_ref_diff_v2_cross_language.py` (12 assertions) | All 12 byte-exact green |
| 6 | Writer/reader dispatch in 3 languages + opt-out flag | `opt_disable_ref_diff_v2` flag; v1↔v2 dispatch in writers and readers | Existing M93 / chr22 tests still green + new dispatch tests |
| 7 | chr22 ratio measurement + format-spec §10.10b + CHANGELOG v1.8 | benchmark doc + format-spec update | Ratio gate ≥2 MB savings on chr22 |

**Sequencing rules** (same as mate_info v2):
- Phase 1 must complete before Phases 2/3/4
- Phases 2/3/4 are independent and parallelizable via subagents
- Phase 5 gates Phase 6
- Phase 7 is the final acceptance gate

**Estimated task count: ~15-16 tasks** (mirrors the mate_info v2
cycle that just shipped in 16 tasks, including the unplanned T2b for
rANS-O0 — that infrastructure is already in place for v2).

## 11. Risks

- **High-N corpora.** PacBio HiFi sometimes maps sequence errors to
  N. If the N-rate is high (>5%), the ESC stream grows linearly and
  may eclipse the BS savings. Stress test must include N-heavy
  pattern; if PacBio HiFi v2 ratio is worse than v1, document and
  consider per-corpus dispatch (rare in practice — Illumina dominates
  the deliverable).
- **Cigar parser drift.** v2 must produce the same per-op counts as
  v1 for any cigar string. Invariant I6 explicitly cross-validates
  against the v1 Python parser on 1000 random + canonical inputs.
- **Default-on rollout.** v1.8 default ON means v1.7 readers fail on
  v1.8 files. Same mitigation as mate_info v2: clear error message +
  opt-out flag. CHANGELOG and migration docs call out the break.
- **Slice index compatibility.** The v2 wire format's slice index is
  byte-compatible with v1 by design. Decoders that only need slice
  offsets (not body decoding) can read v2 files using v1 index code.

## 12. Out of scope (deferred)

- **`sequences_unmapped` routing.** Unmapped reads currently fall
  through to BASE_PACK on the same `sequences` channel; the v1 spec
  noted this should be routed to a separate `sequences_unmapped`
  channel. Independent of codec engineering — defer to a future
  cycle.
- **Per-ref-context substitution model.** CRAM conditions BS on
  ref_base (giving a separate freq table per A/C/G/T base context).
  Marginal entropy gain at chr22 scale per the L2 V3 lesson; defer.
- **NameTokenized v2 (#11 channel 3).** Separate cycle, ~3-4 MB
  savings.
- **Java/ObjC perf optimization.** Correctness-and-ratio first per
  V4 Stage 2 / mate_info v2 precedent.

## 13. References

- Memory: `project_tti_o_v1_2_codecs.md` Status 2026-05-03 (v1.7
  shipped, channel 1 mate_info v2 outcome)
- Memory: `feedback_libttio_rans_api_layers.md` (use
  `ttio_rans_o0_encode/decode` for plain rANS-O0 substream entropy —
  the entry point added in mate_info v2 cycle)
- Memory: `feedback_phase_0_spec_proof.md` (wire-format-breaking
  codec discipline)
- mate_info v2 spec: `docs/superpowers/specs/2026-05-03-mate-info-v2-design.md`
- mate_info v2 plan: `docs/superpowers/plans/2026-05-03-mate-info-v2.md`
- v1 REF_DIFF spec (M93): `docs/codecs/ref_diff.md`
- v1 REF_DIFF Python: `python/src/ttio/codecs/ref_diff.py`
- CRAM 3.1 spec (substream taxonomy reference):
  <https://samtools.github.io/hts-specs/CRAMv3.pdf>
