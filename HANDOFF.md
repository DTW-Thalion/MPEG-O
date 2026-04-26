# HANDOFF — M86 Phase C: Wire NAME_TOKENIZED into the cigars channel

**Scope:** Wire `Compression.NAME_TOKENIZED` (M79 codec id `8`)
into the `signal_channels/cigars` channel of genomic runs.
Closes the codec-applicability gap left by Phase E (which only
wired `read_names`) for the second VL_STRING-in-compound
channel. Same schema-lift pattern as Phase E (compound → flat
1-D uint8). `mate_info` (the third compound channel) is
explicitly out of scope; it has no clean codec match without
per-field decomposition. Three languages with one cross-language
conformance fixture.

**Branch from:** `main` after M86 Phase B docs (`cc8de42`).

**IP provenance:** Pure integration work. Reuses the M85 Phase
B NAME_TOKENIZED codec (already clean-room, already
cross-language conformant) and the M86 Phase E schema-lift +
dispatch pattern (already shipped). No new codec
implementation; no third-party source consulted.

---

## 1. Background and codec-fit rationale

The M82 storage writes `signal_channels/cigars` as a compound
dataset of shape `[n_reads]` with field `{value: VL_STRING}`.
Same shape as M82's read_names compound that Phase E lifted in
M86 Phase E.

The original WORKPLAN sketched cigars as wanting an
"RLE-then-rANS pipeline" — a hypothetical custom codec that
exploits the digit-letter alternation in CIGAR strings. That
custom codec doesn't exist; M85 didn't ship it; Phase C
doesn't plan to ship it.

**The pragmatic choice:** apply NAME_TOKENIZED to cigars. CIGAR
strings are structurally well-suited to NAME_TOKENIZED's
columnar tokeniser — they're already digit-runs alternating
with letter-runs (`100M`, `50M2D48M`). The columnar mode
detects when all reads have the same CIGAR shape (very common
in WGS data dominated by perfect-match reads like `100M`,
`100M`, `100M`, ...) and compresses via a tiny dictionary; the
verbatim mode handles ragged data.

| Pattern                         | Compression with NAME_TOKENIZED |
|---------------------------------|--------------------------------|
| All "100M" (perfect-match WGS)  | excellent (1-entry dict + delta) |
| Mostly "100M", some "99M1D"     | good (small dict)              |
| Highly variable CIGARs          | falls back to verbatim mode    |

A future custom RLE-then-rANS codec could do better than
NAME_TOKENIZED on the highly-variable case (~3:1 typical),
but for the common WGS case the gap is small. Phase C
delivers a working primitive; the optimisation milestone is
deferred.

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

The per-channel allowed-codec map gains a new entry:

```python
_ALLOWED_OVERRIDE_CODECS_BY_CHANNEL = {
    "sequences":         {RANS_ORDER0, RANS_ORDER1, BASE_PACK},
    "qualities":         {RANS_ORDER0, RANS_ORDER1, BASE_PACK, QUALITY_BINNED},
    "read_names":        {NAME_TOKENIZED},
    "cigars":            {NAME_TOKENIZED},                # new in Phase C
    "positions":         {RANS_ORDER0, RANS_ORDER1},
    "flags":             {RANS_ORDER0, RANS_ORDER1},
    "mapping_qualities": {RANS_ORDER0, RANS_ORDER1},
}
```

NAME_TOKENIZED is now valid on BOTH `read_names` and `cigars`.
Validation continues to reject NAME_TOKENIZED on
`sequences`/`qualities`/integer channels (Binding Decision §113
extended): the codec tokenises strings, not binary byte streams
or integer arrays.

The error message for invalid `(channel, codec)` combinations
follows the Phase D/E pattern.

### 2.5 Lossless round-trip

NAME_TOKENIZED is lossless on any ASCII string list (M85 Phase
B §1). When wired into cigars, the channel round-trips
byte-exact. CIGAR strings are 7-bit ASCII per SAM spec; no
encoding concerns.

### 2.6 No back-compat shim

Files written with the cigars override are unreadable by
pre-M86-Phase-C readers (the cigars dataset shape changed from
compound to flat uint8). Discipline matches Phase A/D/E
(Binding Decision §90).

---

## 3. Binding Decisions (continued from M86 Phase B §115–§119)

| #   | Decision | Rationale |
|-----|----------|-----------|
| 120 | NAME_TOKENIZED is now valid on BOTH `read_names` AND `cigars`. The validation map's `cigars` entry is `{NAME_TOKENIZED}` only (no other codecs apply). | CIGAR strings are structurally similar to read names: ASCII strings with potential per-position regularity (typical WGS reads have identical CIGARs like "100M"). NAME_TOKENIZED's columnar mode exploits this; verbatim mode handles the ragged case. Other codecs are wrong-content for VL_STRING channels per the existing rejection rules. |
| 121 | The `_decoded_cigars` cache is a new field separate from `_decoded_read_names` (Option A from §2.3). | Lower-risk than refactoring shipped Phase E code. Generalisation can be a follow-up if a third list-of-strings channel appears. |
| 122 | `mate_info` is explicitly out of Phase C scope. The channel continues to use the existing compound-write path; no override accepted. | Per-field codec dispatch on a 3-field compound (chrom VL_STRING + pos int64 + tlen int32) requires substantial new infrastructure: either per-field schema decomposition (lift one compound to three flat datasets) or per-compound-field dispatch. Both are new design work; deferred. |

---

## 4. API surface (no changes for callers; new value accepted)

### 4.1 Python

The `WrittenGenomicRun.signal_codec_overrides` field signature
is unchanged. Callers can now pass `Compression.NAME_TOKENIZED`
as the value for the `"cigars"` key:

```python
run = WrittenGenomicRun(
    # ... existing fields ...
    signal_codec_overrides={
        "cigars": Compression.NAME_TOKENIZED,  # new in Phase C
    },
)
```

Mixed overrides — including Phase B integer-channel + Phase E
read_names + Phase C cigars — all work in one call:

```python
signal_codec_overrides={
    "sequences":         Compression.BASE_PACK,
    "qualities":         Compression.QUALITY_BINNED,
    "read_names":        Compression.NAME_TOKENIZED,
    "cigars":            Compression.NAME_TOKENIZED,    # new in Phase C
    "positions":         Compression.RANS_ORDER1,
    "flags":             Compression.RANS_ORDER0,
    "mapping_qualities": Compression.RANS_ORDER1,
}
```

### 4.2 Objective-C

```objc
writtenRun.signalCodecOverrides = @{
    @"cigars": @(TTIOCompressionNAME_TOKENIZED),  // new in Phase C
};
```

### 4.3 Java

```java
writtenRun.setSignalCodecOverrides(Map.of(
    "cigars", Compression.NAME_TOKENIZED  // new in Phase C
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

Same shape as Phase E's read_names schema lift.

---

## 6. Tests

### 6.1 Python — extend `python/tests/test_m86_genomic_codec_wiring.py`

Add 6 new test methods (numbering continues from M86 Phase B
which ended around test #38):

39. **`test_round_trip_cigars_name_tokenized`** — write a run
    with `signal_codec_overrides={"cigars":
    Compression.NAME_TOKENIZED}` using a mix of CIGAR strings
    (e.g., `["100M", "100M", "100M", "50M50S", "100M",
    "99M1D"]`). Reopen, iterate all reads, verify each
    `aligned_read.cigar` matches the input byte-exact.
39b. **`test_round_trip_cigars_uniform`** — all reads have the
     same CIGAR (`["100M"] * 100`). Verify columnar mode kicks
     in (single dictionary entry); compression is excellent
     (target wire size < 50 bytes).
40. **`test_size_win_cigars`** — write a 1000-read run with
    structured CIGARs (`"100M"` for 80%, `"99M1D"` for 15%,
    `"50M50S"` for 5%) both with and without NAME_TOKENIZED.
    Verify the compressed `signal_channels/cigars` dataset is
    significantly smaller than the M82-compound storage size.
41. **`test_attribute_set_correctly_cigars`** — write with the
    cigars override; verify the cigars dataset is 1-D uint8
    with `@compression == 8`.
42. **`test_back_compat_cigars_unchanged`** — write without
    the cigars override (or with only other overrides). Verify
    `cigars` is still written as the M82 compound; round-trips
    via existing read path.
43. **`test_reject_rans_on_cigars`** — `signal_codec_overrides=
    {"cigars": Compression.RANS_ORDER0}` raises `ValueError` at
    write time (cigars accepts only NAME_TOKENIZED).
44. **`test_round_trip_full_seven_overrides`** — Phase B's
    test #37 covered six overrides. Extend it (or add a new
    test) for SEVEN overrides: sequences=BASE_PACK,
    qualities=QUALITY_BINNED, read_names=NAME_TOKENIZED,
    cigars=NAME_TOKENIZED, positions=RANS_ORDER1,
    flags=RANS_ORDER0, mapping_qualities=RANS_ORDER1. All
    seven round-trip correctly. The full codec stack on every
    eligible channel.

Plus extend `test_cross_language_fixtures` for the new fixture.

### 6.2 ObjC — extend `objc/Tests/TestM86GenomicCodecWiring.m`

Same 6+ new test cases. Cross-language fixture loaded from
`objc/Tests/Fixtures/genomic/m86_codec_cigars_name_tokenized.tio`.
Target ≥ 15 new assertions.

### 6.3 Java — extend
`java/src/test/java/global/thalion/ttio/genomics/M86CodecWiringTest.java`

Same 6+ new test cases. Cross-language fixture loaded from
`java/src/test/resources/ttio/fixtures/genomic/m86_codec_cigars_name_tokenized.tio`.

### 6.4 Cross-language conformance fixture

Generate one new fixture from the Python writer:
`python/tests/fixtures/genomic/m86_codec_cigars_name_tokenized.tio`.
A 100-read run with deterministic CIGARs constructed via:

```python
cigars = []
for i in range(100):
    if i % 10 < 8:    cigars.append("100M")        # 80% perfect-match
    elif i % 10 == 8: cigars.append("99M1D")       # 10% with deletion
    else:             cigars.append("50M50S")      # 10% with soft-clip
```

Other channels (sequences, qualities, read_names, integers)
use M82 baseline (no override) so the fixture isolates the
cigars wiring.

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
- [ ] All 6+ new tests in
      `python/tests/test_m86_genomic_codec_wiring.py` pass.
- [ ] `m86_codec_cigars_name_tokenized.tio` fixture committed.
- [ ] Validation rejects `(cigars, RANS_ORDER0|RANS_ORDER1|
      BASE_PACK|QUALITY_BINNED)`.
- [ ] Back-compat: empty overrides leaves cigars as the M82
      compound.

### Objective-C
- [ ] All existing tests pass (zero regressions vs the 2370
      PASS baseline + 2 pre-existing M38 Thermo failures).
- [ ] 6+ new test methods pass byte-exact against the Python
      fixture.
- [ ] ≥ 15 new assertions.

### Java
- [ ] All existing tests pass (zero regressions vs the 491/0/0/0
      baseline → ≥ 497/0/0/0 after M86 Phase C).
- [ ] 6+ new test methods pass.
- [ ] Cross-language fixture reads byte-exact.

### Cross-Language
- [ ] All three implementations read
      `m86_codec_cigars_name_tokenized.tio` byte-exact-on-decoded
      (every read's `cigar` field matches the original Python
      input).
- [ ] `docs/codecs/name_tokenizer.md` §8 updated.
- [ ] `docs/format-spec.md` summary updated; §10.6 (or a new
      §10.8) documents the cigars schema lift.
- [ ] `CHANGELOG.md` M86 Phase C entry committed.
- [ ] `WORKPLAN.md` M86 Phase C status flipped to SHIPPED.

---

## 10. Gotchas

134. **The cigars channel uses the same schema-lift pattern as
     Phase E's read_names** (compound → flat uint8). Reuse the
     dispatch mechanism without re-implementing it. The two
     channels share the dispatch shape but have separate
     dataset names and separate caches.

135. **NAME_TOKENIZED's columnar mode is highly effective on
     uniform CIGARs.** A run of 1000 identical "100M" reads
     compresses to a wire stream of < 50 bytes (header + 1-entry
     string dict + delta=0 numeric column for the operator
     count). Tests should include this case to verify the win
     materialises.

136. **CIGAR strings can be empty** (some pipelines emit `"*"`
     for unmapped reads, which NAME_TOKENIZED tokenises as a
     single string token). Verify the fixture and tests
     handle the typical case; don't worry about the empty-string
     edge case unless real-world inputs hit it.

137. **`mate_info` validation must continue to reject all codec
     overrides.** Phase C's allowed-codec map does NOT add a
     `mate_info` entry; the validation block continues to
     reject any override targeting it. Add an explicit test
     for this rejection (parallel to test #43 for cigars
     accepting only NAME_TOKENIZED).

138. **Cigars cache is per-instance** (Binding Decision §121
     follows §114). Two open `GenomicRun` objects on the same
     file each decode independently. Document in the
     `GenomicRun` docstring alongside the existing
     `_decoded_read_names` note.
