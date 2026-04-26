# HANDOFF — M86 Phase D: Wire QUALITY_BINNED into the qualities channel

**Scope:** Extend the M86 Phase A pipeline-wiring infrastructure
to dispatch `Compression.QUALITY_BINNED` (M79 codec id `7`) on
the `signal_channels/qualities` byte channel of genomic runs.
Phase A already shipped the `signal_codec_overrides` dict,
the `@compression` attribute, and the lazy-decode cache for the
byte channels (sequences and qualities); Phase D adds one new
codec id to the validation + dispatch branches in all three
languages.

**Branch from:** `main` after M85 Phase B docs (`bd9941f`).

**IP provenance:** Pure integration work — no new codec
implementation. Uses the M85 Phase A QUALITY_BINNED codec
(`python/src/ttio/codecs/quality.py`,
`objc/Source/Codecs/TTIOQuality.{h,m}`,
`java/src/main/java/global/thalion/ttio/codecs/Quality.java`)
which is already clean-room and already cross-language
conformant.

---

## 1. Background

M86 Phase A (commits `31b0fa48..0de6fde`) wired three codec ids
(4 / 5 / 6 = RANS_ORDER0, RANS_ORDER1, BASE_PACK) into the
`sequences` and `qualities` byte channels of genomic runs.
The validation block at the top of the genomic-run write path
accepts:

- channel name ∈ {`"sequences"`, `"qualities"`}
- codec value ∈ {`RANS_ORDER0`, `RANS_ORDER1`, `BASE_PACK`}

M85 Phase A (commits `9cfb08bd..9c0b450`) shipped the
QUALITY_BINNED codec (M79 slot 7) as a standalone primitive,
explicitly noting that pipeline-wiring would be a future M86
phase. M85 Phase B (commits `cf665e7..bd9941f`) did the same for
NAME_TOKENIZED (M79 slot 8).

M86 Phase D extends the M86 Phase A validation + dispatch to
also accept `Compression.QUALITY_BINNED` for the `qualities`
channel. Restrictions (deliberate per §3 binding decisions):

- QUALITY_BINNED is **only valid on the `qualities` channel**,
  not `sequences`. Applying QUALITY_BINNED to a sequences
  channel would silently destroy the ACGT data via Phred-bin
  quantisation; the validation rejects this combination
  outright.
- The other three codec ids (4 / 5 / 6) continue to apply to
  both `sequences` and `qualities` per Phase A.

NAME_TOKENIZED wiring is M86 Phase E (still deferred) and
requires lifting `signal_channels/read_names` from
VL_STRING-in-compound storage to a flat byte dataset so it can
carry the `@compression` attribute. Phase D does not touch
read_names.

---

## 2. Design

### 2.1 No wire format changes

Phase D uses the same `@compression` attribute scheme as Phase A
(uint8 attribute on the dataset, holding the M79 codec id). A
qualities channel encoded with QUALITY_BINNED has
`@compression == 7` and the dataset bytes are the
self-contained QUALITY_BINNED stream from M85 Phase A's
`docs/codecs/quality.md` §2.

### 2.2 Validation extension

The override-validation block in `_write_genomic_run` (Python),
`writeGenomicRun` / `writeGenomicRunStorage` (ObjC), and
`SpectralDataset` (Java) gains a per-channel codec-applicability
check:

```
allowed_codecs_for_channel = {
    "sequences": {RANS_ORDER0, RANS_ORDER1, BASE_PACK},
    "qualities": {RANS_ORDER0, RANS_ORDER1, BASE_PACK, QUALITY_BINNED},
}
```

For each `(channel_name, codec)` entry in
`signal_codec_overrides`:

1. Reject if `channel_name not in {"sequences", "qualities"}`
   (unchanged from Phase A).
2. Reject if `codec not in allowed_codecs_for_channel[channel_name]`.
   Phase D adds the `qualities`-only QUALITY_BINNED branch.
3. Otherwise, accept and dispatch to the codec.

The error message for "QUALITY_BINNED on sequences" is
explicit: it names the codec, the channel, and explains that
quality binning is lossy and only applies to Phred quality
scores.

### 2.3 Encode dispatch extension

The `_write_byte_channel_with_codec` helper (Python),
`writeByteChannelWithCodec` (Java), and the equivalent ObjC
dispatch site gain one new branch:

```python
elif codec_override == Compression.QUALITY_BINNED:
    from .codecs.quality import encode as _enc
    encoded = _enc(bytes(data))
```

Behaviour: encode the raw uint8 buffer through
`quality.encode()`, write the encoded bytes as an unfiltered
uint8 dataset, set `@compression = 7` on the dataset.

### 2.4 Decode dispatch extension

The `_byte_channel_slice` helper on `GenomicRun` (Python) gains
one new branch:

```python
elif codec_id == Compression.QUALITY_BINNED:
    from .codecs.quality import decode as _dec
    decoded = _dec(all_bytes)
```

Same pattern in ObjC `byteChannelSliceNamed:offset:count:error:`
and Java `byteChannelSlice`. The lazy-decode cache from Phase A
caches the decoded buffer on the `GenomicRun` instance; no new
caching infrastructure is needed.

### 2.5 Lossy round-trip semantics propagate

QUALITY_BINNED is lossy by construction (M85 Phase A §97). When
QUALITY_BINNED is wired into the qualities channel, the
round-trip semantics of `AlignedRead.qualities` change for that
channel:

- Without override: byte-exact round-trip.
- With QUALITY_BINNED override: each byte round-trips to its
  bin centre per the Illumina-8 table.

This is a documented behaviour of the codec, not an M86-specific
issue. Tests must use bin-centre inputs for byte-exact round-trip
assertions OR assert the expected lossy mapping (per M85 Phase A
§7.1 #2).

---

## 3. Binding Decisions (continued from M85 Phase B §98–§107)

| #   | Decision | Rationale |
|-----|----------|-----------|
| 108 | QUALITY_BINNED applies **only** to the `qualities` channel; the validation rejects QUALITY_BINNED on `sequences`. | QUALITY_BINNED quantises bytes through a Phred-specific bin table (8 bins, centres 0/5/15/22/27/32/37/40). Applying it to ACGT sequence bytes (`A`=0x41=65, `C`=0x43=67, `G`=0x47=71, `T`=0x54=84) would map all four to bin 7 / centre 40, silently destroying the sequence. The validation prevents this category error at the write-path entry point; the codec itself remains byte-in-byte-out so other future contexts could use it without restriction. |
| 109 | The other three codec ids (4 / 5 / 6) continue to apply to **both** `sequences` and `qualities` per Phase A. | RANS is a generic byte-stream entropy coder; BASE_PACK is byte-lossless on any input (with sidecar mask). Both work on either channel without category error. Phase D adds QUALITY_BINNED as a new codec applicability, not a restriction on existing applicabilities. |
| 110 | The error message for an invalid `(channel, codec)` combination names the codec, the channel, and the reason. | Better UX than "unsupported codec for channel" alone. The Phase A-style error for invalid channel name (e.g., `signal_codec_overrides={"positions": ...}`) and Phase A-style error for non-codec value (e.g., `LZ4`) remain unchanged; the new Phase D-specific error is for `(sequences, QUALITY_BINNED)` and adds a hint about quality binning being lossy. |

---

## 4. API surface (no changes for callers)

### 4.1 Python

The `WrittenGenomicRun.signal_codec_overrides` field signature is
unchanged. Callers can now pass `Compression.QUALITY_BINNED` as
the value for the `"qualities"` key:

```python
run = WrittenGenomicRun(
    # ... existing fields ...
    signal_codec_overrides={
        "qualities": Compression.QUALITY_BINNED,  # new in Phase D
    },
)
```

### 4.2 Objective-C

```objc
writtenRun.signalCodecOverrides = @{
    @"qualities": @(TTIOCompressionQUALITY_BINNED),  // new in Phase D
};
```

### 4.3 Java

```java
writtenRun.setSignalCodecOverrides(Map.of(
    "qualities", Compression.QUALITY_BINNED  // new in Phase D
));
```

---

## 5. Tests

### 5.1 Python — extend `python/tests/test_m86_genomic_codec_wiring.py`

Add the following test cases (numbering continues from the
existing M86 Phase A test suite):

12. **`test_round_trip_qualities_quality_binned`** — write a run
    with `signal_codec_overrides={"qualities": Compression.QUALITY_BINNED}`
    using bin-centre Phred values
    (`bytes([0,5,15,22,27,32,37,40] * 125)` for 1000 reads × 1
    quality byte each, or whatever shape the existing M86 helper
    builds). Reopen, iterate all reads, verify each
    `aligned_read.qualities` matches the original input (byte-exact
    since the input is all bin centres, which round-trip exactly
    per QUALITY_BINNED §97).
13. **`test_round_trip_qualities_quality_binned_lossy`** — write
    a run with arbitrary Phred values (`bytes(range(0, 50))`
    cycled) using the QUALITY_BINNED override. Reopen, iterate
    all reads, verify each `aligned_read.qualities` matches the
    expected lossy mapping (each input byte → bin centre).
14. **`test_size_win_quality_binned`** — write a 1000-read × 100
    Phred-byte qualities channel both with and without
    QUALITY_BINNED. Verify the QUALITY_BINNED file's
    `signal_channels/qualities` dataset is ~50% the size of the
    uncompressed equivalent (the codec is 4-bit-packed; the
    actual ratio depends on header overhead per read).
15. **`test_attribute_set_correctly_quality_binned`** — open the
    underlying h5py file, verify the qualities dataset has
    `@compression == 7`.
16. **`test_reject_quality_binned_on_sequences`** — write with
    `signal_codec_overrides={"sequences": Compression.QUALITY_BINNED}`
    must raise `ValueError` at write time with a clear message
    naming the codec, the channel, and the lossy-quantisation
    rationale.
17. **`test_mixed_quality_binned_with_rans`** — write with
    `signal_codec_overrides={"sequences": Compression.BASE_PACK,
    "qualities": Compression.QUALITY_BINNED}`. Both round-trip
    correctly. This exercises the mixed-codec path with
    QUALITY_BINNED.

Update the `test_cross_language_fixtures` test to also load and
verify a fourth fixture: `m86_codec_quality_binned.tio` (see
§6).

### 5.2 ObjC — extend `objc/Tests/TestM86GenomicCodecWiring.m`

Same six new test cases. Cross-language fixture loaded from
`objc/Tests/Fixtures/genomic/m86_codec_quality_binned.tio`
(verbatim copy of the Python-generated fixture).

### 5.3 Java — extend
`java/src/test/java/global/thalion/ttio/genomics/M86CodecWiringTest.java`

Same six new test cases. Cross-language fixture loaded from
`java/src/test/resources/ttio/fixtures/genomic/m86_codec_quality_binned.tio`.

### 5.4 Cross-language conformance fixture

Generate one new fixture from the Python writer:
`python/tests/fixtures/genomic/m86_codec_quality_binned.tio`.
A 10-read × 100-bp run with bin-centre qualities (so the
round-trip is byte-exact on the read side; cross-language
verification is meaningful).

---

## 6. Documentation

### 6.1 `docs/codecs/quality.md`

Update §7 ("Wired into / forward references"): change
"M86 Phase D (deferred)" to "M86 Phase D (shipped 2026-04-26)"
with the actual usage pointing at `signal_codec_overrides`.

### 6.2 `docs/format-spec.md`

Update §10.4 trailing summary to note that codec ids 4 / 5 / 6 / 7
are now all wired into the byte-channel pipeline (qualities
specifically); id 8 (NAME_TOKENIZED) remains
standalone-primitive-only awaiting Phase E.

### 6.3 `CHANGELOG.md`

Add M86 Phase D entry under `[Unreleased]`. Update the Unreleased
header. Format mirrors M86 Phase A.

### 6.4 `WORKPLAN.md`

Update the M86 section to reflect Phase D shipping. The "Phase B
— integer channels" and "Phase C — VL_STRING channels" deferred
items remain as written; add a new "Phase D — QUALITY_BINNED
wiring (SHIPPED 2026-04-26)" subsection. Phase E
(NAME_TOKENIZED wiring + read_names schema lift) remains
deferred.

---

## 7. Out of scope

- **NAME_TOKENIZED wiring (Phase E).** Requires lifting
  `read_names` from VL_STRING-in-compound to flat byte dataset.
  Separate future milestone.
- **Integer-channel codecs (Phase B).** `positions`, `flags`,
  `mapping_qualities` continue to use HDF5 ZLIB.
- **Cigars / mate_info channel codecs.** No M79 codec applies
  to these structurally-VL channels.
- **MS-side wiring.** This milestone is genomic-only; the MS
  signal-channel path is unchanged.

---

## 8. Acceptance Criteria

### Python
- [ ] All existing tests pass (zero regressions vs `bd9941f`).
- [ ] All 6 new tests in
      `python/tests/test_m86_genomic_codec_wiring.py` pass
      (12–17 plus the cross-language-fixture extension).
- [ ] `m86_codec_quality_binned.tio` fixture committed.
- [ ] Validation rejects `(sequences, QUALITY_BINNED)` with a
      clear error message.

### Objective-C
- [ ] All existing tests pass (zero regressions vs the 2258
      PASS baseline + 2 pre-existing M38 Thermo failures).
- [ ] 6 new test cases in `TestM86GenomicCodecWiring.m` pass
      byte-exact against the Python fixture for QUALITY_BINNED.
- [ ] Validation rejects `(sequences, QUALITY_BINNED)`.
- [ ] ≥ 15 new assertions across the 6 new tests.

### Java
- [ ] All existing tests pass (zero regressions vs the 468/0/0/0
      baseline → ≥ 474/0/0/0 after M86 Phase D).
- [ ] 6 new test methods in `M86CodecWiringTest.java` pass.
- [ ] Validation rejects `(sequences, QUALITY_BINNED)`.

### Cross-Language
- [ ] All three implementations read
      `m86_codec_quality_binned.tio` byte-exact-on-decoded-data
      (the qualities channel decodes to the bin-centre values
      that match the original input).
- [ ] `docs/codecs/quality.md` §7 updated to reflect M86 Phase
      D shipped.
- [ ] `docs/format-spec.md` summary updated.
- [ ] `CHANGELOG.md` M86 Phase D entry committed.
- [ ] `WORKPLAN.md` M86 Phase D status flipped to SHIPPED.

---

## 9. Gotchas

117. **QUALITY_BINNED on the qualities channel changes round-trip
     semantics for that file.** The qualities dataset becomes
     lossy. Tests that assert byte-exact qualities round-trip
     must use bin-centre input or assert the lossy mapping. The
     M86 Phase A behaviour is unchanged for files that don't
     opt in.

118. **The qualities channel is 1 byte per base, indexed by
     read length.** A 100-base read contributes 100 bytes to the
     qualities buffer. The QUALITY_BINNED encoder operates on
     the entire concatenated qualities buffer for the run; the
     resulting wire stream is `6 + ceil(total_qualities_bytes /
     2)`. Per-read slice access still works because the
     `_byte_channel_slice` helper decodes the whole channel
     once on first access (Phase A's lazy-decode cache).

119. **The validation block now needs a per-channel allowed-codec
     set.** Phase A used a flat
     `_ALLOWED_OVERRIDE_CODECS = {RANS_ORDER0, RANS_ORDER1,
     BASE_PACK}` set. Phase D introduces a per-channel set:
     sequences gets the original three; qualities gets those
     plus QUALITY_BINNED. Make sure the data structure
     transition keeps the existing tests green (sequences +
     RANS / BASE_PACK still work).

120. **The cross-language fixture for QUALITY_BINNED uses
     bin-centre quality values** so the round-trip is
     byte-exact on the read side. ObjC and Java tests must
     produce the same bin-centre input deterministically (e.g.,
     `bytes([0,5,15,22,27,32,37,40] * 125)` — 1000 bytes).

121. **No M85 Phase B wiring in this milestone.** NAME_TOKENIZED
     remains standalone-primitive-only. Don't accidentally add
     `Compression.NAME_TOKENIZED` to the validation; it would
     pass the type check but the dispatch branch isn't there
     and the read_names channel doesn't have @compression
     support yet. Phase E covers that.
