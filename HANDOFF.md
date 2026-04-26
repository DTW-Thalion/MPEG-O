# HANDOFF — M86 Phase F: mate_info per-field decomposition

**Scope:** Schema-lift `signal_channels/mate_info` from a
3-field compound dataset to a subgroup containing three flat
datasets (`chrom`, `pos`, `tlen`), each independently
codec-compressible. Caller-facing API gains three "virtual"
channel names — `mate_info_chrom`, `mate_info_pos`,
`mate_info_tlen` — that map to per-field datasets within the
subgroup. Partial overrides allowed. Closes the last channel
gap left by M86 Phase C (which shipped cigars but deferred
mate_info). Three languages with one cross-language conformance
fixture.

**Branch from:** `main` after M86 Phase C docs (`67faa2c`).

**IP provenance:** Pure integration work + a small schema
adaptation. Reuses the M83 rANS codec, the M85 Phase B
NAME_TOKENIZED codec, the M86 Phase A `@compression` attribute
scheme, the M86 Phase B int↔byte serialisation contract, and
the M86 Phase C/E schema-lift dispatch pattern. New: dispatch
on HDF5 link type (dataset vs group) for the top-level
`mate_info` channel. No new codec implementation; no
third-party source consulted.

---

## 1. Background

The M82 storage writes `signal_channels/mate_info` as a
compound dataset of shape `[n_reads]` with three fields:

```
mate_info: COMPOUND[n_reads] {
    chrom: VL_STRING,   // mate chromosome ("*" for unmapped mates)
    pos:   INT64,       // mate position (-1 if unpaired)
    tlen:  INT32,       // template length (insert size; 0 if unpaired)
}
```

Per Binding Decision §124 from M86 Phase C, mate_info was
deferred because compressing it cleanly requires either
per-field schema decomposition (this milestone) or
per-compound-field codec dispatch (no infrastructure exists).

M86 Phase C shipped the cigars half of "VL_STRING / compound
channels"; Phase F closes the gap by decomposing the
mate_info compound into three per-field datasets when any
override is set, with each field independently
codec-compressible.

### 1.1 Per-field codec applicability

Each field has natural codec affinity:

| Field   | Type       | Allowed codecs                        | Best choice                                  |
|---------|------------|----------------------------------------|----------------------------------------------|
| `chrom` | VL_STRING  | RANS_ORDER0, RANS_ORDER1, NAME_TOKENIZED | NAME_TOKENIZED (chromosome names are highly repetitive — typically <30 distinct values like "chr1"..."chr22","chrX","chrY","chrM","*"; one-entry-per-value dictionary wins) |
| `pos`   | INT64      | RANS_ORDER0, RANS_ORDER1               | RANS_ORDER1 (mirrors Phase B for the `positions` channel; mate positions cluster near read positions for paired reads) |
| `tlen`  | INT32      | RANS_ORDER0, RANS_ORDER1               | RANS_ORDER1 (template lengths cluster around the library insert size; high entropy concentration) |

Other codecs (BASE_PACK, QUALITY_BINNED) are wrong-content for
all three fields and rejected.

The chrom field accepts NAME_TOKENIZED (because it's a string
list — same shape as read_names and cigars) AND rANS (because
strings can be byte-streamed via length-prefix-concat — same
contract as cigars rANS path).

---

## 2. Design

### 2.1 Subgroup schema lift

When ANY `mate_info_*` override is set, the writer skips the
M82 compound write and instead creates a subgroup
`signal_channels/mate_info/` containing three child datasets:

```
signal_channels/mate_info/
    chrom: VL_STRING[n_reads] OR UINT8[encoded_length] @compression=4|5|8
    pos:   INT64[n_reads] OR UINT8[encoded_length] @compression=4|5
    tlen:  INT32[n_reads] OR UINT8[encoded_length] @compression=4|5
```

Each field is written either:
- **As its natural dtype with HDF5-filter ZLIB** (no override
  for that specific field); the dataset has no `@compression`
  attribute.
- **As a flat 1-D uint8 with codec output** (override is set
  for that field); the dataset has `@compression == codec_id`,
  no HDF5 filter.

The chrom field's serialisation matches Phase C's cigars
contract:
- For NAME_TOKENIZED override: `name_tokenizer.encode(chroms)`
  → flat uint8 with `@compression == 8`.
- For RANS_ORDER0/1 override: length-prefix-concat
  serialisation (`varint(len) + ascii bytes` per chrom) →
  `rans.encode(buf, order)` → flat uint8 with
  `@compression == 4` or `5`.

The pos and tlen fields' serialisation matches Phase B's
integer-channel contract:
- For RANS_ORDER0/1 override: little-endian byte serialisation
  (`array.astype('<i8'/'<i4').tobytes()`) → `rans.encode(buf,
  order)` → flat uint8 with `@compression == 4` or `5`.

### 2.2 Trigger semantics — partial overrides allowed

Per Decision (i): any one of `mate_info_chrom`,
`mate_info_pos`, `mate_info_tlen` in `signal_codec_overrides`
triggers the subgroup layout. Fields WITHOUT an override use
their natural-dtype HDF5-filter-ZLIB write inside the subgroup
(no `@compression` attribute). Fields WITH an override use
codec dispatch.

If NO `mate_info_*` override is set, the existing M82
compound write path is used (no schema change, no subgroup).
This preserves backward compatibility for all existing
callers.

### 2.3 Read-side dispatch

In `GenomicRun.__getitem__` (and any other call site that
reads mate fields), introduce three helpers:
`_mate_chrom_at(i)`, `_mate_pos_at(i)`, `_mate_tlen_at(i)`.
Each:

1. Opens the `signal_channels/mate_info` link.
2. **Dispatches on HDF5 link type**:
   - If `mate_info` is a **dataset**: M82 compound layout. Use
     existing `_compound("mate_info")[i][<field>]` path.
   - If `mate_info` is a **group**: subgroup layout. Open the
     child dataset for the requested field (`chrom`, `pos`, or
     `tlen`); check `@compression`:
     - `0` (no attribute): read directly as the natural dtype
       (VL_STRING for chrom; INT64 for pos; INT32 for tlen).
     - `4`/`5` (rANS): read all bytes; `rans.decode(buf)` →
       byte buffer; for chrom, walk varint-length-prefix
       entries → list[str]; for pos, interpret bytes as int64
       LE → np.ndarray; for tlen, interpret as int32 LE.
       Cache the decoded result.
     - `8` (NAME_TOKENIZED, only valid for chrom): read all
       bytes; `name_tokenizer.decode(buf)` → list[str]. Cache.

3. Returns the per-read value.

### 2.4 Cache strategy — combined dict

Add a single combined cache field on `GenomicRun`:
`_decoded_mate_info: dict[str, Any]` keyed by field name
(`"chrom"` → list[str]; `"pos"` → np.ndarray int64; `"tlen"`
→ np.ndarray int32). The `_mate_<field>_at(i)` helpers all
write to this dict on first decode.

This cache is separate from `_decoded_byte_channels`,
`_decoded_int_channels`, `_decoded_read_names`,
`_decoded_cigars` per Binding Decision §125.

### 2.5 Validation extension

The per-channel allowed-codec map gains three new entries:

```python
_ALLOWED_OVERRIDE_CODECS_BY_CHANNEL = {
    "sequences":         {RANS_ORDER0, RANS_ORDER1, BASE_PACK},
    "qualities":         {RANS_ORDER0, RANS_ORDER1, BASE_PACK, QUALITY_BINNED},
    "read_names":        {NAME_TOKENIZED},
    "cigars":            {RANS_ORDER0, RANS_ORDER1, NAME_TOKENIZED},
    "positions":         {RANS_ORDER0, RANS_ORDER1},
    "flags":             {RANS_ORDER0, RANS_ORDER1},
    "mapping_qualities": {RANS_ORDER0, RANS_ORDER1},
    "mate_info_chrom":   {RANS_ORDER0, RANS_ORDER1, NAME_TOKENIZED},  # Phase F
    "mate_info_pos":     {RANS_ORDER0, RANS_ORDER1},                  # Phase F
    "mate_info_tlen":    {RANS_ORDER0, RANS_ORDER1},                  # Phase F
}
```

Validation continues to reject:
- BASE_PACK, QUALITY_BINNED, NAME_TOKENIZED on the integer
  fields (`mate_info_pos`, `mate_info_tlen`).
- BASE_PACK, QUALITY_BINNED on `mate_info_chrom`.
- Any override on the bare channel name `mate_info` (the
  caller MUST use the per-field virtual names).

The error message for `(mate_info, <any>)` is special: it
points the caller at the three per-field names with a
brief explanation that mate_info is decomposed at the
per-field level in Phase F.

### 2.6 No back-compat shim

Files written with any `mate_info_*` override have a
`mate_info` group instead of the M82 compound dataset. Pre-
M86-Phase-F readers that hard-code the compound shape will
fail when they hit the group (HDF5 reports "not a dataset" on
the open). Discipline matches the rest of M86 (Binding
Decision §90).

Files written without any `mate_info_*` override remain
identical to M82 / Phase A/B/C/D/E output. Round-trip
identical through all reader versions for those files.

---

## 3. Binding Decisions (continued from M86 Phase C §120–§124)

| #   | Decision | Rationale |
|-----|----------|-----------|
| 125 | When ANY `mate_info_*` override is set, the writer creates a subgroup `signal_channels/mate_info/` (instead of the compound dataset), and writes each of the three fields as a child dataset within that subgroup. | Per-field codec selection requires per-field datasets. The subgroup keeps the namespace tidy — siblings under `signal_channels/` would proliferate (`mate_info_chrom`, etc.) and visually conflate with the existing top-level channels. The subgroup also gives readers a clean shape-based dispatch (link type = group vs dataset). |
| 126 | The per-field overrides are exposed as three flat-dict keys (`mate_info_chrom`, `mate_info_pos`, `mate_info_tlen`) in `signal_codec_overrides`. The bare key `mate_info` is reserved and rejected. | Matches the existing flat-dict API shape. Avoids introducing a nested-dict surface that the rest of the M86 API doesn't have. The bare-key rejection produces a discoverable error pointing at the per-field names. |
| 127 | Partial overrides allowed: any one of the three triggers the subgroup layout; fields without overrides use their natural dtype with HDF5-filter ZLIB inside the subgroup. | Maximum flexibility without code complexity. Callers can compress only chrom (the high-win field) and leave pos/tlen on default ZLIB if they want. |
| 128 | Read-side dispatch is on **HDF5 link type** (dataset vs group) for `mate_info`, NOT on the `@compression` attribute presence on the bare link. | Compound (M82) and subgroup (Phase F) are different HDF5 link types — the cleanest signal. The `@compression` attribute lives on the per-field child datasets within the subgroup, not on the bare `mate_info` link. |
| 129 | The decoded mate-info cache is a single combined `dict[str, Any]` field keyed by field name. Separate from `_decoded_byte_channels`, `_decoded_int_channels`, `_decoded_read_names`, `_decoded_cigars`. | Three fields with three different value types (list[str] / np.ndarray int64 / np.ndarray int32) — a single typed cache would force a union or Object key. The combined dict keyed by field name is the cleanest shape. |
| 130 | The `mate_info_chrom` field accepts THREE codecs (RANS_ORDER0, RANS_ORDER1, NAME_TOKENIZED) — same as the `cigars` channel from Phase C. | Same reasoning as cigars: chromosome names are a list of structured ASCII strings. NAME_TOKENIZED's columnar mode wins big when the chrom values are highly uniform (the typical case — often a single chromosome per run, or chr1..chr22 + sex + mito). rANS is more robust on mixed inputs. Selection guidance documented in `docs/format-spec.md` §10.9. |

---

## 4. API surface (no field-shape changes; new keys accepted)

### 4.1 Python

The `WrittenGenomicRun.signal_codec_overrides` field signature
is unchanged. Callers add per-field keys for mate_info:

```python
# Maximum compression: all three fields overridden.
run = WrittenGenomicRun(
    # ... existing fields ...
    signal_codec_overrides={
        "mate_info_chrom": Compression.NAME_TOKENIZED,  # new in Phase F
        "mate_info_pos":   Compression.RANS_ORDER1,     # new in Phase F
        "mate_info_tlen":  Compression.RANS_ORDER1,     # new in Phase F
    },
)

# Partial: only chrom (the high-win field).
run = WrittenGenomicRun(
    # ... existing fields ...
    signal_codec_overrides={
        "mate_info_chrom": Compression.NAME_TOKENIZED,
    },
)

# Bare key is REJECTED with a clear error pointing at the
# three per-field names.
run = WrittenGenomicRun(
    # ... existing fields ...
    signal_codec_overrides={
        "mate_info": Compression.RANS_ORDER1,  # raises ValueError
    },
)
```

Mixed overrides (every channel from Phase A through F all at
once) work in one call:

```python
signal_codec_overrides={
    "sequences":         Compression.BASE_PACK,
    "qualities":         Compression.QUALITY_BINNED,
    "read_names":        Compression.NAME_TOKENIZED,
    "cigars":            Compression.RANS_ORDER1,
    "positions":         Compression.RANS_ORDER1,
    "flags":             Compression.RANS_ORDER0,
    "mapping_qualities": Compression.RANS_ORDER1,
    "mate_info_chrom":   Compression.NAME_TOKENIZED,    # new in Phase F
    "mate_info_pos":     Compression.RANS_ORDER1,       # new in Phase F
    "mate_info_tlen":    Compression.RANS_ORDER1,       # new in Phase F
}
```

### 4.2 Objective-C

```objc
writtenRun.signalCodecOverrides = @{
    @"mate_info_chrom": @(TTIOCompressionNAME_TOKENIZED),
    @"mate_info_pos":   @(TTIOCompressionRANS_ORDER1),
    @"mate_info_tlen":  @(TTIOCompressionRANS_ORDER1),
};
```

### 4.3 Java

```java
writtenRun.setSignalCodecOverrides(Map.of(
    "mate_info_chrom", Compression.NAME_TOKENIZED,
    "mate_info_pos",   Compression.RANS_ORDER1,
    "mate_info_tlen",  Compression.RANS_ORDER1
));
```

---

## 5. On-disk schema

### 5.1 M82 baseline (no override) — unchanged

```
/study/genomic_runs/<name>/signal_channels/
    mate_info: COMPOUND[n_reads] {
        chrom: VL_STRING,
        pos:   INT64,
        tlen:  INT32
    }
```

### 5.2 Phase F with any mate_info_* override

```
/study/genomic_runs/<name>/signal_channels/
    mate_info/                                    # GROUP, not dataset
        chrom: <one of three layouts>
            VL_STRING[n_reads]  (HDF5 ZLIB)       # if no chrom override
            UINT8[encoded_len]  @compression=4|5  # if rANS chrom override
            UINT8[encoded_len]  @compression=8    # if NAME_TOK chrom override
        pos:   <one of two layouts>
            INT64[n_reads]      (HDF5 ZLIB)       # if no pos override
            UINT8[encoded_len]  @compression=4|5  # if rANS pos override
        tlen:  <one of two layouts>
            INT32[n_reads]      (HDF5 ZLIB)       # if no tlen override
            UINT8[encoded_len]  @compression=4|5  # if rANS tlen override
```

The `mate_info` link type (group vs dataset) is the primary
read-side dispatch signal. Each per-field child dataset
carries its own `@compression` attribute (or lacks one,
indicating natural-dtype storage).

---

## 6. Tests

### 6.1 Python — extend `python/tests/test_m86_genomic_codec_wiring.py`

Add 9 new test methods (numbering continues from M86 Phase C):

48. **`test_round_trip_mate_chrom_name_tokenized`** — write a
    100-read run with
    `signal_codec_overrides={"mate_info_chrom":
    Compression.NAME_TOKENIZED}` (typical case: most mates on
    same chromosome, e.g. 90% "chr1", 10% other). Reopen,
    iterate all reads, verify each
    `aligned_read.mate_chromosome` matches input byte-exact.
49. **`test_round_trip_mate_pos_rans`** — same with
    `mate_info_pos: RANS_ORDER1`. Verify
    `aligned_read.mate_position` round-trips.
50. **`test_round_trip_mate_tlen_rans`** — same with
    `mate_info_tlen: RANS_ORDER1`. Verify
    `aligned_read.template_length` round-trips.
51. **`test_round_trip_mate_all_three`** — all three
    overrides at once. All three fields round-trip.
52. **`test_round_trip_mate_partial`** — only chrom
    overridden, pos and tlen left at default. Subgroup is
    created (verify `mate_info` is a group), chrom dataset
    has `@compression`, pos and tlen are stored as their
    natural dtypes inside the subgroup with no
    `@compression`. All three round-trip.
53. **`test_back_compat_mate_info_unchanged`** — no
    mate_info_* override. Verify `mate_info` is still the
    M82 compound dataset; round-trips via existing path.
54. **`test_reject_bare_mate_info_key`** —
    `signal_codec_overrides={"mate_info": Compression.RANS_ORDER1}`
    raises ValueError at write time with a message pointing
    at the three per-field keys.
55. **`test_reject_wrong_codec_on_mate_pos`** —
    `signal_codec_overrides={"mate_info_pos": Compression.NAME_TOKENIZED}`
    raises ValueError (NAME_TOKENIZED on integer field).
56. **`test_round_trip_full_ten_overrides`** — extend Phase
    C's full-stack test (#47, seven overrides) to TEN
    overrides: the seven existing + three mate_info_* fields.
    All round-trip correctly. The full codec stack on every
    eligible channel and field.

Plus extend `test_cross_language_fixtures` for the new fixture.

### 6.2 ObjC — extend `objc/Tests/TestM86GenomicCodecWiring.m`

Same 9 new test cases. Cross-language fixture loaded from
`objc/Tests/Fixtures/genomic/m86_codec_mate_info_full.tio`.
Target ≥ 18 new assertions.

### 6.3 Java — extend
`java/src/test/java/global/thalion/ttio/genomics/M86CodecWiringTest.java`

Same 9 new test cases. Cross-language fixture loaded from
`java/src/test/resources/ttio/fixtures/genomic/m86_codec_mate_info_full.tio`.

### 6.4 Cross-language conformance fixture

Generate one fixture from the Python writer:
`python/tests/fixtures/genomic/m86_codec_mate_info_full.tio`.
A 100-read run with realistic mate_info patterns:
- chrom: `["chr1"] * 90 + ["chr2"] * 5 + ["chrX"] * 3 + ["*"] * 2`
- pos: deterministic monotonic positions for paired mates,
  -1 for unmapped
- tlen: cluster around 350 (typical Illumina insert size) for
  paired, 0 for unmapped

Override: all three fields under their recommended codec
(NAME_TOKENIZED for chrom, RANS_ORDER1 for pos and tlen).

Other channels use M82 baseline (no override) so the fixture
isolates the mate_info wiring.

---

## 7. Documentation

### 7.1 `docs/format-spec.md`

Update §10.4 trailing summary: mate_info is no longer
compound-only — it can be decomposed via the per-field virtual
channel names when overrides are set.

Add new §10.9 documenting the mate_info schema lift:

```
## 10.9 mate_info per-field decomposition (M86 Phase F)

The mate_info channel under signal_channels/ has TWO on-disk
layouts depending on whether any mate_info_* override is set:

- No override (M82 default): COMPOUND dataset with three
  fields (chrom: VL_STRING, pos: INT64, tlen: INT32).
- Any mate_info_* override: subgroup containing three child
  datasets (chrom, pos, tlen), each with its own @compression
  or natural dtype.

Readers MUST dispatch on HDF5 link type (dataset = M82
compound; group = Phase F subgroup). Per-field overrides are
exposed via three flat keys in signal_codec_overrides:
mate_info_chrom, mate_info_pos, mate_info_tlen. Partial
overrides allowed; un-overridden fields use natural-dtype
HDF5-filter ZLIB storage inside the subgroup.

Codec applicability per field is documented in the validation
map in spectral_dataset (one-to-one with the existing per-
channel allowed-codec rules: chrom takes the same codecs as
cigars; pos/tlen take the same codecs as positions/flags).

The chrom field's rANS path uses length-prefix-concat
serialisation (varint(len) + ascii bytes per chrom) — same
contract as cigars (§10.8.2).

Pre-M86-Phase-F readers that hard-code the compound layout
will fail when they hit the subgroup. Discipline matches
M80 / M82 / M86 Phase A/E/C (write-forward).
```

### 7.2 `docs/codecs/rans.md`

Update §7 to add mate_info_pos and mate_info_tlen as new
applicable channels for rANS (alongside positions, flags,
mapping_qualities from Phase B). Add mate_info_chrom as
applicable for rANS via the cigars-style length-prefix-concat.

### 7.3 `docs/codecs/name_tokenizer.md`

Update §8 to add mate_info_chrom as the third channel where
NAME_TOKENIZED applies (alongside read_names from Phase E and
cigars from Phase C). Note that for chromosome names, the
columnar dictionary win is essentially guaranteed in
practice (chrom alphabets are tiny — usually <30 distinct
values — so the dictionary fits in a few bytes regardless of
read count).

### 7.4 `CHANGELOG.md`

Add M86 Phase F entry under `[Unreleased]`. Update header.

### 7.5 `WORKPLAN.md`

Update M86 section header from "Phases A, B, C (cigars), D,
and E shipped; Phase C (mate_info) deferred" to "Phases A,
B, C, D, E, and F shipped". Phase F subsection: mark
mate_info wiring complete; note this completes the M82-era
genomic codec story for ALL channels.

---

## 8. Out of scope

- **MS-side wiring.** Genomic-only.
- **Per-field codec dispatch on other compounds.** mate_info
  is the only compound that gets decomposed in Phase F. If
  another compound shows up in the future, it'd need its own
  Phase-F-style milestone.
- **Cross-field codec hints.** The mate fields are
  independent at the codec level; no joint encoding (e.g.
  "encode chrom and pos together as a 2D structure"). Each
  field gets its own codec choice.

---

## 9. Acceptance Criteria

### Python
- [ ] All existing tests pass (zero regressions vs `67faa2c`).
- [ ] All 9 new tests in
      `python/tests/test_m86_genomic_codec_wiring.py` pass.
- [ ] `m86_codec_mate_info_full.tio` fixture committed.
- [ ] Validation accepts the three new keys (mate_info_chrom,
      mate_info_pos, mate_info_tlen) with their per-field
      allowed codec sets.
- [ ] Validation rejects the bare `mate_info` key with a
      message pointing at the per-field keys.
- [ ] Validation rejects wrong-content codecs on each field
      (NAME_TOKENIZED on int fields; BASE_PACK and
      QUALITY_BINNED on all three).
- [ ] Partial overrides work: only chrom triggers the
      subgroup but pos/tlen stay on natural-dtype ZLIB inside
      the subgroup.
- [ ] Back-compat: empty mate_info_* overrides leave
      mate_info as the M82 compound dataset.

### Objective-C
- [ ] All existing tests pass (zero regressions vs the 2427
      PASS baseline + 2 pre-existing M38 Thermo failures).
- [ ] 9 new test methods pass byte-exact against the Python
      fixture.
- [ ] HDF5-link-type dispatch (dataset vs group) works for
      both layouts.
- [ ] ≥ 18 new assertions.

### Java
- [ ] All existing tests pass (zero regressions vs the 502/0/0/0
      baseline → ≥ 511/0/0/0 after M86 Phase F).
- [ ] 9 new test methods pass.
- [ ] Cross-language fixture reads byte-exact for all three
      mate fields.

### Cross-Language
- [ ] All three implementations read
      `m86_codec_mate_info_full.tio` byte-exact-on-decoded
      (every read's `mate_chromosome`, `mate_position`,
      `template_length` fields match the original Python
      input).
- [ ] `docs/format-spec.md` summary updated; new §10.9
      documents the mate_info subgroup pattern.
- [ ] `docs/codecs/rans.md` §7 updated to mention the three
      mate_info_* channels.
- [ ] `docs/codecs/name_tokenizer.md` §8 updated to mention
      mate_info_chrom.
- [ ] `CHANGELOG.md` M86 Phase F entry committed.
- [ ] `WORKPLAN.md` M86 Phase F status flipped to SHIPPED;
      header updated to "Phases A, B, C, D, E, and F shipped".

---

## 10. Gotchas

141. **Dispatch on HDF5 link type for mate_info, not on
     attribute presence.** This is the first M86 phase where
     a top-level signal_channels link can be either a
     compound dataset OR a group. Use the HDF5 binding's link-
     type query (`H5O_TYPE_DATASET` vs `H5O_TYPE_GROUP` in
     ObjC; equivalents in Python h5py and Java HDF5-Java).

142. **Per-field validation is independent.** A run can have
     `mate_info_chrom` override but no `mate_info_pos`
     override; the chrom field gets codec dispatch while the
     pos field uses natural-dtype storage inside the subgroup.
     Don't accidentally reject partial-override states.

143. **The bare `mate_info` key is rejected.** Don't silently
     map it to one of the per-field overrides; produce a
     clear error pointing the caller at the three per-field
     names. Tests must cover this rejection (#54).

144. **Cache discipline: one combined `_decoded_mate_info`
     dict, NOT three separate fields.** Per Binding Decision
     §129. Each `_mate_<field>_at(i)` helper writes to
     `_decoded_mate_info[<field>]` on first decode. Other
     M86 caches (byte channels, integer channels, read names,
     cigars) remain separate per their respective binding
     decisions.

145. **Three fields = three sets of Phase B integer-channel
     code paths to mirror.** The pos and tlen fields are
     just like Phase B's positions and flags channels — same
     LE byte serialisation, same channel-name → dtype
     lookup. Reuse the existing Phase B helpers if possible
     (or extract a shared int-channel encode/decode helper
     that the per-field code path can call).

146. **The chrom field is just like the cigars channel from
     Phase C.** Same length-prefix-concat serialisation for
     the rANS path, same direct-call for the NAME_TOKENIZED
     path. Reuse Phase C helpers if possible.

147. **HDF5 link-type query is language-specific.** Python
     h5py: `isinstance(parent["mate_info"], h5py.Group)` vs
     `h5py.Dataset`. ObjC: `H5Oget_info_by_name` returns a
     struct with a `type` field (`H5O_TYPE_GROUP` or
     `H5O_TYPE_DATASET`). Java: `H5.H5Oget_info_by_name`
     returns similar. Document the per-language idiom in the
     implementer prompts.

148. **Empty / unmapped mate fields are common.** Many
     reads have no mate (`mate_chromosome == "*"`,
     `mate_position == -1`, `template_length == 0`). The
     codecs handle these fine — chrom's "*" goes through the
     NAME_TOKENIZED dictionary (one entry); pos's -1
     delta-encodes well in rANS; tlen's 0 has high
     concentration in the rANS frequency table. Tests should
     include realistic mixes of paired and unpaired reads.
