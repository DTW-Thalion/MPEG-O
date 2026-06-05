# P3.10 — Split the god-files (all 3 SDKs) — Design

> OO-assessment (`docs/architecture/2026-06-02-oo-design-assessment.md`) P3.10.
> Pure code movement: NO `.tio` wire / transport-protocol / behavior / public-API
> change. Each SDK splits independently (no shared seam). Cross-language
> conformance is the gate.

## Goal

Decompose the four monolithic source files by moving cohesive code groups into
separate files / translation units, so each file has one clear responsibility and
fits in a reviewer's (and the model's) working context. Every public class API
stays byte-identical — the unmodified test suites must compile and pass unchanged.

| File | LOC now | After |
|------|--------:|------:|
| `python/src/ttio/spectral_dataset.py` | 2718 | ~1300 (class + orchestration) |
| `python/src/ttio/transport/codec.py` | 3157 | thin re-export facade |
| `java/.../SpectralDataset.java` | 3240 | ~1300 (class + public statics) |
| `objc/Source/Dataset/TTIOSpectralDataset.m` | 4388 | ~1800 (core) |

**Already split (do NOT touch):** Java transport (`TransportWriter.java` 1459 /
`TransportReader.java` 1697 are separate); ObjC transport (`TTIOTransportWriter.m`
/ `TTIOTransportReader.m` separate). The transport god-file exists only in Python.

## Hard invariants (every PR)

- No change to `.tio` on-disk layout, transport wire protocol, or any public
  class/method/function signature. `ttio/__init__.py` re-exports
  (`SpectralDataset`, `WrittenRun`, `WrittenGenomicRun`) and the ObjC `.h` / Java
  public API are unchanged.
- Behavior-identical — this is code movement, not logic change.
- Cross-language conformance + each SDK's full suite stay green.

## Architecture — four PRs (ordered lowest→highest risk)

### PR-1 — Python `spectral_dataset.py`

The `SpectralDataset` class (lines ~65–1114), `WrittenRun` (~1115), `_write_run`
(~1169), `write_minimal`, `_split_run_names`, `_NullGuard` STAY. Extract the
module-level free-function subsystems into two private submodules in
`python/src/ttio/`:

- **`_dataset_write_genomic.py`** — the genomic-write subsystem (~1286–2308):
  `_any_v1_5_codec`, `_reference_md5_for_run`, `_load_references_provider`,
  `_embed_references_for_runs`, `_is_valid_compression`, `_write_sequences_ref_diff_v2`,
  `_write_qualities_fqzcomp_nx16_z`, `_write_genomic_run`, `_build_chrom_id_table`,
  `_resolve_mate_chrom_ids`, `_write_bulk_v2_blob`, `_write_mate_info_bulk_verbatim`,
  `_write_sequences_ref_diff_bulk_verbatim`, `_write_read_names_bulk_verbatim`,
  `_write_mate_info_inline_v2`.
- **`_dataset_write_metadata.py`** — metadata + subjects/samples IO (~2309–2718):
  `_write_identifications`, `_write_quantifications`, `_write_provenance`,
  `_maybe_json_list`, `_maybe_json_dict`, `_decode_identifications_json`,
  `_decode_quantifications_json`, `_decode_provenance_json`,
  `_validate_subjects_and_samples`, `_write_subjects_h5`, `_write_samples_h5`,
  `_write_subjects_provider`, `_write_samples_provider`, `_parse_attributes_json`,
  `_read_subjects`, `_read_samples`, `_read_string_attr_or_default`,
  `_read_long_attr_or_default`.

Imports are one-way: the submodules import from `_hdf5_io`, `enums`, numpy, the
record dataclasses, and `written_genomic_run` — never from `spectral_dataset`.
`spectral_dataset.write_minimal`/`_write_run` import the helpers. No cycle.
Names consumed elsewhere (tests/other modules) that move out keep working via an
explicit re-import in `spectral_dataset.py` if any external caller references them
(grep first; most are leading-underscore privates with no external callers).

### PR-2 — Python `transport/codec.py`

Split into three modules under `python/src/ttio/transport/`:
- **`_writer.py`** — `TransportWriter` (~244–1735) + writer-only helpers
  (`_spectrum_to_access_unit`, `_instrument_config_json`, `_genomic_run_metadata_json`,
  `_provenance_*` builders, `_scan_pattern_to_byte`).
- **`_reader.py`** — `TransportReader` (~1899–2879) + ingest/decode helpers
  (`_new_genomic_accumulator`, `_ingest_genomic_access_unit_bytes`,
  `_decode_stream_header`, `_decode_dataset_header`, `_ingest_access_unit_bytes`,
  `_ingest_access_unit`, `_scan_pattern_from_byte`).
- **`_common.py`** — shared helpers (`_read_mate_chrom_names_table`,
  `_apply_wire_codec`, `_decode_wire_codec`, `_iter_genomic_run_access_units`).
- **`codec.py`** becomes a thin facade: `from ._writer import TransportWriter`,
  `from ._reader import TransportReader`, and re-defines/keeps `file_to_transport`
  / `transport_to_file` (or imports them), preserving `from ttio.transport.codec
  import …` for every existing caller. Grep all importers of `transport.codec`
  and confirm each symbol is re-exported.

### PR-3 — Java `SpectralDataset.java`

Extract the `private static` write machinery into package-private helper classes
in `global.thalion.ttio` (same package, so package-private visibility is
preserved):
- **`SpectralDatasetGenomicWriter`** — `writeGenomicRunSubtree`, `writeMateInfoV2`,
  `writeBulkMateInfo`, `writeBulkReadNames`, `writeBulkSequencesRefDiff`,
  `referenceMd5ForRun`, `usesRefDiffDefaultPath`, `embedReferencesForRuns`,
  `bytesToHexLocal`, `writeSequencesRefDiff`, `writeQualitiesFqzcompNx16Z`,
  `writeByteChannelWithCodec`, `codecIdFor`, `encodeCigars`, `writeUnsignedVarint`,
  `writeSignalChannel`, `writeCompoundOneCol`, `writeCompoundOneColBytes`
  (~1377–2546).
- **`SpectralDatasetMetadataIO`** — `writeIdentifications`/`readIdentifications`,
  `writeQuantifications`/`readQuantifications`, `writeProvenance`/`readProvenance`,
  the `*FromJson` / `build*Json` / `parse*Json` helpers, `nonEmptyJson`,
  `validateSubjectsAndSamples`, `writeSubjects`/`writeSamples`/`*ViaProvider`,
  `readSubjects`/`readSamples`/`*FromProvider`, `readStringAttrOrDefault`,
  `readLongAttrOrDefault` (~2547–3096).

The public `SpectralDataset` keeps all instance accessors, the public static
`open`/`create`/`createWithImages` signatures, the create-orchestration (which now
calls the helper classes), and the encrypt/decrypt/close instance methods.
**Risk:** `buildIdentificationsJson`/`buildQuantificationsJson`/`buildProvenanceJson`
are package-private `static` (not `private`) — grep `src/test` for
`SpectralDataset.buildIdentificationsJson` etc.; if referenced, either keep a thin
`static` delegator on `SpectralDataset` or update the test call sites to the new
class. No public API change either way.

### PR-4 — ObjC `TTIOSpectralDataset.m`

Split the implementation into **categories** in new `.m` files under
`objc/Source/Dataset/`, sharing private state via a new internal header
**`TTIOSpectralDataset+Internal.h`** (a class extension exposing the ivars +
internal helpers the categories need). The public `TTIOSpectralDataset.h` is
unchanged.

- **`TTIOSpectralDataset+GenomicWrite.m`** — the ~1200 LOC of file-`static`
  genomic-write C functions before `@implementation` (`_TTIO_M86_*`, `_TTIO_V17_*`,
  `_TTIO_V18_*`, `_TTIO_PhaseT_*`, `_TTIO_M93_*`, `_TTIO_M94*`, ~86–1312) PLUS the
  genomic write class methods (`+writeGenomicRunStorage:`, `+writeMSRunStorage:`,
  `+writeMinimalGenomicViaProviderURL:`, `+writeGenomicRun:`, `+writeMinimalToPath:`
  family, ~2122–3253). These are `+` class methods taking explicit params (little
  ivar access), so they move cleanly; their static helpers move with them.
- Core `TTIOSpectralDataset.m` keeps: `@implementation` of init/`isEncrypted`/
  `writeToFilePath:` / read (`+readViaProviderURL:`, `+readFromFilePath:`) /
  `closeFile` / runs accessors / `encryptWithKey:`/`decryptWithKey:`/access-policy
  (the instance methods that touch ivars).
- If a second category cleanly separates more (e.g. `+Metadata.m`), do it, but one
  large `+GenomicWrite.m` is the primary win (~2500 LOC out → core ~1800).
- **Build registration (triple-surface, per project convention):** add the new
  `.m` file(s) to BOTH `*_OBJC_FILES` lists in `objc/Source/GNUmakefile`, and
  ensure `TTIOSpectralDataset+Internal.h` is in the header set. Tests build
  unchanged. Verify the category methods that the `.h` declares still link.
- **ObjC ivar-visibility constraint:** category methods in a separate file cannot
  see ivars declared in the primary `.m`'s class extension. Move the shared ivar
  declarations into `TTIOSpectralDataset+Internal.h`'s class extension, imported
  by both the core `.m` and the category `.m`(s). Static C functions that take
  params (not ivars) need no header.

## Error handling

No new error paths — code movement only. Existing error/exception behavior is
preserved verbatim in the moved functions.

## Testing

Per PR: run the affected SDK's full suite (Python pytest; Java `mvn verify` incl.
the ≥0.84 jacoco gate; ObjC ctest/test runner) + confirm cross-language
conformance on CI. No new tests required (the value is that the *existing* tests
pass unchanged against the reorganized code), though a trivial "imports still
resolve / facade re-exports" smoke assertion is welcome for the Python facade
(PR-2) and the Python submodules (PR-1).

## Out of scope

- Any logic/behavior change, public-API change, or wire/protocol change.
- Java/ObjC transport files (already split).
- The class-internal restructure the audit also mentioned (crypto/image mixins) —
  explicitly deferred; this is the free-function/static-extraction strategy only.
- P3.8 (spectrum_class enum) and P3.11 (encapsulation parity) — separate items.

## PR sequence

PR-1 (Python dataset) → PR-2 (Python transport) → PR-3 (Java) → PR-4 (ObjC).
Each is its own branch off main, CI-green, merged before the next.
