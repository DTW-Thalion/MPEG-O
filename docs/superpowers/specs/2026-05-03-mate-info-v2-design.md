# mate_info v2 — CRAM-style inline mate-pair encoding (TTI-O #11 channel 1)

> **Status (2026-05-03).** Brainstormed 2026-05-03 immediately after the
> L4 v1.6 follow-up cluster shipped at HEAD `d048b2b`. First channel
> of the WORKPLAN #11 codec engineering pass (REF_DIFF / NameTokenized
> / mate_info). This spec covers mate_info only; REF_DIFF v2 and
> NameTokenized v2 will get their own per-channel specs in subsequent
> cycles, sharing the engineering shape established here.

> **WORKPLAN entry:** Task #11 — codec engineering pass, channel 1
> (mate_info).

> **Out of scope:**
> - REF_DIFF v2 (sequences channel) — separate cycle
> - NameTokenized v2 (read_names channel) — separate cycle
> - #10 offsets-cumsum (structural HDF5 framing change) — independent track
> - mate_info v2 perf optimization in Java/ObjC — correctness and ratio
>   first, perf is a Stage-2-style follow-up

## 0. Why this spec exists

After v1.6 shipped (HEAD `d048b2b`), the chr22 NA12878 lean+mapped
file is 105 MB vs CRAM 3.1's 86 MB — a 19 MB gap. Per-channel
analysis from the v1.6 close-out:

| Channel | Current | Target | Gap closure |
|---------|--------:|-------:|------------:|
| sequences (REF_DIFF) | 11.3 MB | ~6-8 MB | 3-5 MB |
| read_names (NameTokenized) | 7.1 MB | ~3-4 MB | 3-4 MB |
| mate_info/{chrom,pos,tlen} | 11.5 MB | ~3-4 MB | **7-8 MB** |
| Other | ~75 MB | ~75 MB | 0 |

mate_info has the largest single-channel opportunity. Reason: CRAM
bit-packs PNEXT/RNEXT/TLEN inline per record, exploiting the SAM
mate-pair invariants:

- ~90% of records are properly paired with mate on same chrom →
  `mate_chrom == own_chrom` is a single bit
- For those records, `mate_pos = own_pos + small_delta` → 1-2 byte
  zigzag-varint, not 8-byte int64
- `tlen` is bounded for proper pairs and often near zero or near
  insert-size

Our current layout writes three independent compressed arrays
(`signal_channels/mate_info/{chrom,pos,tlen}`), each on its own with
no cross-stream redundancy elimination. The static per-record cost is
~6.5 bytes; CRAM gets it to ~1.5-2 bytes. **mate_info v2 closes that
gap** by mirroring the CRAM substream taxonomy.

## 1. Goal

Add a new compression codec id `MATE_INLINE_V2 = 13` and a new
on-disk layout `signal_channels/mate_info/inline_v2` that encodes the
full mate triple (`mate_chrom_id`, `mate_pos`, `tlen`) per record as
a CRAM-style 4-substream blob. Default ON in v1.7 with an opt-out
flag. Saves ≥5 MB on chr22 NA12878 lean+mapped (target 7-8 MB).

## 2. Non-goals

- **External byte-equality with CRAM.** CRAM's mate-info logic is
  spread across its slice container, not a self-contained library
  entry point. We borrow CRAM's substream **taxonomy** (MF/NS/NP/TS),
  not its bit-level layout. Cross-language byte-exactness is enforced
  Python ↔ Java ↔ ObjC only.
- **Variable-T or adaptive entropy coders for substreams.** Per the
  L2 V3 lesson (`feedback_rans_nx16_variable_t_invariant` +
  `project_tti_o_v1_2_codecs.md` Status 2026-05-02 evening),
  adaptive RC at chr22 scale gives marginal ratio improvement over
  static rANS-O0. Substreams use `ttio_rans_encode_block` /
  `ttio_rans_decode_block` (the existing rANS-O0 pass).
- **Backward-compatibility for v1.6 readers on v1.7 files.** Soft
  wire-format addition: v1.6 readers fail on v1.7 files with a clear
  "unknown compression id 13" error. Users who need v1.6 round-trip
  must opt out of v1.7's default.

## 3. Design summary

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Wire-format strategy | Soft addition: new codec id `MATE_INLINE_V2 = 13` alongside v1 streams | Per `feedback_phase_0_spec_proof`, full Phase 0 discipline; clean migration |
| Internal model | CRAM-style 4-substream decomposition (MF / NS / NP / TS) | Each substream's distribution is qualitatively different; separate streams let each rANS-O0 pass model its own distribution |
| Linkage | Shared C kernel, V4 Stage 2 pattern (`native/src/mate_info_v2.{c,h}` + Python ctypes + Java JNI + ObjC direct link) | One source of truth for the modeling logic; eliminates cross-language ratio drift |
| Substream entropy coders | Per-stream best-fit from existing arsenal (rANS-O0 + zigzag-varint; MF auto-pick 2-bit-pack vs rANS-O0) | Reuses `ttio_rans_encode_block`; no new entropy coder code; per L2 V3 lesson, static rANS at chr22 scale is near-optimal |
| HDF5 layout | Single uint8 blob at new path `signal_channels/mate_info/inline_v2`; v1 layout untouched | Mirrors M94.Z and REF_DIFF; clean v1↔v2 dispatch |
| Default activation | v1.7 default ON; opt-out flag `opt_disable_inline_mate_info_v2: bool = False` | Captures savings immediately; opt-out preserves v1.6 round-trip when needed |
| Validation | Phase 0 invariants doc + parameterized stress test + v1↔v2 oracle + cross-language byte-exact gate (4 corpora × 3 languages) | Catches the M94.X failure shape (small-fixture-pass / production-fail) |

## 4. Wire format

### 4.1 Codec id and on-disk path

- Compression enum entry: `MATE_INLINE_V2 = 13` (next free id; current
  max is 12, `FQZCOMP_NX16_Z`; id 10 is `_RESERVED_10` and not reused).
- HDF5 path: `signal_channels/mate_info/inline_v2` (uint8 1-D dataset,
  no HDF5 filter, `@compression = 13`).

### 4.2 Inputs at encode time

The encoder takes the full record set as parallel typed arrays. The
first three are the mate triple to encode; the last two are
**reader-side dependencies** required for SAME_CHROM delta
reconstruction.

| Input | Type | Source |
|-------|------|--------|
| `mate_chrom_ids[N]` | `int32` | per-record, -1 if RNEXT='*' |
| `mate_positions[N]` | `int64` | per-record, 0-based POS |
| `template_lengths[N]` | `int32` | per-record, signed tlen |
| `own_chrom_ids[N]` | `uint16` | from `genomic_index/chromosome_ids` (L1 stream); 0xFFFF treated as -1 |
| `own_positions[N]` | `int64` | from `genomic_index/positions` |

The decoder takes the encoded blob plus `(own_chrom_ids,
own_positions, n_records)` and produces `(mate_chrom_ids,
mate_positions, template_lengths)`. The reader-side dependency
changes the read order vs v1: `inline_v2` decode must run AFTER
`genomic_index/positions` and `genomic_index/chromosome_ids` are
loaded. Documented in `docs/format-spec.md` (the existing v1
mate_info section §10.9 grows a sibling §10.9b for v2 in Phase 7).

### 4.3 Container layout

```
[MAGIC      "MIv2"   ]   4 bytes
[VERSION    0x01     ]   1 byte
[FLAGS      u8       ]   1 byte (all bits reserved, must be 0)
[NUM_RECS              ]   8 bytes  u64 LE
[NUM_CROSS             ]   4 bytes  u32 LE  (count of MF==1, sizes NS-stream)
[MF_LEN  NS_LEN  NP_LEN  TS_LEN]   16 bytes  4× u32 LE
[MF_BYTES   ...]   MF_LEN  bytes
[NS_BYTES   ...]   NS_LEN  bytes
[NP_BYTES   ...]   NP_LEN  bytes
[TS_BYTES   ...]   TS_LEN  bytes
```

Container header overhead: **34 bytes** (negligible).

### 4.4 MF taxonomy (mate flag)

2 bits, 3 active values, value 3 reserved.

| MF | meaning | mate_chrom_id condition |
|----|---------|------------------------|
| 0  | SAME_CHROM      | `mate_chrom_id == own_chrom_id` |
| 1  | CROSS_CHROM     | `mate_chrom_id >= 0 && != own_chrom_id` |
| 2  | NO_MATE         | `mate_chrom_id == -1` (RNEXT='*') |
| 3  | _reserved_      | Must not be emitted; decoder rejects with `TTIO_RANS_ERR_RESERVED_MF`. |

The `'='` SAM-spec shortcut for RNEXT is canonicalized at BAM parse
time to the own chrom_id; we encode against the canonical form, not
the literal `'='` byte.

### 4.5 MF substream

Leading byte selects encoding:

- `0x00` raw 2-bit pack: `ceil(N/4)` bytes; MF[i] in bits
  `[(i%4)*2 : (i%4)*2+2]` of byte `i/4` (LSB-first within the byte).
  Bits beyond `2*N` in the final byte are padded zero.
- `0x01` rANS-O0 over the literal MF[] byte array (1 byte/record,
  value 0/1/2; rANS dictionary covers values {0,1,2}).

Encoder picks smaller of the two; decoder dispatches on leading byte.

**Encoder MF=3 guard:** before encoding under either path, the
encoder asserts `MF[i] ∈ {0, 1, 2}` for all `i`. The 2-bit raw pack
can bitwise represent value 3, so the validation is path-independent
and must run before either branch.

**Decoder MF=3 rejection:** after decoding under either path, the
decoder validates each reconstructed MF value is in `{0, 1, 2}` and
rejects any 3 with `TTIO_RANS_ERR_RESERVED_MF`. This catches both
adversarial rANS dictionaries containing 3 AND adversarial raw-pack
bytes with `0b11` slots.

Length: `1 + min(ceil(N/4), rANS_O0_size(MF_byte_array))` bytes.

### 4.6 NS substream (next-segment chrom for cross-chrom records)

For each MF==1 record (in record order), `varint(mate_chrom_id)`
where `mate_chrom_id` is the index into
`genomic_index/chromosome_names`. Concatenated, then rANS-O0.

The decoder reads exactly NUM_CROSS varints from this stream; an
NS_LEN that does not produce exactly NUM_CROSS varints is rejected
with `TTIO_RANS_ERR_NS_LENGTH_MISMATCH`.

### 4.7 NP substream (next-segment position)

For each record (in order):

- MF==0 (SAME_CHROM): `zigzag_varint(mate_pos - own_pos)`
- MF==1 (CROSS_CHROM): `zigzag_varint(mate_pos)`
- MF==2 (NO_MATE): `zigzag_varint(mate_pos)`

Concatenated, rANS-O0.

Zigzag is used uniformly across all three classes (rather than
unsigned varint for MF==1 / MF==2) because real BAMs sometimes carry
`mate_pos = -1` for unmapped mates that share the own_chrom_id, and
because the SAM convention of placing unmapped mates at the mapped
mate's position can produce zero-or-negative values after 1-based →
0-based conversion. The 1-bit zigzag overhead on positive values is
< 1% on chr22-scale corpora.

### 4.8 TS substream (template size / tlen)

For each record (in order), `zigzag_varint(tlen)`. Concatenated,
rANS-O0.

### 4.9 Varint and zigzag-varint format

- `varint(x)`: little-endian base-128 (LEB128). 7 data bits per byte;
  high bit set on all but the last byte. Max length: `ceil(64/7) = 10`
  bytes for `uint64`.
- `zigzag_varint(x)`: encode signed `x` as unsigned
  `(x << 1) ^ (x >> 63)` (arithmetic shift), then varint. Recovers
  via `(u >> 1) ^ -(u & 1)`. Max length: 10 bytes for `int64`.

## 5. Phase 0 invariants

The Phase 0 deliverable is a written invariants list (this section)
plus a stress-test C program (`native/tests/test_mate_info_v2_*.c`)
that validates each invariant exhaustively. No production code is
written before Phase 0 lands.

| ID | Invariant | Test |
|----|-----------|------|
| I1 | **MF exhaustiveness:** every `(own_chrom_id, mate_chrom_id)` pair where `own ∈ {0..K-1}, mate ∈ {-1, 0..K-1}` maps to exactly one of {0, 1, 2}. | Enumerate K=16, all (16 × 17) pairs; assert exactly one MF assignment. |
| I2 | **Zigzag bijectivity:** `zigzag_decode(zigzag_encode(x)) == x` for all `x ∈ [INT64_MIN, INT64_MAX]`. | 10K random samples + boundary values (±0, ±1, ±2^31, ±2^32, ±2^62, INT64_MIN/MAX). |
| I3 | **Varint reversibility:** `varint_decode(varint_encode(x)) == x` for all `x ∈ [0, UINT64_MAX]`. | Same shape as I2 in `[0, UINT64_MAX]`. |
| I4 | **NS length conservation:** decoder consumes exactly NUM_CROSS varints from NS stream — under-read AND over-read both rejected with `TTIO_RANS_ERR_NS_LENGTH_MISMATCH`. | Synthetic NS streams with NS_LEN deliberately off by ±1, ±10 bytes; assert error. |
| I5 | **MF auto-pick equivalence:** raw-pack decode (leading byte `0x00`) reconstructs the same MF[] array as rANS decode (leading byte `0x01`) for the same input. | 1000 synthetic MF[] arrays; encode under both, decode each, assert equality. |
| I6 | **End-to-end lossless:** for any input `(mate_chrom_ids, mate_positions, template_lengths)` and matching `(own_chrom_ids, own_positions)`, `decode(encode(...))` returns the input exactly. | 1000 synthetic random valid mate triples; round-trip + equality. |
| I7 | **Reserved MF rejection (both paths):** decoder rejects any MF value of 3 with `TTIO_RANS_ERR_RESERVED_MF`, in both the rANS-O0 path AND the raw-pack path. | (a) Synthetic rANS-O0 stream containing MF=3; assert decoder error. (b) Synthetic raw-pack stream with a `0b11` 2-bit slot; assert decoder error. |
| I8 | **Encoder MF=3 guard:** encoder rejects any input MF[] containing value 3 before either encoding path, with `TTIO_RANS_ERR_RESERVED_MF`. | Synthetic input MF=[0, 1, 3, 2]; assert encoder rejects. |

The stress test (`test_mate_info_v2_stress.c`) parameterizes:
`n_records ∈ {1, 100, 10_000, 1_000_000}` × `pattern ∈ {all-proper,
all-cross, all-unmapped, mixed-50-30-20}`. ~16 round-trips, each
with full equality assertion. Targets the M94.X failure shape:
small fixtures pass, large adversarial inputs fail.

## 6. C library API

### 6.1 New kernel: `native/src/mate_info_v2.{c,h}`

Sized comparably to `m94z_v4_wire.c` (~600-800 lines). Reuses
existing `ttio_rans_encode_block` / `ttio_rans_decode_block` for each
substream's rANS-O0 pass — no new entropy coder code.

### 6.2 Public entry points

Added to `native/include/ttio_rans.h` (avoiding header sprawl):

```c
typedef struct {
    const int32_t  *mate_chrom_ids;     // -1 if RNEXT='*', else id ≥ 0
    const int64_t  *mate_positions;     // 0-based POS
    const int32_t  *template_lengths;   // signed tlen
    const uint16_t *own_chrom_ids;      // L1 id stream; 0xFFFF treated as -1
    const int64_t  *own_positions;
    uint64_t        n_records;
} ttio_mate_info_v2_input;

typedef struct {
    uint8_t  *out_buf;
    size_t    out_capacity;
    size_t   *out_size;      // written: actual encoded size
} ttio_mate_info_v2_output;

size_t ttio_mate_info_v2_max_encoded_size(uint64_t n_records);

int ttio_mate_info_v2_encode(
    const ttio_mate_info_v2_input *in,
    ttio_mate_info_v2_output      *out);

int ttio_mate_info_v2_decode(
    const uint8_t *encoded, size_t encoded_size,
    const uint16_t *own_chrom_ids,
    const int64_t  *own_positions,
    uint64_t        n_records,
    int32_t        *out_mate_chrom_ids,
    int64_t        *out_mate_positions,
    int32_t        *out_template_lengths);
```

Returns 0 on success; negative `TTIO_RANS_ERR_*` on framing or length
mismatch, decoder bound violations, MF==3 reserved, or
NS-stream/NUM_CROSS mismatch.

### 6.3 ctests

- `test_mate_info_v2_invariants.c` — one assertion per invariant
  I1–I8 from §5.
- `test_mate_info_v2_stress.c` — parameterized round-trip across
  16 (n_records, pattern) combinations.
- `test_mate_info_v2_chr22_fixture.c` — end-to-end test on a real
  chr22 mate triple extracted from the existing
  `data/genomic/na12878/na12878.chr22.lean.mapped.bam`.

## 7. Language bindings

All three follow the V4 Stage 2 pattern.

### 7.1 Python — `python/src/ttio/codecs/mate_info_v2.py`

ctypes wrapper following `fqzcomp_nx16_z.py`'s shape (lazy-load
`libttio_rans.so` from `TTIO_RANS_LIB_PATH`).

```python
def encode(
    mate_chrom_ids: np.ndarray,    # int32
    mate_positions: np.ndarray,    # int64
    template_lengths: np.ndarray,  # int32
    own_chrom_ids: np.ndarray,     # uint16
    own_positions: np.ndarray,     # int64
) -> bytes: ...

def decode(
    encoded: bytes,
    own_chrom_ids: np.ndarray,     # uint16
    own_positions: np.ndarray,     # int64
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Returns (mate_chrom_ids, mate_positions, template_lengths)."""
```

No pure-Python fallback: if `_HAVE_NATIVE_LIB` is False at write
time and `opt_disable_inline_mate_info_v2 == False`, raise a clear
error pointing at the native lib build instructions or the opt-out
flag. (Read of v1 files works without the native lib; only v2
write/read needs it.)

### 7.2 Java — `java/src/main/java/global/thalion/ttio/codecs/MateInfoV2.java`

Mirrors `FqzcompNx16Z.encodeV4` shape exactly. JNI bridge in
`native/src/ttio_rans_jni.c::Java_global_thalion_ttio_codecs_MateInfoV2_encodeNative` /
`_decodeNative`.

CLI tool: `java/src/main/java/global/thalion/ttio/tools/MateInfoV2Cli.java`
(takes a corpus name, emits encoded blob to stdout for the
cross-language gate).

### 7.3 ObjC — `objc/Source/Codecs/TTIOMateInfoV2.{h,m}`

Direct link to `ttio_mate_info_v2_encode` / `_decode` (no JNI).
Mirrors `TTIOFqzcompNx16Z`'s shape. CLI tool: `objc/Tools/TtioMateInfoV2Cli.m`.

## 8. Writer/reader dispatch

### 8.1 Writer

New flag `WrittenGenomicRun.opt_disable_inline_mate_info_v2: bool =
False` in all three languages.

Writer logic in `_write_mate_info_subgroup` (Python) and equivalents:

- If `opt_disable_inline_mate_info_v2 == True` OR no mate_info data
  is present → fall through to existing v1 write path (unchanged).
- Otherwise → call `mate_info_v2.encode(...)`, write resulting bytes
  as `signal_channels/mate_info/inline_v2` uint8 dataset with
  `@compression = 13`.

`signal_codec_overrides` keys (`mate_info_chrom`, `mate_info_pos`,
`mate_info_tlen`) become **disallowed** when
`opt_disable_inline_mate_info_v2 == False`. Error message points at
the opt-out flag, mirroring the v1.6 pattern that disallowed
`signal_codec_overrides['positions' / 'flags' / 'mapping_qualities']`.

### 8.2 Reader

In `GenomicRun.read` (or equivalent), check for
`signal_channels/mate_info/inline_v2` first.

- If present: read uint8 blob, call `mate_info_v2.decode(blob,
  own_chrom_ids, own_positions)`. Requires
  `genomic_index/positions` and `genomic_index/chromosome_ids` to
  have been read first — enforce read order.
- If absent: fall through to existing v1 read path (read
  `mate_info/{chrom,pos,tlen}` separately). Unchanged.

A v1.6 reader on a v1.7 file: encounters `inline_v2` dataset with
`@compression = 13`, doesn't recognize the codec id, raises a clear
error: "unknown compression id 13 in
signal_channels/mate_info/inline_v2 — file written by TTI-O v1.7+;
upgrade reader."

## 9. Validation

### 9.1 Layer 1 — Phase 0 invariants (C)

See §5. Native ctests in `native/tests/`.

### 9.2 Layer 2 — v1↔v2 oracle (Python)

`python/tests/integration/test_mate_info_v2_v1_oracle.py` — for
each of the 4 corpora:

- Encode via v1 (set `opt_disable_inline_mate_info_v2 = True`),
  decode → `tuple_v1`.
- Encode via v2 (default), decode → `tuple_v2`.
- Assert `tuple_v1 == tuple_v2` per record.

Catches encoder/decoder asymmetry without an external reference.

### 9.3 Layer 3 — cross-language byte-exact (V4 Stage 2 pattern)

`python/tests/integration/test_mate_info_v2_cross_language.py` —
for each corpus × language, encode through that language's binding,
assert byte-identical encoded blob across {Python, Java, ObjC}.

4 corpora × 3 languages = **12 byte-exact assertions**. Uses Java +
ObjC CLI tools (`MateInfoV2Cli` / `TtioMateInfoV2Cli`).

### 9.4 Layer 4 — chr22 ratio gate

`python/tests/integration/test_mate_info_v2_compression_gate.py` —
chr22 NA12878 lean+mapped end-to-end:

- v1 baseline → expect ~105 MB total file size (current v1.6).
- v2 default → expect ~97-98 MB (savings target: 7-8 MB).
- **Hard gate:** if savings < 5 MB, fail.

Per-substream byte breakdown logged to
`docs/benchmarks/2026-MM-DD-mate-info-v2-results.md`.

### 9.5 Test corpora

Already on disk per `project_tti_o_v1_2_codecs.md`:

- chr22 NA12878 100bp WGS — `data/genomic/na12878/na12878.chr22.lean.mapped.bam`
- NA12878 WES (chr22, capture, ~95bp)
- HG002 Illumina 2×250 (chr22, 1M-read subset)
- HG002 PacBio HiFi (low mate-pair density — mostly MF==2; tests the
  unmapped-mate path)

## 10. Phase plan

Mirrors V4 Stage 2's successful shape: spec proof → native kernel →
per-language bindings → cross-language gate → writer/reader dispatch
→ ratio gate. The implementation plan produced from this spec will
order tasks accordingly.

| Phase | Scope | Output | Gate |
|-------|-------|--------|------|
| 0 | Spec & invariants doc | This document | User approval |
| 1 | C kernel + 8 invariant ctests + parameterized stress ctest | `native/src/mate_info_v2.{c,h}`; `native/tests/test_mate_info_v2_*.c` | All ctests + stress test pass |
| 2 | Python ctypes wrapper + v1↔v2 oracle test | `python/src/ttio/codecs/mate_info_v2.py`; `test_mate_info_v2_v1_oracle.py` | Oracle test green on all 4 corpora |
| 3 | Java JNI binding + CLI tool + round-trip test | `MateInfoV2.java`; `Java_..._MateInfoV2_*` JNI; `MateInfoV2Cli.java` | Round-trip green; CLI emits valid blob |
| 4 | ObjC direct link + CLI tool + round-trip test | `TTIOMateInfoV2.{h,m}`; `TtioMateInfoV2Cli.m` | Round-trip green; CLI emits valid blob |
| 5 | Cross-language byte-exact gate | `test_mate_info_v2_cross_language.py` (12 assertions) | All 12 byte-exact green |
| 6 | Writer/reader dispatch in 3 languages + opt-out flag | `opt_disable_inline_mate_info_v2` flag; v1↔v2 dispatch in writers and readers | Existing M82/M89 matrix tests still green + new dispatch tests |
| 7 | chr22 ratio measurement + format-spec §10.X + CHANGELOG | `docs/benchmarks/2026-MM-DD-mate-info-v2-results.md`; format-spec update | Ratio gate ≥5 MB savings on chr22 |

**Sequencing rules:**

- Phase 1 must complete before Phases 2/3/4 (they depend on the C
  library symbols).
- Phases 2/3/4 are independent and can be parallelized via subagents
  per `superpowers:dispatching-parallel-agents` (V4 Stage 3 used
  this).
- Phase 5 gates Phase 6 (no point wiring writers if cross-language
  disagrees on bytes).
- Phase 7 is the final acceptance gate.

**Estimated task count:** ~15 tasks (matches V4 Stage 2's task
count, executed in a single session).

## 11. Risks (per `feedback_phase_0_spec_proof`)

- **Adversarial mate patterns at scale.** PacBio HiFi has mostly
  MF==2 (mate unmapped or absent). Phase 1 stress test covers
  all-unmapped pattern explicitly. WES capture data has unusual
  insert-size distributions; covered by the 4-corpus cross-language
  gate.
- **chrom_id sentinel collision.** L1 chrom_ids are uint16 (0xFFFF
  reserved for "unmapped own chrom"). NS varint encodes
  `mate_chrom_id ≥ 0`, so no overlap. The encoder asserts
  `mate_chrom_id != 0xFFFF` before emitting NS bytes; documented in
  §4.6.
- **Read-order dependency.** mate_info_v2 decode requires
  `genomic_index/positions` and `genomic_index/chromosome_ids` to be
  read first. The reader enforces this with an explicit dependency
  check; missing-input error message points at the dependency.
- **Default-on rollout.** v1.7 default ON means v1.6 readers fail on
  v1.7 files. Mitigated by clear error message + opt-out flag for
  users who must round-trip with v1.6. CHANGELOG and migration docs
  call out the break.

## 12. Out of scope (deferred)

- **REF_DIFF v2 (sequences channel)** — separate cycle, ~3-5 MB
  savings, will use the same shared-C-kernel pattern established here.
- **NameTokenized v2 (read_names channel)** — separate cycle,
  ~3-4 MB savings.
- **#10 offsets-cumsum** — independent structural change. Memory
  recommended bundling with #11, but the codec work and the HDF5
  framing change have no shared infrastructure; bundling adds
  coordination risk without simplifying either.
- **Java/ObjC mate_info v2 perf optimization.** Correctness-and-ratio
  first per V4 Stage 2 precedent. Perf is a Stage-2-style follow-up
  if mate_info encode wall ever shows up in profiles.
- **Adaptive context coders for substreams.** Per L2 V3 lesson,
  static rANS-O0 at chr22 scale is near-optimal for the substream
  distributions; adaptive RC adds complexity without ratio benefit.

## 13. References

- Memory: `project_tti_o_v1_2_codecs.md` Status 2026-05-03 evening
  (v1.6 follow-up close-out, #11 scoping)
- Memory: `feedback_phase_0_spec_proof.md` (wire-format-breaking
  codec discipline)
- Memory: `feedback_perf_pivot_single_lang.md` (linkage-shape
  guidance — distinguished from this spec since mate_info v2 is a
  ratio gap not a perf gap)
- V4 Stage 2 spec: `docs/superpowers/specs/2026-05-02-l2x-m94z-richer-context-stage2-design.md`
- v1.6 L4 spec: `docs/superpowers/plans/2026-05-03-drop-genomic-signal-channel-int-dups.md`
- L1 chromosomes decomp spec: `docs/superpowers/specs/2026-05-01-l1-chromosomes-decomp-design.md`
- SAM/BAM spec: <https://samtools.github.io/hts-specs/SAMv1.pdf>
- CRAM 3.1 spec (substream taxonomy reference): <https://samtools.github.io/hts-specs/CRAMv3.pdf>
