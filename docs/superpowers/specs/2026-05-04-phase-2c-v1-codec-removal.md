# Phase 2c spec — v1 codec implementation removal + transport drift reconciliation

**Date:** 2026-05-04
**Branch base:** `122729f` (post-Phase 2b ObjC)
**Authorizing context:** TTI-O v1.0 reset; Phase 2a + 2b shipped (opt-out flags
gone). Phase 2c removes the v1 codec implementation paths those flags used to
expose.

## Scope items

### 1. NAME_TOKENIZED v1 (codec id 8)

Reachable via `signalCodecOverrides[read_names] = NAME_TOKENIZED`. Files:
- Python: `python/src/ttio/codecs/name_tokenizer.py` + native `_name_tokenizer/`
- Java: `java/src/main/java/global/thalion/ttio/codecs/NameTokenizer.java`
- ObjC: `objc/Source/Codecs/TTIONameTokenizer.{h,m}`
- Writer dispatch in spectral_dataset (3 langs): the
  `NAME_TOKENIZED → flat 1-D uint8 dataset` branch
- Reader dispatch: `@compression == 8 → decode via NameTokenizer`
- Override-validation that accepts NAME_TOKENIZED for read_names
- Tests asserting v1 dispatch: `test_*_name_tok*_v1*`, plus
  `test_attribute_set_correctly_*` if it positionally depends on enum value 8.

### 2. REF_DIFF v1 (codec id 9)

Reachable via `signalCodecOverrides[sequences] = REF_DIFF`. Files mirror
NAME_TOKENIZED:
- Python: `python/src/ttio/codecs/ref_diff.py` + native `_ref_diff/`
- Java: `RefDiff.java`
- ObjC: `TTIORefDiff.{h,m}`
- M93 writer dispatch (`_write_sequences_ref_diff` in Python; equivalent
  in Java/ObjC) — single-chromosome, all-reads-mapped, reference present
- Reader dispatch
- `_uses_ref_diff_v2_default` reference-resolution path (already handles
  v2 — confirm v1 path can be removed too)

### 3. mate_info v1 per-field subgroup (Phase F layout)

NOT a separate codec — a writer pattern. Files:
- Python: writer code in `spectral_dataset.py` `_write_mate_info_v1` /
  Phase F dispatch
- Java: in `SpectralDataset.java` similar dispatch
- ObjC: in `TTIOSpectralDataset.m`
- Reader path in `genomic_run.py` / `GenomicRun.java` / `TTIOGenomicRun.m`
  that handles `signal_channels/mate_info/{chrom,pos,tlen}` subgroup
  layout vs the `signal_channels/mate_info/inline_v2` blob layout
- Override-validation that accepts `mate_info_chrom`/`mate_info_pos`/
  `mate_info_tlen` channel-name keys (currently rejects unconditionally
  per Phase 2b — that rejection should now be the only path after the
  reader logic for the subgroup layout is removed)

### 4. M82 compound read_names

NOT a separate codec — a writer pattern. Currently the FALLBACK when v2
native lib unavailable (the Phase 2b ObjC agent added an `if (run.readCount
== 0) → M82 compound` empty-run guard too). Files:
- Writer code in `spectral_dataset.py` / `SpectralDataset.java` /
  `TTIOSpectralDataset.m` that emits read_names as a VL-string compound
  dataset
- Reader path that materialises read_names from the compound dataset
- Empty-run handling: after removal, empty runs need a different fallback
  — either error out or emit an empty inline blob with v2 magic

### 5. M94.Z V1/V2/V3 internal version flavors of FQZCOMP_NX16_Z (codec id 12)

Codec ENTRY stays (id 12 is the only qualities codec). Internal flavors:
- V1: pure-Python (initial impl)
- V2: native libttio_rans body (Task 21)
- V3: adaptive Range Coder (L2 / Task #82 Phase B.2)
- V4: CRAM 3.1 fqzcomp_qual port (L2.X Stage 2) — KEEP, current default

Reader currently handles V1/V2/V3/V4 header variants by inspecting the
header byte. Phase 2c removes V1/V2/V3 paths; reader rejects with a
clear error message.

Files: `python/src/ttio/codecs/fqzcomp_nx16_z.py` (lines around 58–62 +
header-pack functions). Java: `FqzcompNx16Z.java`. ObjC: `TTIOFqzcompNx16Z.{h,m}`.

### 6. Transport semantic drift reconciliation — DEFERRED to Phase 2c-T

`python/src/ttio/transport/codec.py:850` previously set
`opt_disable_inline_mate_info_v2=True` to preserve verbatim SAM
mate_chromosome sentinels (`=`, `""`) across the wire. Phase 2b dropped
the kwarg per directive — v2 normalises `=` → resolved chrom name and
`""` → `*`.

**Decision (2026-05-04 user call):** Phase 2c does NOT touch transport.
A separate **Phase 2c-T** will design + implement the proper bulk-mode
wire format (new packet type carrying v2 blob bytes verbatim alongside
per-AU index metadata) so receivers can write v2 blobs into the local
file without going through a decode→re-encode round-trip.

Rationale: the proper fix is not a one-liner — transport is full
3-language (Python + Java + ObjC), wire format is per-AU not block-level,
and the v2 codecs are inherently block-level. A clean blob-mode wire
format requires its own spec doc + 3-language coordination + cross-lang
byte-identity verification.

Phase 2c carryover: m89 cross-language pre-existing failures remain
same-set (the 3 `*-encode_objc-decode` cells); they'll be resolved when
Phase 2c-T lands. Transport README will be updated in Phase 2c-T, not
here.

## Cross-language fixtures (the kept-in-2b exception)

- `python/tests/fixtures/genomic/m86_codec_mate_info_full.tio`
- `python/tests/fixtures/genomic/m86_codec_cigars_name_tokenized.tio`
- `regenerate_m86_*.py` scripts that produce these

These fixtures use v1 codecs explicitly. After Phase 2c:
- The regenerator scripts can no longer produce them (writer paths gone).
- The Java `crossLanguageFixtureMateInfoFull` + ObjC equivalent + Python
  reader test become dead — DELETE all three.
- Delete the `.tio` fixture files + the regenerator scripts.

## Deletion order (per language)

Language-by-language to keep each suite green throughout:

**Per language:**
1. Delete v1 writer dispatch in spectral_dataset (NAME_TOKENIZED,
   REF_DIFF, mate_info v1 subgroup, M82 compound read_names)
2. Delete writer-side override validation that accepted v1 codec IDs
3. Delete v1 reader dispatch
4. Delete v1 codec impl files
5. Delete tests that exercised v1 paths
6. Delete the M94.Z V1/V2/V3 reader header dispatch (keep V4)
7. Delete cross-language fixture tests + .tio files + regenerator scripts
8. Run full suite — must pass

**Cross-language coordination:**
- Order: Python → Java → ObjC (Python is the reference; once it ships,
  Java + ObjC can be done in parallel)
- The cross-language fixture tests delete in the language that owns the
  test (Python deletes the regenerator scripts + .tio files; Java + ObjC
  delete their consumer tests)

## Out of scope (deferred to later phases)

- Removing the `RANS_ORDER0` / `RANS_ORDER1` / `BASE_PACK` /
  `QUALITY_BINNED` enum values — those remain valid signal_codec_overrides
  for sequences/qualities channels (they're not "v1 codecs", they're
  alternative codecs)
- Removing the `DELTA_RANS_ORDER0` (id 11) codec — orthogonal, used for
  sorted integer channels; not a v1 fallback
- Removing the `_RESERVED_10` enum slot (Phase 2d)
- Removing the `kTTIOFormatVersionM82/M93/M74` constants (Phase 2d)

## Verification

After Phase 2c lands:
- `grep -rn "NAME_TOKENIZED\b\|REF_DIFF\b" python/src/ttio java/src/main objc/Source --include="*.py" --include="*.java" --include="*.m" --include="*.h" 2>/dev/null` → reachable matches must be only enum-declaration sites (kept until Phase 2d) + reader-side error messages ("v1 codec id N is no longer supported").
- All 3 test suites pass with no NEW failures vs the post-2b baselines:
  - Python: 1894/12/57skip (12 pre-existing — same set)
  - Java: 868/0/0/4
  - ObjC: 3310/0
- chr22 round-trip end-to-end still works (default v2 codecs only).

## Open-question resolutions (user calls 2026-05-04)

1. **M94.Z V1/V2/V3 reader removal**: REJECT old-version files with
   "unsupported version" error. Clean v1.0 break — no half-supported
   legacy paths.
2. **Cross-language fixture deletion**: DELETE the v1 fixtures + their
   tests entirely now. Phase 3's "fixture regen + cross-lang gate
   revalidation" will produce v2 fixtures.
3. **Transport drift fix**: SPLIT — Phase 2c does codec removal only;
   Phase 2c-T (separate phase, separate spec) does the proper bulk-mode
   wire format change carrying v2 blobs natively. See §6 above.
