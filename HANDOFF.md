# HANDOFF — M86 Phase E: Wire NAME_TOKENIZED into the read_names channel

**Scope:** Wire `Compression.NAME_TOKENIZED` (M79 codec id `8`,
shipped standalone in M85 Phase B) into the
`signal_channels/read_names` channel of genomic runs. Unlike
M86 Phase A and Phase D (which extended dispatch on existing
flat byte channels), Phase E lifts `read_names` from
VL_STRING-in-compound storage to a flat 1-D uint8 dataset that
can carry the `@compression` attribute. Three languages (Python
reference, ObjC normative, Java parity), with one
cross-language conformance fixture.

**Branch from:** `main` after M86 Phase D docs (`ebc8768`).

**IP provenance:** Pure integration work + small schema
adaptation. Reuses the M85 Phase B NAME_TOKENIZED codec
(`name_tokenizer.encode`/`decode` returning `list[str]` ↔
`bytes`) and the M86 Phase A wiring infrastructure
(`signal_codec_overrides`, `@compression` attribute, lazy-decode
cache pattern). No new codec implementation; no third-party
source consulted.

---

## 1. Background

M82 stores read names as a compound HDF5 dataset:
`signal_channels/read_names` has shape `[n_reads]` and dtype
`{value: VL_STRING}`. The compound shape was historical
(originally allowed multiple per-read fields); in v0.11+ it's
effectively a single VL_STRING column.

M86 Phase A's `@compression` attribute scheme (Binding Decision
§86 — attribute on the dataset, holding the M79 codec id) works
for flat 1-D uint8 datasets. A compound dataset can technically
carry attributes too, but the codec output is a flat byte stream
(not a row-per-name compound), so attaching `@compression == 8`
to a compound dataset would be misleading: the dataset shape
itself wouldn't match what the codec produces.

Phase E resolves this with a **schema lift**: when
`signal_codec_overrides["read_names"]` is set, the writer skips
the M82 compound layout and instead writes a flat 1-D uint8
dataset (still named `read_names`) containing the codec output.
The decoder dispatches on dataset shape:

- Compound (`{value: VL_STRING}`) → existing M82 read path.
- Flat 1-D uint8 with `@compression == 8` → codec dispatch.

This is consistent with M86 Phase A's "write-forward, no
back-compat shim" discipline (Binding Decision §90): files
written with the override are unreadable by pre-M86 readers.
Files without the override remain identical to M82 / Phase A
output.

`cigars` and `mate_info` are out of scope for Phase E — they're
still VL_STRING-in-compound and have no codec match yet
(`cigars` would want an RLE-then-rANS pipeline, `mate_info` is
an integer-tuple compound). They continue to use the existing
compound-write path.

---

## 2. Design

### 2.1 Schema lift on write

In `_write_genomic_run` (Python equivalent in each language),
after the validation block, branch on whether `read_names` is
in `signal_codec_overrides`:

```
if "read_names" in signal_codec_overrides:
    encoded = name_tokenizer.encode(run.read_names)  # list[str] → bytes
    arr = np.frombuffer(encoded, dtype=np.uint8)
    ds = sc.create_dataset(
        "read_names", Precision.UINT8, length=arr.shape[0],
        chunk_size=DEFAULT_SIGNAL_CHUNK,
        compression=None,           # no HDF5 filter
    )
    ds.write(arr)
    write_int_attr(ds, "compression", int(Compression.NAME_TOKENIZED))
else:
    # Existing M82 compound write path (unchanged).
    write_compound_dataset(sc, "read_names",
                           [{"value": n} for n in run.read_names],
                           [("value", io.vl_str())])
```

The flat dataset shares its name (`read_names`) with the M82
compound; they are mutually exclusive within a single run.

### 2.2 Schema dispatch on read

In `GenomicRun.__getitem__` (and any other call site that reads
`read_names`), introduce a `_read_name_at(i)` helper that:

```
def _read_name_at(self, i: int) -> str:
    cached = self._decoded_read_names
    if cached is not None:
        return cached[i]

    sig = self.group.open_group("signal_channels")
    ds = sig.open_dataset("read_names")  # or open_compound?

    # Dispatch on dataset shape / attribute presence.
    if _looks_like_codec_dataset(ds):
        codec_id = read_int_attr_or_zero(ds, "compression")
        if codec_id == Compression.NAME_TOKENIZED:
            from .codecs.name_tokenizer import decode as _dec
            all_bytes = bytes(ds.read(offset=0, count=ds.length))
            self._decoded_read_names = _dec(all_bytes)
            return self._decoded_read_names[i]
        else:
            raise ValueError(f"@compression={codec_id} on read_names is not supported")

    # Fall through to compound path (M82, no override).
    names = self._compound("read_names")
    return names[i]["value"]
```

The `_decoded_read_names` cache is a per-`GenomicRun`-instance
`list[str]` (not `bytes`, because the codec returns a list). The
existing `_decoded_byte_channels` cache from Phase A/D is for
byte channels and is unaffected.

`_looks_like_codec_dataset(ds)` returns True iff the dataset is
a 1-D uint8 dataset (vs a compound). Each language has slightly
different shape-introspection APIs; the implementer picks the
appropriate predicate per language.

### 2.3 Validation extension

The per-channel allowed-codec map gains a new entry:

```
_ALLOWED_OVERRIDE_CODECS_BY_CHANNEL = {
    "sequences":  {RANS_ORDER0, RANS_ORDER1, BASE_PACK},
    "qualities":  {RANS_ORDER0, RANS_ORDER1, BASE_PACK, QUALITY_BINNED},
    "read_names": {NAME_TOKENIZED},   # new in Phase E
}
```

NAME_TOKENIZED is **only valid on the `read_names` channel**;
applying it to `sequences` or `qualities` would mis-tokenise
binary byte streams. The other byte-channel codecs (4/5/6/7)
are NOT valid on `read_names` because the source data is
`list[str]`, not `bytes` — there's no universal byte
serialisation step that works for all callers.

The error message for an invalid `(channel, codec)` combination
follows the Phase D pattern: name the codec, name the channel,
explain the rationale.

### 2.4 Lossless round-trip

NAME_TOKENIZED is a lossless codec (M85 Phase B §1). When wired
into `read_names`, the channel round-trips byte-exact for any
input list of ASCII names. This is a stronger guarantee than
Phase D (QUALITY_BINNED is lossy) and matches M82's existing
VL_STRING semantics.

### 2.5 Other read-side call sites

The existing M82 read path may call `_compound("read_names")`
from places other than `__getitem__` — bulk reads, region
queries, etc. All call sites need to route through
`_read_name_at(i)` (or a bulk equivalent
`_all_read_names()`). The implementer audits the existing call
sites and updates them.

For bulk reads, lazy-decode-once-then-slice is fine: the
decoded list is materialised on first access regardless. A
bulk-read call to `_all_read_names()` returns the cached list
directly.

---

## 3. Binding Decisions (continued from M86 Phase D §108–§110)

| #   | Decision | Rationale |
|-----|----------|-----------|
| 111 | When `signal_codec_overrides["read_names"]` is set, the writer **replaces** the M82 compound `read_names` dataset with a flat 1-D uint8 dataset of the same name. The two layouts are mutually exclusive within a single run. | The codec output is a flat byte stream; the `@compression` attribute scheme (Binding Decision §86) requires a flat dataset. Keeping the same dataset name lets the read-side dispatch on shape rather than name lookup. |
| 112 | Read-side dispatch is on **dataset shape** (compound vs 1-D uint8), not on attribute presence alone. A flat 1-D uint8 dataset *without* `@compression` is malformed (since M82 used compound exclusively). | Shape is a stronger signal than attribute presence: it catches both "missing attribute" (corrupt write) and "wrong codec id" (e.g., writing `@compression == 4` on read_names) by routing through the codec dispatch and letting the codec dispatch reject the value. |
| 113 | NAME_TOKENIZED is **only valid on the `read_names` channel**; not on sequences or qualities. | NAME_TOKENIZED expects to tokenise UTF-8 strings (in v0, ASCII-only). Applying it to a binary byte stream like sequences (ACGT bytes) or qualities (Phred bytes) would mis-tokenise the data — every byte that happens to be a digit would split into a token, and the per-column type detection would fall back to verbatim, producing nonsensical compression. The validation rejects these combinations. |
| 114 | The decoded read-names list is cached per-`GenomicRun`-instance as `_decoded_read_names: list[str] \| None`. This cache is **separate** from the M86 Phase A `_decoded_byte_channels: dict[str, bytes]` cache. | Different value type (`list[str]` vs `bytes`); different semantics (the read_names cache holds the entire decoded list, indexed by read number; the byte-channel cache holds the entire concatenated buffer, sliced by per-read offset/length). Sharing the cache structure would conflate them. |

---

## 4. API surface (unchanged for callers; new value accepted)

### 4.1 Python

The `WrittenGenomicRun.signal_codec_overrides` field signature
is unchanged. Callers can now pass `Compression.NAME_TOKENIZED`
as the value for the `"read_names"` key:

```python
run = WrittenGenomicRun(
    # ... existing fields ...
    signal_codec_overrides={
        "read_names": Compression.NAME_TOKENIZED,  # new in Phase E
    },
)
```

Mixed overrides work — sequences + qualities + read_names can
all opt into different codecs in the same run:

```python
signal_codec_overrides={
    "sequences":  Compression.BASE_PACK,
    "qualities":  Compression.QUALITY_BINNED,
    "read_names": Compression.NAME_TOKENIZED,
}
```

### 4.2 Objective-C

```objc
writtenRun.signalCodecOverrides = @{
    @"read_names": @(TTIOCompressionNAME_TOKENIZED),  // new in Phase E
};
```

### 4.3 Java

```java
writtenRun.setSignalCodecOverrides(Map.of(
    "read_names", Compression.NAME_TOKENIZED  // new in Phase E
));
```

---

## 5. On-disk schema (the schema lift)

### 5.1 M82 baseline (no override) — unchanged

```
/study/genomic_runs/<name>/signal_channels/
    read_names: COMPOUND[n_reads] {
        value: VL_STRING
    }
```

### 5.2 Phase E with NAME_TOKENIZED override

```
/study/genomic_runs/<name>/signal_channels/
    read_names: UINT8[encoded_length], no HDF5 filter
        @compression: UINT8 = 8 (NAME_TOKENIZED)
```

The `encoded_length` is whatever
`name_tokenizer.encode(run.read_names)` produces. The dataset
bytes ARE the self-contained NAME_TOKENIZED stream from M85
Phase B's `docs/codecs/name_tokenizer.md` §2.

### 5.3 Both layouts use the same dataset name

This is intentional (Binding Decision §111). A reader cannot
distinguish the two by name; it must inspect the dataset shape
or the `@compression` attribute presence.

---

## 6. Tests

### 6.1 Python — extend `python/tests/test_m86_genomic_codec_wiring.py`

Add 6 new test methods (numbering continues from the M86 Phase
D suite, which ended around test #17):

18. **`test_round_trip_read_names_name_tokenized`** — write a
    run with `signal_codec_overrides={"read_names":
    Compression.NAME_TOKENIZED}` using structured Illumina-like
    names. Reopen, iterate all reads, verify each
    `aligned_read.read_name` matches the original input
    byte-exact.
19. **`test_size_win_name_tokenized`** — write a 1000-read run
    with structured Illumina-style names both with and without
    NAME_TOKENIZED. Verify the encoded `read_names` dataset is
    significantly smaller (target: NAME_TOKENIZED dataset < 50%
    of the M82-compound storage size). The exact ratio depends
    on HDF5 VL_STRING overhead; just verify it's a meaningful
    win.
20. **`test_attribute_set_correctly_name_tokenized`** — write
    with the NAME_TOKENIZED override; open the underlying h5py
    file directly; verify the `read_names` dataset is 1-D uint8
    (not compound) and has `@compression == 8`.
21. **`test_back_compat_read_names_unchanged`** — write without
    the read_names override (empty `signal_codec_overrides`,
    or only sequences/qualities overrides). Verify `read_names`
    is still written as the M82 compound (round-trip via the
    existing read path).
22. **`test_reject_name_tokenized_on_sequences`** —
    `signal_codec_overrides={"sequences":
    Compression.NAME_TOKENIZED}` raises `ValueError` at write
    time with a clear lossy/wrong-channel message per Binding
    Decision §113.
23. **`test_mixed_all_three_overrides`** — write with all three
    overrides at once: sequences=BASE_PACK,
    qualities=QUALITY_BINNED, read_names=NAME_TOKENIZED. All
    three round-trip correctly. This exercises the full codec
    stack on a single file.

Plus extend the existing `test_cross_language_fixtures`
parametrisation to also load
`m86_codec_name_tokenized.tio`.

### 6.2 ObjC — extend
`objc/Tests/TestM86GenomicCodecWiring.m`

Same 6 new test cases. Cross-language fixture loaded from
`objc/Tests/Fixtures/genomic/m86_codec_name_tokenized.tio`.
Target ≥ 15 new assertions across the 6 tests.

### 6.3 Java — extend
`java/src/test/java/global/thalion/ttio/genomics/M86CodecWiringTest.java`

Same 6 new test cases. Cross-language fixture loaded from
`java/src/test/resources/ttio/fixtures/genomic/m86_codec_name_tokenized.tio`.

### 6.4 Cross-language conformance fixture

Generate one new fixture from the Python writer:
`python/tests/fixtures/genomic/m86_codec_name_tokenized.tio`. A
10-read × 100-bp run with structured Illumina-style names like
`f"INSTR:RUN:1:{tile}:{x}:{y}"` (5 columns: 4 string + numeric
+ … wait, that's 6 columns). Use a deterministic generator so
ObjC and Java can construct the same input names.

---

## 7. Documentation

### 7.1 `docs/codecs/name_tokenizer.md`

Update §8 ("Wired into / forward references"): change "M86 Phase
E (deferred)" to "M86 Phase E (shipped 2026-04-26)" with the
actual usage pointing at `signal_codec_overrides`.

### 7.2 `docs/format-spec.md`

Update §10.4 trailing summary: ids 4/5/6/7/8 are now ALL wired
into the genomic signal-channel pipeline. The `read_names`
channel uses a schema-lift pattern (compound → flat uint8) when
the override is set; document this in §10.5 or a new §10.6.

Add a new §10.6 (or extend §10.5) that documents the
schema-lift pattern for `read_names`:

> ### 10.6 `read_names` schema lift under NAME_TOKENIZED (M86 Phase E)
>
> `signal_channels/read_names` has two on-disk layouts depending
> on whether NAME_TOKENIZED was used at write time:
>
> - **No override (M82 default):** compound dataset of shape
>   `[n_reads]` with field `{value: VL_STRING}`. Backward
>   compatible with M82 readers.
> - **NAME_TOKENIZED override active:** flat 1-D `UINT8` dataset
>   of length = `name_tokenizer.encode()` output size, with
>   `@compression == 8` attribute. The dataset bytes are the
>   self-contained NAME_TOKENIZED stream.
>
> Readers dispatch on dataset shape: a 1-D `UINT8` dataset
> requires the codec dispatch path; a compound dataset uses the
> M82 read path. Pre-M86 readers that only know the compound
> layout will silently misinterpret a flat-uint8 read_names
> channel as a corrupt compound — the `@compression` attribute
> is the canonical signal for codec-aware dispatch.
>
> Other VL_STRING channels (`cigars`, `mate_info`) do NOT
> currently support a codec override; they remain in compound
> storage.

### 7.3 `CHANGELOG.md`

Add M86 Phase E entry under `[Unreleased]`.

### 7.4 `WORKPLAN.md`

The M86 section needs Phase E status flipped from DEFERRED to
SHIPPED. Update the "Phases A and D shipped" header to
"Phases A, D, and E shipped".

---

## 8. Out of scope

- **Cigars and mate_info codec wiring.** These remain in
  VL_STRING-in-compound storage; no codec match yet (cigars want
  RLE-then-rANS, mate_info is an integer compound). Future
  milestones.
- **Integer-channel codecs (Phase B).** `positions`, `flags`,
  `mapping_qualities` continue to use HDF5 ZLIB.
- **MS-side wiring.** Genomic-only.

---

## 9. Acceptance Criteria

### Python
- [ ] All existing tests pass (zero regressions vs `ebc8768`).
- [ ] All 6 new tests in
      `python/tests/test_m86_genomic_codec_wiring.py` pass.
- [ ] `m86_codec_name_tokenized.tio` fixture committed.
- [ ] Validation rejects `(sequences, NAME_TOKENIZED)` and
      `(qualities, NAME_TOKENIZED)`.
- [ ] Back-compat: empty overrides path leaves `read_names` as
      the M82 compound; round-trip via existing read code.

### Objective-C
- [ ] All existing tests pass (zero regressions vs the 2290 PASS
      baseline + 2 pre-existing M38 Thermo failures).
- [ ] 6 new test methods in `TestM86GenomicCodecWiring.m` pass.
- [ ] Cross-language fixture reads byte-exact (round-trip
      correct on all 10 read names).
- [ ] ≥ 15 new assertions across the 6 new tests.

### Java
- [ ] All existing tests pass (zero regressions vs the 475/0/0/0
      baseline → ≥ 481/0/0/0 after M86 Phase E).
- [ ] 6 new test methods in `M86CodecWiringTest.java` pass.
- [ ] Cross-language fixture reads byte-exact.

### Cross-Language
- [ ] All three implementations read
      `m86_codec_name_tokenized.tio` byte-exact-on-decoded-names
      (every read's `read_name` field matches the original
      Python input list).
- [ ] `docs/codecs/name_tokenizer.md` §8 updated to reflect M86
      Phase E shipped.
- [ ] `docs/format-spec.md` summary updated; new §10.6 documents
      the schema-lift pattern.
- [ ] `CHANGELOG.md` M86 Phase E entry committed.
- [ ] `WORKPLAN.md` M86 Phase E status flipped to SHIPPED.

---

## 10. Gotchas

122. **Schema lift means the `read_names` dataset shape changes
     based on the override.** A v0.12 file with the override
     has a flat uint8 dataset; without the override it has the
     M82 compound. Readers MUST inspect dataset shape (or the
     `@compression` attribute) before assuming compound layout.
     Pre-M86-Phase-E readers that hard-code the compound shape
     will fail when they hit the flat-uint8 layout.

123. **`_decoded_read_names` cache holds a `list[str]`, not a
     `dict[str, bytes]` like Phase A/D's
     `_decoded_byte_channels`.** Don't try to reuse the byte-
     channel cache; the value type is different. Per Binding
     Decision §114, keep them separate.

124. **NAME_TOKENIZED's per-batch encoding means the entire
     read_names list must be passed to `encode()` in one shot.**
     Streaming write of read names would require a different
     codec design. Phase E assumes the writer has the full list
     at hand (which it does, because `WrittenGenomicRun`
     already has `read_names: list[str]` as a field).

125. **Bulk read paths (region queries, etc.) need to materialise
     the decoded list once on first access.** The lazy-decode
     cache is per-instance; a region query iterates a subset of
     read indices but still triggers the whole-list decode on
     first access. For 10M reads this is potentially a few
     hundred MB of decoded strings in RAM — acceptable for
     typical genomic workloads, document the implication in the
     `GenomicRun` docstring.

126. **Other call sites that touch `read_names` need updating.**
     Audit: search for `_compound("read_names")` and
     `read_names` access in each language's codebase; route all
     through the new `_read_name_at(i)` (or
     `_all_read_names()`) helper. Don't leave a Phase A
     compound-only path in `region_query` etc.

127. **NAME_TOKENIZED's lossless guarantee differs from
     QUALITY_BINNED's lossy semantics.** Round-trip is
     byte-exact on the decoded `aligned_read.read_name` field,
     so byte-equality assertions in tests are valid (no
     bin-centre adjustment needed).
