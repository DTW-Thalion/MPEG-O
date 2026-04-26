# HANDOFF — M86 Phase C: Wire rANS + NAME_TOKENIZED into the cigars channel

**Scope:** Wire `Compression.RANS_ORDER0`,
`Compression.RANS_ORDER1`, and `Compression.NAME_TOKENIZED`
(M79 codec ids `4`, `5`, `8`) into the
`signal_channels/cigars` channel of genomic runs. Caller picks
the codec; the validation map accepts all three; the dispatch
routes through the appropriate codec based on `@compression`.
The rANS path uses a length-prefix-concat serialisation
(`varint(len) + bytes` per CIGAR); the NAME_TOKENIZED path
uses the codec's native `list[str] → bytes` API. Same
schema-lift pattern as Phase E (compound → flat 1-D uint8).
`mate_info` (the third compound channel) is explicitly out of
scope. Three languages with two cross-language conformance
fixtures (one per cigars codec).

**Branch from:** `main` after M86 Phase B docs (`cc8de42`).

**IP provenance:** Pure integration work. Reuses the M85 Phase
B NAME_TOKENIZED codec (already clean-room, already
cross-language conformant) and the M86 Phase E schema-lift +
dispatch pattern (already shipped). No new codec
implementation; no third-party source consulted.

---

## 1. Background and codec choice

The M82 storage writes `signal_channels/cigars` as a compound
dataset of shape `[n_reads]` with field `{value: VL_STRING}`.
Same shape as M82's read_names compound that Phase E lifted in
M86 Phase E.

The original WORKPLAN sketched cigars as wanting an
"RLE-then-rANS pipeline" — a hypothetical custom codec that
exploits the digit-letter alternation in CIGAR strings. That
custom codec doesn't exist. Phase C ships **two existing-codec
paths** instead, letting callers pick:

### 1.1 The two codec paths and when each wins

**Path A — `Compression.NAME_TOKENIZED` (M79 id 8).** The codec
tokenises each CIGAR into digit-runs and letter-runs (e.g.
`"100M"` → `[100, "M"]`), then either:
- **Columnar mode**: if all reads have the same token shape,
  emits per-column streams (numeric column delta-encoded,
  string column dictionary-encoded). Great compression on
  uniform CIGARs.
- **Verbatim mode**: if token shapes vary across reads, falls
  back to `varint(len) + bytes` per read — **no compression**,
  essentially raw bytes with a tiny header.

**Path B — `Compression.RANS_ORDER0` or `Compression.RANS_ORDER1`
(M79 ids 4, 5).** The codec sees a flat byte stream produced
by length-prefix-concat serialisation of the CIGAR list
(`varint(len) + bytes` per CIGAR). rANS exploits byte-level
repetition across the whole stream — CIGAR strings have a
limited alphabet (digits + ~9 operator letters MIDNSHP=X), so
order-0 typically achieves 3-5× compression and order-1 even
better.

### 1.2 Which to use under which conditions

| Workload                              | Best choice    | Reason                                          |
|---------------------------------------|----------------|--------------------------------------------------|
| All reads identical CIGAR (e.g. `["100M"] × N`) | NAME_TOKENIZED | Columnar mode → 1-entry dict + delta=0; ~2 bytes/read |
| Mostly uniform with a few variants    | NAME_TOKENIZED | Columnar still hits if ALL reads have same token-count shape |
| **Mixed token-count (typical real WGS)**: indels, soft-clips, hard-clips break uniformity | **RANS_ORDER1** | NAME_TOKENIZED falls back to verbatim → no compression. RANS exploits the limited byte alphabet across the whole stream. |
| Tiny dataset (< 100 reads)            | NAME_TOKENIZED | rANS's 1024-byte order-0 freq table dominates on small inputs |
| Large dataset (> 1000 reads)          | **RANS_ORDER1** | Per-read overhead amortises; byte-level repetition wins |
| Unknown / general default             | **RANS_ORDER1** | More robust across input distributions |

**The honest summary:** for real WGS data (which has indels,
clips, and other variability that breaks token-count
uniformity), **`RANS_ORDER1` is the better default**. It
achieves ~3-5× compression even on the worst case. Use
`NAME_TOKENIZED` only when you know the CIGARs are uniform
(e.g. perfect-match-only synthetic data, or a pre-filtered
subset).

A future custom RLE-then-rANS codec could outperform both by
exploiting the digit-letter alternation explicitly while still
applying entropy coding. That's a future optimisation
milestone if/when needed; Phase C ships the two existing-codec
paths.

### 1.3 mate_info — out of scope

`mate_info` is a 3-field compound (`chrom` VL_STRING, `pos`
int64, `tlen` int32). Compressing it cleanly would require
either per-field schema decomposition (lift the compound to
three separate flat datasets) or per-compound-field codec
dispatch (no infrastructure for this exists). Both are
substantial new design work. Phase C explicitly defers
mate_info; the channel continues to use the existing
compound-write path.

---

## 2. Design

### 2.1 Schema lift on write (mirrors Phase E for cigars)

When `signal_codec_overrides["cigars"]` is set, the writer
skips the M82 compound write for cigars and instead writes a
flat 1-D uint8 dataset (still named `cigars`) containing the
codec output. Sets `@compression == 8` on it. No HDF5 filter.

When the override is not set, the writer uses the existing
M82 compound-write path (no change).

### 2.2 Schema dispatch on read (mirrors Phase E)

In `GenomicRun.__getitem__` (and any other call site that
reads cigars), introduce a `_cigar_at(i)` helper that:

1. Uses cached decoded list if present.
2. Opens the cigars dataset.
3. Dispatches on dataset shape:
   - 1-D uint8 → codec dispatch path (read all bytes → decode
     via `name_tokenizer.decode()` → cache as list[str] → return entry).
   - Compound → existing M82 path (`_compound("cigars")[i]["value"]`).

### 2.3 Cache strategy — TWO acceptable designs

The implementer picks one of:

**Option A (separate cache):** Add a new field `_decoded_cigars:
list[str] | None` parallel to Phase E's `_decoded_read_names`.
Simplest, does not touch shipped Phase E code. Recommended.

**Option B (generalised cache):** Refactor `_decoded_read_names`
+ new `_decoded_cigars` into `_decoded_string_channels: dict[str,
list[str]]` keyed by channel name (`"read_names"` /
`"cigars"`). Cleaner long-term but touches Phase E code.

Either is acceptable. Option A is the lower-risk choice for
Phase C; Option B can be a follow-up refactor if the third
list-of-strings channel ever shows up.

### 2.4 Validation extension

The per-channel allowed-codec map gains a new entry accepting
**three** codecs for cigars:

```python
_ALLOWED_OVERRIDE_CODECS_BY_CHANNEL = {
    "sequences":         {RANS_ORDER0, RANS_ORDER1, BASE_PACK},
    "qualities":         {RANS_ORDER0, RANS_ORDER1, BASE_PACK, QUALITY_BINNED},
    "read_names":        {NAME_TOKENIZED},
    "cigars":            {RANS_ORDER0, RANS_ORDER1, NAME_TOKENIZED},  # Phase C
    "positions":         {RANS_ORDER0, RANS_ORDER1},
    "flags":             {RANS_ORDER0, RANS_ORDER1},
    "mapping_qualities": {RANS_ORDER0, RANS_ORDER1},
}
```

NAME_TOKENIZED is now valid on BOTH `read_names` and `cigars`.
RANS_ORDER0/1 are now valid on cigars (in addition to
sequences, qualities, and the integer channels). Validation
continues to reject:
- NAME_TOKENIZED on sequences/qualities/integer channels
  (binary byte stream / integer-content mismatch).
- BASE_PACK and QUALITY_BINNED on cigars (wrong-content for
  CIGAR strings; BASE_PACK assumes ACGT bytes,
  QUALITY_BINNED assumes Phred values).

The error message for invalid `(channel, codec)` combinations
follows the Phase D/E pattern.

### 2.5 The VL-string serialisation contract for the rANS path

When the override is `RANS_ORDER0` or `RANS_ORDER1`, the
encoder serialises the `list[str]` of CIGARs to a flat byte
stream using length-prefix concatenation:

```
For each cigar in cigars:
    emit varint(len(cigar.encode('ascii')))
    emit cigar.encode('ascii')
```

This is the same wire-level shape as NAME_TOKENIZED's verbatim
mode, minus the 7-byte NAME_TOKENIZED header (since the
self-contained rANS stream already records original_length and
the byte count). The serialised bytes are then encoded via
`rans.encode(bytes, order)`.

The reader reverses: decode the rANS stream → byte buffer →
walk varint-length-prefixed entries → list[str].

**Important**: all CIGARs MUST be 7-bit ASCII per the SAM spec.
The encoder validates this and raises on non-ASCII input
(matches NAME_TOKENIZED's existing constraint). Decoder uses
`bytes.decode('ascii')` strictly.

### 2.6 Encode dispatch extension

For each cigars override, the writer:

1. Validates per §2.4 (channel allowed; codec allowed for
   that channel).
2. Picks the encoder branch by codec id:
   - `RANS_ORDER0` / `RANS_ORDER1`: serialise via length-
     prefix-concat (§2.5), then `rans.encode(bytes, order)`.
   - `NAME_TOKENIZED`: call `name_tokenizer.encode(cigars)`
     directly (the codec already handles the string-list
     input).
3. Writes the encoded bytes as a flat 1-D uint8 dataset (no
   HDF5 filter), sets `@compression == codec_id`.

### 2.7 Decode dispatch extension

In `_cigar_at(i)` (or equivalent helper):

1. Open dataset; check `@compression`.
2. If 0: existing M82 compound path.
3. If 4 or 5: read all bytes → `rans.decode(bytes)` → walk
   varint-length-prefixed entries to reconstruct list[str] →
   cache.
4. If 8: read all bytes → `name_tokenizer.decode(bytes)` →
   cache.
5. Other codec ids: raise (malformed stream).

The cache stores the fully-decoded `list[str]`; per-read
access slices into the cache.

### 2.8 Lossless round-trip

Both rANS paths and NAME_TOKENIZED are lossless on any ASCII
string list. Round-trip is byte-exact for either codec choice.
CIGAR strings are 7-bit ASCII per SAM spec; no encoding
concerns.

### 2.9 No back-compat shim

Files written with the cigars override are unreadable by
pre-M86-Phase-C readers (the cigars dataset shape changed from
compound to flat uint8). Discipline matches Phase A/D/E
(Binding Decision §90).

---

## 3. Binding Decisions (continued from M86 Phase B §115–§119)

| #   | Decision | Rationale |
|-----|----------|-----------|
| 120 | The `cigars` channel accepts THREE codec overrides: `RANS_ORDER0`, `RANS_ORDER1`, `NAME_TOKENIZED`. The caller picks based on workload characteristics. | Different CIGAR distributions favour different codecs: NAME_TOKENIZED's columnar mode wins on uniform CIGARs (small per-read overhead), but falls back to verbatim/no-compression on mixed token-count data. rANS wins on mixed/realistic data via byte-level entropy coding over the limited CIGAR alphabet (digits + ~9 operators). Allowing both codecs lets callers optimise for their workload; the §1.2 selection table documents the tradeoffs. |
| 121 | The recommended **default for general use is `RANS_ORDER1`**. NAME_TOKENIZED is the niche choice for known-uniform CIGARs. | Real WGS data has indels, soft-clips, and hard-clips that break token-count uniformity, sending NAME_TOKENIZED to its no-compression verbatim mode. rANS_ORDER1 achieves ~3-5× compression on realistic mixed data via byte-level entropy. NAME_TOKENIZED only beats rANS on synthetic-uniform inputs or pre-filtered subsets. Documentation must call this out explicitly so callers don't pick NAME_TOKENIZED expecting compression on real data. |
| 122 | The rANS-on-cigars path uses a length-prefix-concat serialisation (`varint(len) + bytes` per CIGAR). This is wire-level identical to NAME_TOKENIZED's verbatim mode, minus the 7-byte NAME_TOKENIZED header. | Simplest possible deterministic serialisation for a list of variable-length ASCII strings. Reusing NAME_TOKENIZED's verbatim format would require parsing through the NAME_TOKENIZED header — wasted bytes since rANS's own self-contained header already records original_length. The length-prefix-concat shape is its own contract for the rANS path and is documented in `docs/format-spec.md` §10.6 (extended). |
| 123 | The `_decoded_cigars` cache is a new field separate from `_decoded_read_names` (Option A from §2.3). | Lower-risk than refactoring shipped Phase E code. Generalisation can be a follow-up if a third list-of-strings channel appears. |
| 124 | `mate_info` is explicitly out of Phase C scope. The channel continues to use the existing compound-write path; no override accepted. | Per-field codec dispatch on a 3-field compound (chrom VL_STRING + pos int64 + tlen int32) requires substantial new infrastructure: either per-field schema decomposition (lift one compound to three flat datasets) or per-compound-field dispatch. Both are new design work; deferred. |

---

## 4. API surface (no changes for callers; new values accepted)

### 4.1 Python

The `WrittenGenomicRun.signal_codec_overrides` field signature
is unchanged. Callers pick one of three codecs for cigars:

```python
# Recommended default for real WGS data:
run = WrittenGenomicRun(
    # ... existing fields ...
    signal_codec_overrides={
        "cigars": Compression.RANS_ORDER1,  # new in Phase C
    },
)

# Or, if you know your CIGARs are uniform (synthetic data,
# perfect-match-only filtered subset):
run = WrittenGenomicRun(
    # ... existing fields ...
    signal_codec_overrides={
        "cigars": Compression.NAME_TOKENIZED,  # new in Phase C
    },
)
```

Mixed overrides — Phase A + B + D + E + C all at once — work
in one call:

```python
signal_codec_overrides={
    "sequences":         Compression.BASE_PACK,
    "qualities":         Compression.QUALITY_BINNED,
    "read_names":        Compression.NAME_TOKENIZED,
    "cigars":            Compression.RANS_ORDER1,        # new in Phase C
    "positions":         Compression.RANS_ORDER1,
    "flags":             Compression.RANS_ORDER0,
    "mapping_qualities": Compression.RANS_ORDER1,
}
```

### 4.2 Objective-C

```objc
// Default for general data:
writtenRun.signalCodecOverrides = @{
    @"cigars": @(TTIOCompressionRANS_ORDER1),  // new in Phase C
};

// For known-uniform CIGARs:
writtenRun.signalCodecOverrides = @{
    @"cigars": @(TTIOCompressionNAME_TOKENIZED),
};
```

### 4.3 Java

```java
// Default for general data:
writtenRun.setSignalCodecOverrides(Map.of(
    "cigars", Compression.RANS_ORDER1  // new in Phase C
));

// For known-uniform CIGARs:
writtenRun.setSignalCodecOverrides(Map.of(
    "cigars", Compression.NAME_TOKENIZED
));
```

---

## 5. On-disk schema

### 5.1 M82 baseline (no override) — unchanged

```
/study/genomic_runs/<name>/signal_channels/
    cigars: COMPOUND[n_reads] {
        value: VL_STRING
    }
```

### 5.2 Phase C with NAME_TOKENIZED override

```
/study/genomic_runs/<name>/signal_channels/
    cigars: UINT8[encoded_length], no HDF5 filter
        @compression: UINT8 = 8 (NAME_TOKENIZED)
```

The dataset bytes are the self-contained NAME_TOKENIZED stream
from M85 Phase B (header + columnar-or-verbatim body).

### 5.3 Phase C with rANS override

```
/study/genomic_runs/<name>/signal_channels/
    cigars: UINT8[encoded_length], no HDF5 filter
        @compression: UINT8 = 4 (RANS_ORDER0) or 5 (RANS_ORDER1)
```

The dataset bytes are the self-contained rANS stream from M83.
The decoded byte buffer is interpreted as a length-prefix-concat
sequence: each entry is `varint(len) + len bytes` of the next
CIGAR, repeated until the buffer is exhausted. The total number
of CIGARs equals the run's `read_count` (read from
`@read_count` on the parent group, or from the index).

Same dataset name and shape as Phase C with NAME_TOKENIZED;
the `@compression` value disambiguates the decode path.

---

## 6. Tests

### 6.1 Python — extend `python/tests/test_m86_genomic_codec_wiring.py`

Add 9 new test methods (numbering continues from M86 Phase B
which ended around test #38):

39. **`test_round_trip_cigars_rans_order1`** — write a run
    with `signal_codec_overrides={"cigars":
    Compression.RANS_ORDER1}` using mixed CIGARs (e.g., 80%
    `"100M"`, 10% `"99M1D"`, 10% `"50M50S"`, 1000 reads
    total). Reopen, iterate all reads, verify each
    `aligned_read.cigar` matches the input byte-exact.
40. **`test_round_trip_cigars_name_tokenized_uniform`** — all
    reads have the same CIGAR (`["100M"] * 100`). Verify
    columnar mode kicks in (assert
    `Compression.NAME_TOKENIZED` succeeds and round-trips);
    NAME_TOKENIZED wire size on this input < 50 bytes.
41. **`test_round_trip_cigars_name_tokenized_mixed`** — same
    mixed-CIGAR input as #39 but with NAME_TOKENIZED. Verify
    round-trip; note (in the test docstring) that this falls
    back to verbatim mode and produces a much larger wire than
    rANS.
42. **`test_size_comparison_cigars_codecs`** — write the same
    1000-read mixed-CIGAR input three ways: no override,
    RANS_ORDER1, NAME_TOKENIZED. Compare on-disk dataset
    sizes. Assert RANS_ORDER1 < NAME_TOKENIZED < no-override
    (or at minimum, RANS_ORDER1 is meaningfully smaller than
    no-override). Print the three sizes so the comparison is
    visible in test output. **This test demonstrates §1.2's
    selection guidance.**
43. **`test_size_win_cigars_uniform`** — same comparison on
    uniform input (`["100M"] * 1000`). Assert NAME_TOKENIZED <
    RANS_ORDER1 (or at minimum, NAME_TOKENIZED's wire size on
    this input is < 100 bytes — the columnar-mode win).
44. **`test_attribute_set_correctly_cigars`** — write with
    each of the three accepted codecs; verify the cigars
    dataset is 1-D uint8 with `@compression == 4`, `5`, or `8`
    respectively.
45. **`test_back_compat_cigars_unchanged`** — write without
    the cigars override. Verify `cigars` is still written as
    the M82 compound; round-trips via existing read path.
46. **`test_reject_base_pack_on_cigars`** — `signal_codec_overrides=
    {"cigars": Compression.BASE_PACK}` raises `ValueError` at
    write time (cigars rejects content-incompatible codecs).
47. **`test_round_trip_full_seven_overrides`** — Phase B's
    test #37 covered six overrides. Extend it for SEVEN
    overrides: sequences=BASE_PACK, qualities=QUALITY_BINNED,
    read_names=NAME_TOKENIZED, **cigars=RANS_ORDER1**
    (recommended default), positions=RANS_ORDER1,
    flags=RANS_ORDER0, mapping_qualities=RANS_ORDER1. All
    seven round-trip correctly.

Plus extend `test_cross_language_fixtures` to include both new
fixtures (rANS path AND NAME_TOKENIZED path on cigars).

### 6.2 ObjC — extend `objc/Tests/TestM86GenomicCodecWiring.m`

Same 9 new test cases. Cross-language fixtures loaded from
`objc/Tests/Fixtures/genomic/m86_codec_cigars_rans.tio` and
`objc/Tests/Fixtures/genomic/m86_codec_cigars_name_tokenized.tio`.
Target ≥ 20 new assertions.

### 6.3 Java — extend
`java/src/test/java/global/thalion/ttio/genomics/M86CodecWiringTest.java`

Same 9 new test cases. Cross-language fixtures loaded from
`java/src/test/resources/ttio/fixtures/genomic/m86_codec_cigars_rans.tio`
and
`java/src/test/resources/ttio/fixtures/genomic/m86_codec_cigars_name_tokenized.tio`.

### 6.4 Cross-language conformance fixtures

Generate **two** fixtures from the Python writer (one per
codec path) so cross-language conformance covers both:

**Fixture A — `m86_codec_cigars_rans.tio`** (the recommended
default for real data). 100-read run with mixed CIGARs:

```python
cigars = []
for i in range(100):
    if i % 10 < 8:    cigars.append("100M")        # 80% perfect-match
    elif i % 10 == 8: cigars.append("99M1D")       # 10% with deletion
    else:             cigars.append("50M50S")      # 10% with soft-clip
```

Override: `{"cigars": Compression.RANS_ORDER1}`. This is the
realistic data pattern; rANS exploits byte-level repetition
across the whole stream and produces a meaningful compression
ratio.

**Fixture B — `m86_codec_cigars_name_tokenized.tio`** (the
columnar-win path). 100-read run with all-uniform CIGARs:

```python
cigars = ["100M"] * 100
```

Override: `{"cigars": Compression.NAME_TOKENIZED}`. This is
the columnar-mode sweet spot; the wire stream is tiny
(~30 bytes for 100 identical CIGARs).

Other channels (sequences, qualities, read_names, integers)
use M82 baseline (no override) in both fixtures so each
isolates the cigars wiring path.

---

## 7. Documentation

### 7.1 `docs/codecs/name_tokenizer.md`

Update §8 ("Wired into / forward references"): NAME_TOKENIZED
is now wired into BOTH `read_names` (Phase E) AND `cigars`
(Phase C). Both use the same schema-lift pattern.

### 7.2 `docs/format-spec.md`

Update §10.4 trailing summary: id 8 now applies to cigars too.
Update §10.6 (read_names schema lift) — extend the section to
also document the cigars schema lift (or add a parallel §10.8).

### 7.3 `CHANGELOG.md`

Add M86 Phase C entry under `[Unreleased]`. Update header.

### 7.4 `WORKPLAN.md`

Update M86 section header from "Phases A, B, D, and E shipped"
to "Phases A, B, C, D, and E shipped". Phase C subsection:
mark cigars wiring complete; mate_info still deferred.

---

## 8. Out of scope

- **mate_info compression.** Per-field codec dispatch on a
  3-field compound requires substantial new infrastructure;
  deferred. The channel stays in compound storage.
- **Custom RLE-then-rANS codec for cigars.** A future
  optimisation milestone could ship a CIGAR-specific codec
  that exploits the digit-letter alternation more aggressively
  than NAME_TOKENIZED. M86 Phase C ships the working primitive;
  the optimisation is deferred.
- **MS-side wiring.** Genomic-only.

---

## 9. Acceptance Criteria

### Python
- [ ] All existing tests pass (zero regressions vs `cc8de42`).
- [ ] All 9 new tests in
      `python/tests/test_m86_genomic_codec_wiring.py` pass.
- [ ] **Both** cigars fixtures committed:
      `m86_codec_cigars_rans.tio` and
      `m86_codec_cigars_name_tokenized.tio`.
- [ ] Validation accepts `{RANS_ORDER0, RANS_ORDER1,
      NAME_TOKENIZED}` on cigars; rejects BASE_PACK and
      QUALITY_BINNED on cigars.
- [ ] Test #42 (`test_size_comparison_cigars_codecs`) prints
      and asserts the expected ordering: RANS_ORDER1 <
      NAME_TOKENIZED < no-override on the realistic mixed
      input. This makes the §1.2 selection guidance
      visible-and-tested.
- [ ] Back-compat: empty overrides leaves cigars as the M82
      compound.

### Objective-C
- [ ] All existing tests pass (zero regressions vs the 2370
      PASS baseline + 2 pre-existing M38 Thermo failures).
- [ ] 9 new test methods pass byte-exact against both Python
      fixtures.
- [ ] ≥ 20 new assertions.

### Java
- [ ] All existing tests pass (zero regressions vs the 491/0/0/0
      baseline → ≥ 500/0/0/0 after M86 Phase C).
- [ ] 9 new test methods pass.
- [ ] Both cross-language fixtures read byte-exact.

### Cross-Language
- [ ] All three implementations read **both**
      `m86_codec_cigars_rans.tio` and
      `m86_codec_cigars_name_tokenized.tio` byte-exact-on-decoded
      (every read's `cigar` field matches the original Python
      input).
- [ ] `docs/codecs/name_tokenizer.md` §8 updated to reflect
      cigars wiring AND the NAME_TOKENIZED-vs-rANS selection
      guidance.
- [ ] `docs/codecs/rans.md` §7 updated to mention cigars as a
      new applicable channel for rANS.
- [ ] `docs/format-spec.md` summary updated; §10.6 (or a new
      §10.8) documents the cigars schema lift AND BOTH wire
      formats (NAME_TOKENIZED-stream vs rANS-of-length-prefix-
      concat) AND the §1.2 selection guidance.
- [ ] `CHANGELOG.md` M86 Phase C entry committed; includes the
      selection-guidance summary.
- [ ] `WORKPLAN.md` M86 Phase C status flipped to SHIPPED.

---

## 10. Gotchas

134. **The cigars channel uses the same schema-lift pattern as
     Phase E's read_names** (compound → flat uint8). Reuse the
     dispatch mechanism without re-implementing it. The two
     channels share the dispatch shape but have separate
     dataset names and separate caches.

135. **NAME_TOKENIZED's columnar mode is highly effective on
     uniform CIGARs but degrades to no compression on
     mixed-token-count input.** A run of 1000 identical "100M"
     reads compresses to a wire stream of < 50 bytes via the
     1-entry dict + delta=0 numeric column. The same 1000
     reads with mixed indel/clip CIGARs falls back to
     verbatim mode and produces a wire stream essentially the
     size of the raw bytes. **rANS is the safer default for
     real data**; document this in the codec-selection table
     (§1.2) and surface it in any user-facing docs.

136. **CIGAR strings can be `"*"`** (some pipelines emit it
     for unmapped reads). Both rANS and NAME_TOKENIZED handle
     it transparently as a single ASCII byte sequence. Don't
     special-case empty strings — the SAM spec doesn't allow
     empty CIGARs (`"*"` is the unmapped sentinel).

137. **`mate_info` validation must continue to reject all codec
     overrides.** Phase C's allowed-codec map does NOT add a
     `mate_info` entry; the validation block continues to
     reject any override targeting it. Add an explicit test
     for this rejection.

138. **Cigars cache is per-instance** (Binding Decision §123
     follows §114). Two open `GenomicRun` objects on the same
     file each decode independently. Document in the
     `GenomicRun` docstring alongside the existing
     `_decoded_read_names` note.

139. **The rANS-on-cigars path uses length-prefix-concat
     (not NAME_TOKENIZED-verbatim format).** The two encodings
     would produce different byte streams for the same input
     even though both are "list[str] → bytes". When wiring,
     make sure the rANS path uses raw `varint(len) + bytes`
     concatenation directly — don't accidentally call
     NAME_TOKENIZED's encoder and then rANS-encode its output
     (that would be a different codec entirely, with a
     different wire format).

140. **Selection guidance must be discoverable.** Document the
     rANS-vs-NAME_TOKENIZED choice in `docs/codecs/rans.md`,
     `docs/codecs/name_tokenizer.md`, AND
     `docs/format-spec.md` so users find it from any entry
     point. The §1.2 selection table belongs in user-facing
     docs, not just this internal HANDOFF.
