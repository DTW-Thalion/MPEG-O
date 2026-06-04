# Importer / Exporter Registry — Objective-C — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Bring the Objective-C SDK to importer/exporter registry parity with Python (#213) and Java (#214/#215): uniform `TTIOReader`/`TTIOWriter` protocols dispatching through a `TTIOImportedDataset` draft, two registries mirroring Python's tables, shared run-selection, and a unified `encode`/`export` CLI. **The last SDK of the P2.6 effort.** ObjC has no GUI module → one PR.

**Architecture:** A `TTIOReader` produces an in-memory `TTIOImportedDataset` draft; a single `-writeToPath:error:` is the lone dataset-write site. The draft supports a **write-through delegate** (an `id`-returning block) for the two importers that don't build in-memory runs: **Bruker** (shells out to the Python `bruker_tdf_cli` via `NSTask`) and **imzML** (builds a `TTIOMSImage` and writes via its existing `-writeToFilePath:`). A `TTIOWriter` takes an opened `TTIOSpectralDataset` + layer. Registries are `pthread_once` singletons keyed by canonical NSString format key. Reuse the codec-registry ObjC idioms (PR #211, `objc/Source/Codecs/Registry/`).

**Tech Stack:** GNUstep + clang, ARC (`-fobjc-arc`), `Testing.h` PASS macros. Build/test: `cd ~/TTI-O/objc && ./build.sh check` (fails on any non-PASS via `build-check.log`). Push from Windows git. CI's ObjC job + cross-language conformance is the gate.

**Hard invariants:**
- **No `.tio` wire/on-disk change** — adapters reuse the existing reader/writer code; imzML reuses `TTIOMSImage -writeToFilePath:` (byte-identical to any image `.tio`); Bruker reuses the existing subprocess. The `+writeMinimalToPath:...mixedRuns:...` path is unchanged for run-based drafts.
- **Registry mirrors Python's keys/aliases/extensions** (11 import / 8 export; fasta/fastq CLI-delegated), asserted by a cross-language parity test. `requiredTool` is per-ObjC-reality: **samtools** for bam/sam/cram (matches Python — ObjC shells out to samtools), the vendor strings for thermo/waters, and the Bruker/Thermo readers raise their own clear errors at runtime.
- **No behavior change** to existing readers/writers (only adapters + registry added; Bruker gets an internal extraction like Java).

**Reference:** combined spec `docs/superpowers/specs/2026-06-03-importer-exporter-registry-parity-design.md`; the merged **Java** plan/PRs (#214) as the proven shape; the **codec-registry ObjC port** (#211, `objc/Source/Codecs/Registry/`) for ObjC idioms; the merged Python readers/writers for opts + error-text parity. ObjC SDK root: `objc/Source/`.

**Verified ObjC facts (investigation, baseline `main` @ 283ffcc2):**
- Write path = class methods `+[TTIOSpectralDataset writeMinimalToPath:title:isaInvestigationId:mixedRuns:genomicRuns:identifications:quantifications:provenanceRecords:error:]` (`TTIOSpectralDataset.h:187`) + a `...progress:error:` overload (`:208`). `mixedRuns` is an `NSDictionary` of name→(`TTIOWrittenRun`|`TTIOWrittenGenomicRun`), dispatched by `-isKindOfClass:`. **No image / subjects / samples parameters.**
- Image write = standalone `TTIOMSImage` with `-writeToFilePath:error:` (`Image/TTIOMSImage.h:149`) — writes a complete image `.tio`. Read accessors `msImage`/`ramanImage`/`irImage` exist (category, lazy). `TTIOImzMLReader` returns `TTIOImzMLImport` (`Import/TTIOImzMLReader.h:81`) and **nothing converts it to a `.tio`** — that conversion is the imzML parity gap to fill (port the cube projection from Java `ImzMLReaderAdapter` / Python).
- Reader returns (heterogeneous): mzML/nmrML/Waters → `TTIOSpectralDataset` (class `+readFromFilePath:...`); Thermo → `TTIOSpectralDataset` **stub** (returns error "SDK dependency missing"); mzTab → `TTIOMzTabImport`; imzML → `TTIOImzMLImport`; JCAMP → `TTIOSpectrum` (`+readSpectrumFromPath:`); BAM/SAM/CRAM → `TTIOWrittenGenomicRun` (instance `-initWithPath:` + `-toGenomicRunWithName:region:sampleName:[progress:]error:`); **Bruker → writes `.tio` inline** via `+importFromPath:toOutput:error:` (`Import/TTIOBrukerTDFReader.h:84`; subprocess in `.m:212-270`).
- Exporter inputs (heterogeneous): mzML/ISA → whole `TTIOSpectralDataset` (class); mzTab → idents/quants arrays; NMR/JCAMP → single spectrum; imzML → pixels/`TTIOImzMLImport`; BAM/CRAM → single `TTIOWrittenGenomicRun` (instance `-writeRun:...`); FASTA/FASTQ → run/reference. **No run-selection helper exists.**
- Genomic I/O = `samtools` via `NSTask` (no htslib; `libTTIO_LIBRARIES_DEPEND_UPON` has no htslib — `Source/GNUmakefile:278`). → `requiredTool="samtools"`.
- No unified encode/export CLI (only per-format tools). Tools tested via `NSTask` fork-exec (`Tests/TestC1ToolsCli.m`).
- **Triple-surface manual registration** (easy to under-register): lib sources → `Source/GNUmakefile` `libTTIO_HEADER_FILES` + `libTTIO_OBJC_FILES`; tools → `Tools/GNUmakefile`; tests → `Tests/GNUmakefile` `TTIOTests_OBJC_FILES` + an `extern` decl AND a call site in `Tests/TTIOTestRunner.m`.

---

### Task OT1: `TTIOImportedDataset` draft (+ write-through delegate)

**Files:**
- Create: `objc/Source/Import/TTIOImportedDataset.{h,m}`
- Test: `objc/Tests/TestImportedDataset.m` (+ register in `Tests/GNUmakefile` & `TTIOTestRunner.m`)
- Modify: `objc/Source/GNUmakefile` (register the new sources)

The normalized draft. Mutable properties (title, isaInvestigationId, msRuns dict, genomicRuns dict, identifications/quantifications/provenance arrays, msImage/ramanImage/irImage). `-writeToPath:error:` = single write site: if a `writeDelegate` block is set, call it (write-through: Bruker subprocess / imzML image); else call `+[TTIOSpectralDataset writeMinimalToPath:...mixedRuns:genomicRuns:...]`.

- [ ] **Step 1: Study** `+writeMinimalToPath:...mixedRuns:...` exact selector + the codec-registry class style (`objc/Source/Codecs/Registry/TTIOCodecContext.{h,m}` for an ARC value object). Confirm `TTIOWrittenRun`/`TTIOWrittenGenomicRun` types + how `mixedRuns` merges MS+genomic (or whether genomicRuns is a separate param).
- [ ] **Step 2: Write the failing test** `TestImportedDataset.m` (Testing.h style): build a draft with one `TTIOWrittenRun` (use the test helper other tests use — `grep -rn "TTIOWrittenRun" objc/Tests`), `-writeToPath:error:`, reopen via `+[TTIOSpectralDataset readFromFilePath:error:]`, PASS that an MS run is present. A second test: a draft with a `writeDelegate` block writes a sentinel file and `-writeToPath:` returns its result.
- [ ] **Step 3: Implement** `TTIOImportedDataset.{h,m}` (ARC). Header: mutable props + `@property(copy) TTIOImportedDatasetWriteDelegate writeDelegate;` where `typedef BOOL (^TTIOImportedDatasetWriteDelegate)(NSString *outputPath, NSError **error);` + `-writeToPath:(NSString*)path error:(NSError**)error`. Impl: delegate-or-writeMinimal. Register in `Source/GNUmakefile` (both lists). Register the test (3 surfaces).
- [ ] **Step 4: `cd ~/TTI-O/objc && ./build.sh check`** — green (new tests PASS, nothing breaks).
- [ ] **Step 5: Commit** `feat(objc-import): TTIOImportedDataset draft with write-through delegate`.

---

### Task OT2: `TTIOReader` / `TTIOWriter` protocols

**Files:**
- Create: `objc/Source/Import/TTIOReader.h`, `objc/Source/Export/TTIOWriter.h`
- Test: extend `TestImportedDataset.m` or a tiny `TestReaderWriterProtocols.m`
- Modify: `Source/GNUmakefile` (header registration)

- [ ] **Step 1: Study** `TTIOCodec.h` (`@protocol TTIOCodec <NSObject>`) for the idiom.
- [ ] **Step 2: Failing test** — a file-private class implementing `TTIOReader` returns a `TTIOImportedDataset`; `PASS([obj conformsToProtocol:@protocol(TTIOReader)], ...)`. Same for `TTIOWriter`.
- [ ] **Step 3: Implement** the two protocols:
  - `@protocol TTIOReader <NSObject>` — `- (nullable TTIOImportedDataset *)readInputs:(NSArray<NSString*>*)inputs options:(NSDictionary<NSString*,id>*)opts progress:(nullable TTIOProgressBlock)progress error:(NSError**)error;`
  - `@protocol TTIOWriter <NSObject>` — `- (BOOL)writeDataset:(TTIOSpectralDataset*)ds layer:(nullable NSString*)layer toOutput:(NSString*)output options:(NSDictionary<NSString*,id>*)opts error:(NSError**)error;`
  (Confirm the real `TTIOProgressBlock` typedef name/location from the readers.)
  Register headers in `Source/GNUmakefile`.
- [ ] **Step 4: build.sh check** green. **Step 5: Commit** `feat(objc): TTIOReader/TTIOWriter protocols`.

---

### Task OT3: `TTIORunSelection` shared helpers

**Files:**
- Create: `objc/Source/Export/TTIORunSelection.{h,m}`
- Test: `objc/Tests/TestRunSelection.m` (+ register)
- Modify: `Source/GNUmakefile`

Select a run from an opened dataset by optional layer; mirror Python `_select` / Java `RunSelection` error text. Plus the read-side genomic→written conversion if ObjC exporters need it (study: does `TTIOBamWriter -writeRun:` take a `TTIOWrittenGenomicRun`, and does an opened dataset expose genomic runs as written or read-side? If a conversion is needed, add `+writtenFromGenomicRun:` mirroring Java `RunSelection.toWritten`).

- [ ] **Step 1: Study** how an opened `TTIOSpectralDataset` lists runs (`msRuns`/`nmrRuns`/`genomicRuns` accessors — grep `TTIOSpectralDataset.h`), the NMR discriminant (spectrum class string), and whether genomic runs come back as written or read-side. Read Python `_select.py` for the exact messages.
- [ ] **Step 2: Failing test** — build a dataset with two MS runs; `+[TTIORunSelection analyticalRunIn:layer:error:]` returns the named one; nil + error (Python message) when ambiguous; the sole run when unambiguous.
- [ ] **Step 3: Implement** `+analyticalRunIn:layer:error:`, `+nmrRunIn:layer:error:`, `+genomicRunIn:layer:error:` (+ `+writtenFromGenomicRun:` if needed), Python-parity NSError messages. Register.
- [ ] **Step 4: build.sh check** green. **Step 5: Commit** `feat(objc-export): TTIORunSelection helpers`.

---

### Task OT4: Bruker `readDataset` returns a write-through draft

**Files:**
- Modify: `objc/Source/Import/TTIOBrukerTDFReader.{h,m}`
- Test: `objc/Tests/TestBrukerReaderDataset.m` (+ register)

Bruker writes the `.tio` via Python subprocess. Extract the subprocess call into a private leaf; add `+readDatasetFromPath:error:` returning a `TTIOImportedDataset` whose `writeDelegate` invokes the leaf. Keep `+importFromPath:toOutput:error:` byte-identical (delegating to the leaf).

- [ ] **Step 1: Study** `+importFromPath:toOutput:error:` (`.m:195-270`): the metadata validation + the `NSTask` subprocess + output-exists check.
- [ ] **Step 2: Failing test** — `PASS([TTIOBrukerTDFReader respondsToSelector:@selector(readDatasetFromPath:error:)], ...)` and that it returns a `TTIOImportedDataset` (reflection/smoke; the real subprocess round-trip stays gated on the Python helper). Mirror Java's guarded Bruker test.
- [ ] **Step 3: Implement** a private leaf `_runImportFromPath:toOutput:error:` (the moved subprocess body); `+importFromPath:toOutput:error:` = validate + `_runImport...`; `+readDatasetFromPath:error:` returns `[TTIOImportedDataset datasetWithWriteDelegate:^BOOL(NSString *out, NSError **e){ return [self _runImportFromPath:path toOutput:out error:e]; }]` (after the same up-front metadata validation). No recursion (delegate → leaf, not the public method).
- [ ] **Step 4: build.sh check** green (Bruker tests pass/skip). **Step 5: Commit** `refactor(objc-import): Bruker readDataset write-through draft`.

---

### Task OT5: Per-format `TTIOReader` adapters

**Files:**
- Create: `objc/Source/Import/TTIOReaderAdapters.{h,m}` (file-private adapter classes, one per format — or one file per adapter; match codec-registry style which used file-private classes in one .m)
- Test: `objc/Tests/TestFormatReaders.m` (+ register)
- Modify: `Source/GNUmakefile`

11 adapters normalizing each importer into a `TTIOImportedDataset`, mirroring Java's adapters + Python opts. imzML builds a `TTIOMSImage` (port the cube projection) and sets a write-through delegate to `[image writeToFilePath:]`; jcamp wraps the single `TTIOSpectrum` into a single-spectrum run with mode select; genomic uses `name`/`region`/`sample`/`reference` opts; Bruker adapter returns `+[TTIOBrukerTDFReader readDatasetFromPath:error:]`.

- [ ] **Step 1: Study** each reader selector (facts above) + Java's `importers/readers/*Adapter.java` for the exact normalization (esp. imzML cube, jcamp mode, mzTab idents/quants) + Python opts keys.
- [ ] **Step 2: Failing test** — each adapter `conformsToProtocol:@protocol(TTIOReader)`; a real mzML round-trip: write a tiny `.tio`, export to mzML (`+[TTIOMzMLWriter writeDataset:toPath:...]`), adapter reads it → draft → `-writeToPath:` → reopen → PASS MS run present.
- [ ] **Step 3: Implement** the 11 adapters (ARC, file-private). Each: build `TTIOImportedDataset`, set fields from the underlying reader's output. mzTab → idents/quants; imzML → `msImage` + write-through delegate; jcamp → single-spectrum run (Raman/IR/UVVis → acquisition mode, like Java); genomic → genomicRuns; Bruker → the OT4 draft; thermo → calls the stub reader (errors at runtime, fine). Register sources.
- [ ] **Step 4: build.sh check** green. **Step 5: Commit** `feat(objc-import): per-format TTIOReader adapters`.

---

### Task OT6: Per-format `TTIOWriter` adapters

**Files:**
- Create: `objc/Source/Export/TTIOWriterAdapters.{h,m}`
- Test: `objc/Tests/TestFormatWriters.m` (+ register)
- Modify: `Source/GNUmakefile`

8 adapters (mzML, mzTab, nmrML, imzML, jcamp, isa, bam, cram) mirroring Java's writer adapters + Python error text, using `TTIORunSelection` for run picking + the passed opened dataset.

- [ ] **Step 1: Study** each exporter selector + Java's `exporters/writers/*Adapter.java` (run picking, encoding/reference opts, NMR/jcamp first-spectrum + error messages, imzML image null-guard, ISA dir/json).
- [ ] **Step 2: Failing test** — each adapter `conformsToProtocol:@protocol(TTIOWriter)`; a real mzML export: build a `.tio`, open it, adapter writes mzML, PASS output exists/non-empty.
- [ ] **Step 3: Implement** the 8 adapters. mzML/ISA → whole dataset; nmrML/jcamp → `TTIORunSelection` analytical/nmr run → first spectrum → modality writer (Python error text); imzML → `ds.msImage` null-guard (Python message) → `TTIOImzMLWriter`; bam/cram → `TTIORunSelection.genomicRun` (+ `writtenFrom...` if needed) → `TTIOBamWriter`/`TTIOCramWriter` (cram needs `reference` opt, Python message). Register.
- [ ] **Step 4: build.sh check** green. **Step 5: Commit** `feat(objc-export): per-format TTIOWriter adapters`.

---

### Task OT7: `TTIOImporterRegistry` / `TTIOExporterRegistry` (+ parity test)

**Files:**
- Create: `objc/Source/Import/TTIOImporterRegistry.{h,m}`, `objc/Source/Export/TTIOExporterRegistry.{h,m}`
- Test: `objc/Tests/TestImporterExporterRegistry.m`, `objc/Tests/TestRegistryParity.m` (+ register)
- Modify: `Source/GNUmakefile`

`pthread_once` singletons (like `TTIOCodecRegistry`) keyed by canonical NSString format key → adapter instance, with displayName/extensions/requiredTool, alias normalization, `+normalize:`, `+specForFormat:error:`, `+registryKeys`, `+supportedEncodeFormats`/`+supportedExportFormats`, and `+encodeFormat:inputs:output:options:error:` / `+exportFormat:tioPath:layer:output:options:error:` dispatch. Mirror Python's tables (11 import / 8 export; fasta/fastq CLI-delegated). `requiredTool`: bam/sam/cram="samtools", bruker-timstof="python", thermo-raw="ThermoRawFileParser", waters-masslynx="masslynxraw".

- [ ] **Step 1: Copy the canonical tables** from `python/src/ttio/importers/registry.py` + `exporters/registry.py` (keys/display/extensions/aliases/CLI_DELEGATED). Verify against the live Python files.
- [ ] **Step 2: Failing tests** — `TestImporterExporterRegistry`: registryKeys == the 11/8 sets; `+normalize:@"thermo"` == `@"thermo-raw"`; `+specForFormat:@"ome"` → nil+error; encode dispatch for mzml round-trips. `TestRegistryParity`: ObjC import+export key sets + alias maps equal a hardcoded Python-sourced golden list (the cross-language fence).
- [ ] **Step 3: Implement** both registries (pthread_once, NSDictionary<NSString*, id<TTIOReader/Writer>> + a spec object/struct carrying displayName/extensions/requiredTool). Dispatch: `encode` = `[[spec.reader readInputs:inputs options:opts progress:nil error:&e] writeToPath:output error:&e]`; `export` opens the dataset (`+readFromFilePath:`) then `[spec.writer writeDataset:ds layer:layer toOutput:output options:opts error:&e]`. Register sources + both tests (3 surfaces each).
- [ ] **Step 4: build.sh check** green. **Step 5: Commit** `feat(objc): importer/exporter registries + parity test`.

---

### Task OT8: `encode` / `export` CLI tools

**Files:**
- Create: `objc/Tools/TtioEncode.m`, `objc/Tools/TtioExport.m`
- Modify: `objc/Tools/GNUmakefile` (register both tools)
- Test: `objc/Tests/TestEncodeExportCli.m` (NSTask fork-exec, like `TestC1ToolsCli.m`) (+ register)

Hand-rolled arg parsing → registry dispatch. `--format`, inputs, `--output`, `--layer`, `--extra k=v`, `--list-formats`. Exit codes mirror Python (0 success, 2 importer/exporter failure or bad args, 3 unsupported format). fasta/fastq → "delegated" message + exit 3 (documented divergence; ObjC has no unified fasta/fastq import CLI yet).

- [ ] **Step 1: Study** an existing tool (`objc/Tools/TtioToMzML.m` or `TtioTransportEncode.m`) for the `main(int,char**)` + arg + exit-code style, and `Tests/TestC1ToolsCli.m` `c1RunTool` for the fork-exec test harness + the tools-dir path.
- [ ] **Step 2: Failing test** — `TtioEncode` unknown format → exit 3; `--list-formats` → 0; a real mzML encode → 0 + output exists. (Build a fixture mzML as in OT5.)
- [ ] **Step 3: Implement** both tools (dispatch via the registries) + register in `Tools/GNUmakefile` (TOOL_NAME + per-tool `_OBJC_FILES`/`_TOOL_LIBS`/`_LIB_DIRS`). Register the test.
- [ ] **Step 4: build.sh check** green. **Step 5: Commit** `feat(objc-tools): encode/export CLI`.

---

### Task OT9: Registration audit + full check + CHANGELOG

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Audit the triple-surface registration** — every new `.h`/`.m` in `Source/GNUmakefile` (both lists); both new tools in `Tools/GNUmakefile`; every new test in `Tests/GNUmakefile` AND `Tests/TTIOTestRunner.m` (extern + call). Grep to confirm none dropped.
- [ ] **Step 2: Full `cd ~/TTI-O/objc && ./build.sh check`** — all green; remove any stray `build-check.log` from the worktree before finishing (it's a build artifact, must not be committed).
- [ ] **Step 3: CHANGELOG** under `## [Unreleased]`:
  ```markdown
  ### Changed — Importer/exporter dispatch unified behind Reader/Writer protocols (Objective-C)

  The ObjC SDK gains `TTIOReader`/`TTIOWriter` protocols, a `TTIOImportedDataset`
  draft (single write site, with a write-through delegate for the subprocess-backed
  Bruker importer and for imzML image output via `TTIOMSImage`), `TTIORunSelection`
  helpers, per-format adapters, `TTIOImporterRegistry`/`TTIOExporterRegistry`
  mirroring the Python registries (11 import / 8 export; `fasta`/`fastq`
  CLI-delegated; genomic `requiredTool="samtools"` per ObjC's samtools-subprocess
  reality), a cross-language registry parity test, and `TtioEncode`/`TtioExport`
  CLI tools. imzML import now produces a `.tio` (previously parse-only). No `.tio`
  wire change. Completes the 3-SDK P2.6 importer/exporter parity (Python #213,
  Java #214/#215).
  ```
- [ ] **Step 4: Commit** `docs: changelog for ObjC importer/exporter registry`.

---

## Self-review notes (author)

- **Spec coverage:** draft (OT1) + protocols (OT2) + registries mirroring Python (OT7) + CLI (OT8) + parity test (OT7). The write-through delegate (OT1) covers BOTH Bruker (OT4) AND imzML image output (OT5) — so NO wire-adjacent `writeMinimal` image expansion is needed (unlike Java; ObjC's standalone `TTIOMSImage` writer makes the delegate cleaner). imzML import→.tio is NEW capability (parity with Python/Java).
- **Per-language `requiredTool`:** ObjC genomic = "samtools" (matches Python; ObjC shells out — opposite of Java's htsjdk→null). The parity test fences keys/aliases, NOT requiredTool (which legitimately differs per language).
- **Risk watch:** (1) **triple-surface registration** — the #1 ObjC footgun; audit in OT9. (2) imzML cube projection must match Java/Python (port carefully, OT5). (3) `TTIORunSelection` is new (ObjC had none) — get the read-side genomic→written conversion right (OT3). (4) Bruker subprocess byte-identical (OT4, like Java). (5) heterogeneous reader returns — each adapter normalizes (OT5). (6) NMR/jcamp export = selected-run first-spectrum + Python error text (OT6), matching the Java decision.
- **Type consistency:** `TTIOReader readInputs:options:progress:error: -> TTIOImportedDataset`; `TTIOWriter writeDataset:layer:toOutput:options:error:`; `TTIOImportedDataset -writeToPath:error:` (single site, delegate-aware); `TTIORunSelection` used by writer adapters + registries' `export`.
