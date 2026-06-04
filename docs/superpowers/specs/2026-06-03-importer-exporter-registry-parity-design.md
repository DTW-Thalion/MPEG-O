# Importer / Exporter Registry — 3-SDK Parity — Design

**Date:** 2026-06-03
**Status:** Approved (brainstorm), pending implementation plan
**Scope owner:** importer/exporter subsystem, all three SDKs + tio-browser
**Baseline:** `main` @ `2da938c2` (post-v1.6.5).
**Origin:** Recommendation **P2.6** of the OO design assessment
(`docs/architecture/2026-06-02-oo-design-assessment.md`): "Lift the
importer/exporter registry into Java & ObjC behind real `Reader`/`Writer`
interfaces, collapsing the Python adapter-normalization layer." Follows the
codec-registry parity sweep (Python #209, Java #210, ObjC #211, shipped v1.6.5)
in pattern and discipline.

## Background — current state (verified at baseline)

The three SDKs have drifted in *how* a source format becomes a `.tio` (and back):

- **Python (SDK):** has both registries —
  `importers/registry.py` (`FormatSpec`: key, display name, extensions,
  `required_tool`, **adapter callable** `(inputs, output, **opts) -> None`) and
  `exporters/registry.py` (`ExportSpec`, adapter `(tio_path, layer, output,
  **opts) -> None`). Alias normalization, `spec_for`/`registry_keys`/
  `supported_*_formats`, and `encode()`/`export()` dispatch consumed by the
  `ttio encode`/`ttio export` CLI. The adapters paper over **heterogeneous**
  importer shapes: mzML/mzTab/nmrML/Thermo/Waters do `read(path) -> result`
  then `result.to_ttio(output)`; imzML takes a second `.ibd` input; Bruker
  writes during `read`; BAM/SAM/CRAM do `Reader(path).to_genomic_run(...)` then
  `SpectralDataset.write_minimal(...)`; JCAMP does `read_spectrum` →
  `build_written_run` → `write_minimal`. `fasta`/`fastq` are intentionally
  `CLI_DELEGATED` (richer dedicated CLIs: reference/unaligned modes, PHRED).

- **Java:** **no SDK registry and no unified `encode`/`export` CLI.** Bare
  reader/writer classes with no shared interface and heterogeneous, mostly
  *static* signatures: `MzMLReader.read(path) -> AcquisitionRun`,
  `BamReader(path).toGenomicRun(name) -> WrittenGenomicRun`,
  `MzMLWriter.write(AcquisitionRun, path)`, `BamWriter(path).write(
  WrittenGenomicRun, provenance, ...)`. A **parallel registry exists in
  tio-browser's GUI** (`browser/importers/ImportFormatRegistry` +
  `ImportFormatSpec`, `browser/exporters/Export*`) — but it is GUI-coupled:
  reflective `readerClassFqn` lookup, `browser.diag.Diagnostics` availability,
  and an `ExtraField`/`SourceKind` enum for form rendering. Python's registry
  docstring states it "mirrors the tio-browser GUI `ImportFormatRegistry`" — so
  the format set is duplicated across two hand-maintained registries today.

- **Objective-C:** **no registry at all.** Bare `Import/TTIO*Reader` +
  `Export/TTIO*Writer` classes and per-format CLI tools (`TtioToMzML`,
  `TtioBamDump`, …). Return types are heterogeneous within the language:
  `+[TTIOMzMLReader readFromFilePath:] -> TTIOSpectralDataset *` but
  `-[TTIOBamReader toGenomicRunWithName:] -> TTIOWrittenGenomicRun *`; writers
  take a `TTIOSpectralDataset` (`+[TTIOMzMLWriter writeDataset:...]`).

**The crux:** the audit's literal `read(...) -> Dataset` contract cannot be
taken verbatim, because **`SpectralDataset` is a wrapper over an *open* HDF5
file**, not an in-memory value you build and serialize. Every importer's
terminal step is the static `SpectralDataset.write_minimal(output, *, title,
isa_investigation_id, runs, genomic_runs, identifications, …, image,
raman_image, ir_image, subjects, samples, progress)`, fed by already-built
*run* objects (or an `ImportResult` of spectra/chromatograms). The real
in-memory intermediate is per-format and irregular; unifying it is the work.

## Goals

1. A real, uniform **`Reader`/`Writer` interface** in all three languages that
   every importer/exporter implements, plus an **SDK-level registry** keyed by a
   canonical format key, in Java and ObjC — mirroring (and tidying) Python's.
2. A **normalized in-memory draft** value object that every reader produces and
   a single writer serializes, collapsing the per-format adapter normalization
   (Python's adapter callables are deleted).
3. A unified **`ttio encode --format`/`ttio export --format` CLI** in Java and
   ObjC (Python already has it), so command-line format coverage is identical
   across languages.
4. **tio-browser delegates** its format set, extensions, and required-tool
   availability to the new Java SDK registry, keeping only GUI-specific metadata
   (`SourceKind`, `ExtraField`). The parallel format list is removed.

## Non-goals / hard invariants

- **No wire / on-disk `.tio` format change.** Identical `write_minimal` output;
  byte-equality and cross-language conformance fixtures unchanged.
- **No change to which formats are supported, their aliases, extensions, or how
  each maps to/from `.tio`.** Pure refactor of dispatch + interfaces; the CLI
  additions are *additive surface* exposing existing capability.
- **No change to external-tool semantics.** "Registered" (has a codec) stays
  distinct from "tool installed now" (samtools, ThermoRawFileParser, vendor
  converters); the reader/writer still raises its own clear error at run time.
- Out of scope: the genomic codec registry (done, v1.6.5); the stringly-typed
  `spectrum_class` discriminator (P3.8); the `SpectralDataset` god-file split
  (P3.10); new formats. `fasta`/`fastq` keep their dedicated rich CLIs (see
  below).

## Architecture

### 1. The normalized draft — `ImportedDataset`

A small, language-idiomatic value object carrying everything `write_minimal`
needs, with **one** `write(output, *, provider=...)` that is the single call
site of `write_minimal` (Py) / the equivalent dataset writer (Java/ObjC):

- Fields: `title`, `isa_investigation_id`, `runs` (analytical),
  `genomic_runs`, `identifications`, `quantifications`, `provenance`,
  `features`, `image`/`raman_image`/`ir_image`, `subjects`, `samples`.
- **Python:** generalize the existing `importers/import_result.py::ImportResult`
  into `ImportedDataset` (or rename + extend) — it already does
  `build_runs()` + `to_ttio()`; add `genomic_runs`/images and make `write()`
  the lone `write_minimal` caller. Keep `ImportResult` as a thin deprecated
  alias if any public code imports it (verify during planning).
- **Java:** new `importers/ImportedDataset` (record + builder) bundling
  `Map<String, AcquisitionRun>` + `Map<String, WrittenGenomicRun>` + metadata;
  `write(Path, ...)` calls the existing minimal-dataset writer.
- **ObjC:** new `Import/TTIOImportedDataset` value object;
  `-writeToPath:error:` calls the existing dataset writer. (ObjC mzML currently
  returns a `TTIOSpectralDataset`; the reader is changed to return a draft
  instead, normalizing it with the genomic path.)

### 2. `Reader` / `Writer` interfaces

Uniform, in all three languages:

- **Reader** — *pure produce, no file writing inside importers*:
  - Python: `Reader.read(self, inputs: list[str], opts: Mapping, progress=None) -> ImportedDataset`
  - Java: `interface Reader { ImportedDataset read(List<String> inputs, Map<String,Object> opts, ProgressSink progress) throws IOException; }`
  - ObjC: `@protocol TTIOReader` — `- (nullable TTIOImportedDataset *)readInputs:(NSArray<NSString*>*)inputs options:(NSDictionary*)opts progress:(id<TTIOProgressSink>)progress error:(NSError**)error;`
  - `inputs` carries multi-file formats (imzML `.imzML`+`.ibd`); `opts` carries
    format-specific knobs (BAM `reference`, Bruker `ms2`, genomic `name`/
    `sample`, JCAMP `encoding`).
- **Writer** — exporters already open-and-read, so they take the *opened*
  dataset + a layer selector:
  - Python: `Writer.write(self, ds: SpectralDataset, layer: str | None, output: str, opts: Mapping) -> None`
  - Java: `interface Writer { void write(SpectralDataset ds, String layer, Path output, Map<String,Object> opts) throws IOException; }`
  - ObjC: `@protocol TTIOWriter` — `- (BOOL)writeDataset:(TTIOSpectralDataset*)ds layer:(nullable NSString*)layer toOutput:(NSString*)output options:(NSDictionary*)opts error:(NSError**)error;`
  - The registry/CLI owns opening the `.tio` and the run-selection helpers
    (`_genomic_run`, `_analytical_run`, `_nmr_run` in Python today) become
    shared registry-side utilities, not per-writer copies.

Existing concrete reader/writer classes are retrofitted to implement these
(their current static helpers may remain as thin internals, but the
registry-facing entry point is the interface method).

### 3. Registry

One importer registry + one exporter registry per language, same surface as
Python's today:

- A spec entry: `key`, `displayName`, `extensions`, `requiredTool`,
  and the `Reader`/`Writer` instance (replacing Python's adapter callable).
- `normalize(fmt)` (lowercase + alias map), `isRegistryFormat`, `specFor`,
  `registryKeys`, `supportedEncodeFormats`/`supportedExportFormats`
  (registry ∪ CLI-delegated), and `encode(fmt, inputs, output, opts)` /
  `export(fmt, tioPath, layer, output, opts)` dispatch.
- Alias tables and the exact format/extension/required-tool set are **copied
  verbatim** from Python's registries (the canonical source) so the three match
  by construction. A cross-language test asserts identical key sets.

### 4. Unified CLI (Java + ObjC)

- Java: an `encode`/`export` entry (e.g. `tools/EncodeCli`, `tools/ExportCli`,
  or subcommands of a `ttio` dispatcher) parsing `--format`, inputs, `--output`,
  `--layer`, and `--extra k=v` (mapped to `opts`), then calling the registry.
  `--list-formats` prints `supported*Formats()`.
- ObjC: matching `TtioEncode.m` / `TtioExport.m` tools wired into
  `objc/Tools/GNUmakefile`.
- `fasta`/`fastq` remain `CLI_DELEGATED`: the dedicated subcommands keep their
  rich options (reference/unaligned, line width, PHRED), but both formats also
  get `Reader`/`Writer` registrations so `--list-formats` and the common path
  are complete. Behavior of the dedicated CLIs is unchanged.

### 5. tio-browser delegation (Java, same repo)

`ImportFormatRegistry`/`ExportFormatRegistry` stop hand-listing formats. They
iterate the SDK registry for the **format set, extensions, and required tool**,
and wrap each in the GUI `ImportFormatSpec` adding only GUI-only data
(`SourceKind`, `ExtraField` form hints, `Diagnostics`-based availability —
which can now key off the SDK spec's `requiredTool`). The reflective
`readerClassFqn` availability check is replaced by the SDK registry's presence.
Existing `ImportFormatRegistry*Test`/`ExportFormatRegistry*Test` must stay green
(adjusted only where they asserted the now-delegated hardcoded list).

## Cross-language parity

- Identical canonical key set + alias map + extension lists + required-tool
  strings across Python/Java/ObjC (asserted by a conformance test that compares
  the three `registryKeys()` and alias maps — checked-in golden list).
- Identical `Reader`/`Writer` method *shape* (produce-draft / write-opened),
  matching the codec-registry precedent of nominal + behavioral parity.
- `ImportedDataset` field set mirrors `write_minimal`'s parameters in all three.

## Testing

- **Python:** new `tests/importers/test_reader_interface.py` +
  `tests/exporters/test_writer_interface.py` (each format's reader returns an
  `ImportedDataset`; `.write()` round-trips byte-identically to the old adapter
  path on the existing fixtures). Existing import/export round-trip tests and
  the `encode`/`export` CLI tests must stay green unchanged.
- **Java:** `ImporterRegistryTest`/`ExporterRegistryTest` (key-set, alias,
  dispatch, draft round-trip), plus a CLI smoke test (`encode`/`export`
  `--list-formats` and one real round-trip per non-tool format). tio-browser
  registry tests adjusted for delegation.
- **ObjC:** `TestImporterRegistry.m`/`TestExporterRegistry.m` registered in
  `TTIOTestRunner.m`, same assertions; `objc/build.sh check` green.
- **Cross-language:** a golden key/alias/extension list checked in once and
  asserted by all three (the parity fence).
- Existing cross-language import/export conformance fixtures unchanged
  (the no-wire-change fence).

## Risks

- **Heterogeneous importers resisting the `-> ImportedDataset` contract**
  (highest): Bruker writes during `read`; some readers stream. Mitigation: the
  draft holds *run objects* (already built in memory today) — no extra
  materialization beyond status quo; Bruker's reader is refactored to build runs
  and return a draft rather than write inline. Verify each importer during
  planning; any that genuinely cannot must be flagged before coding (mirrors the
  codec-registry BLOCK discipline).
- **Python `ImportResult` is public API.** Renaming/extending it may break
  importers. Mitigation: keep `ImportResult` as an alias; grep all consumers
  first.
- **tio-browser availability semantics.** GUI greys formats via `Diagnostics`;
  delegation must preserve the exact greying behavior. Mitigation: GUI spec
  keeps `binaryAvailable()` keyed off the SDK `requiredTool`; registry tests
  guard.
- **CLI behavioral parity.** New Java/ObjC CLIs must match Python's
  flags/errors/exit semantics. Mitigation: derive the arg surface from Python's
  CLI; smoke-test `--list-formats` equality.

## Delivery (mirrors the codec-registry cadence)

1. **Python-first proof** — `ImportedDataset` + `Reader`/`Writer` protocols,
   collapse adapter callables, registries dispatch to interfaces, CLI unchanged.
   (1 PR.)
2. **Java** — SDK `ImportedDataset` + interfaces + registries + `encode`/`export`
   CLI + **tio-browser delegation**. (1 PR; GUI is in the same repo.)
3. **ObjC** — SDK `TTIOImportedDataset` + protocols + registries + CLI tools.
   (1 PR.)

Each PR: build/test in WSL (`pytest` with `TTIO_RANS_LIB_PATH`; `JAVA_HOME=
~/jdk25 mvn -Djacoco.skip=true`; `objc/build.sh check`), push from Windows git,
CI cross-language conformance is the gate. Subagent-driven, two-stage review per
task.

## File structure (indicative)

| File | Change | Responsibility |
|---|---|---|
| `python/src/ttio/importers/imported_dataset.py` | Create (or rename `import_result.py`) | normalized draft + `write()` |
| `python/src/ttio/importers/base.py` | Create | `Reader` protocol |
| `python/src/ttio/exporters/base.py` | Create | `Writer` protocol |
| `python/src/ttio/importers/registry.py`, `exporters/registry.py` | Modify | dispatch to interfaces; drop adapter callables |
| `python/src/ttio/importers/*.py`, `exporters/*.py` | Modify | implement `Reader`/`Writer` |
| `java/.../importers/{Reader,ImportedDataset,ImporterRegistry}.java` | Create | interface + draft + registry |
| `java/.../exporters/{Writer,ExporterRegistry}.java` | Create | interface + registry |
| `java/.../importers/*Reader.java`, `exporters/*Writer.java` | Modify | implement interfaces |
| `java/.../tools/{EncodeCli,ExportCli}.java` | Create | unified CLI |
| `tio-browser/.../{importers,exporters}/*FormatRegistry.java` | Modify | delegate to SDK registry |
| `objc/Source/Import/{TTIOReader.h,TTIOImportedDataset.{h,m},TTIOImporterRegistry.{h,m}}` | Create | protocol + draft + registry |
| `objc/Source/Export/{TTIOWriter.h,TTIOExporterRegistry.{h,m}}` | Create | protocol + registry |
| `objc/Source/{Import,Export}/TTIO*{Reader,Writer}.{h,m}` | Modify | implement protocols |
| `objc/Tools/{TtioEncode.m,TtioExport.m}` + `GNUmakefile` | Create/Modify | CLI |
| each lang's tests + a checked-in golden key/alias list | Create | parity + round-trip fences |
| `CHANGELOG.md` | Modify | `[Unreleased]` per PR |

## Follow-on

After all three ship, the importer/exporter subsystem joins the codec subsystem
as registry-driven in all SDKs. Natural next audit items: P2.5 (shared `Image`
base — touches the draft's `image`/`raman_image`/`ir_image` fields, so some
synergy) and P3.8 (the `spectrum_class` discriminator the run-selection helpers
still switch on).
