# Importer / Exporter Registry — tio-browser GUI Migration (PR-J2) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Migrate the tio-browser GUI to dispatch the registry-covered formats through the Java SDK importer/exporter registry + shared `RunSelection` (landed in PR-J1, #214), and source the GUI format-registry metadata from the SDK — removing the GUI's parallel per-format import/export logic and its duplicated `toWritten`/`pickRun`/`pickGenomicRun`. `fasta`/`fastq` (+ `FASTA (reference)`/`(reads)`) stay GUI-local (CLI-delegated in every SDK by design — preserves the cross-language `RegistryParityTest` fence).

**Architecture:** The GUI `ImportTask`/`ExportTask` per-format `importX`/`exportX` bodies are replaced by SDK-adapter calls that preserve the GUI's **two-phase progress**: `ImporterRegistry.specFor(key).reader().read(inputs, opts, readerSink).write(target, writerSink)` for import; `ExporterRegistry.specFor(key).writer().write(ds, layer, target, opts)` (writer-phase sink) for export. A display-name→canonical-key map bridges the GUI's display names (`"mzML (indexed)"`, `"Bruker timsTOF"`) to SDK keys (`mzml`, `bruker-timstof`). The GUI format registries build their common-format rows from the SDK `FormatSpec`/`ExportSpec` (extensions, required tool) + GUI-only `SourceKind`/`ExtraField`, appending the local fasta/fastq/variant rows.

**Tech Stack:** Java 22, JavaFX, JUnit 5. tio-browser depends on the SDK jar — build/test:
```
cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -B install -DskipTests -Djacoco.skip=true
cd ~/TTI-O/tio-browser && JAVA_HOME=~/jdk25 mvn -o -B test -Dhdf5.jar=/usr/share/java/jarhdf5.jar
```
(tio-browser builds with `-Djacoco.skip=true` — no coverage gate on the GUI module.) Push from Windows git. CI's `tio-browser — build & test` job is the gate.

**Hard invariants:**
- **No `.tio` wire/on-disk change** — the SDK adapters produce identical output to the GUI's former per-format logic (the SDK adapters were built in PR-J1 to replicate `ImportTask`/`ExportTask`'s exact behavior — see PR #214). Image import (imzML) now flows through the SDK draft path (`createWithImages`/`ImportedDataset`), which reuses `MSImage.writeTo` — byte-identical to the GUI's old raw-HDF5 write.
- **No UX regression** — two-phase progress (reader 0–50%, writer 50–100%) preserved; the same formats remain available/greyed via `Diagnostics`.
- **fasta/fastq stay GUI-local** — not added to the SDK registry; `RegistryParityTest` (SDK) stays green.
- **No SDK changes** — PR-J2 is tio-browser-only (the SDK API it needs already shipped in PR-J1). The one exception permitted: if a tiny SDK accessor is genuinely missing for the GUI to build opts/specs, add it minimally and note it.

**Reference:** combined spec `docs/superpowers/specs/2026-06-03-importer-exporter-registry-parity-design.md`; PR-J1 (#214, on main) for the SDK API; this session's GUI investigation. GUI root: `tio-browser/src/main/java/global/thalion/ttio/browser/`.

**Verified GUI facts (baseline `main` @ 8e0a8af7):**
- `ImportTask.call()` switches on `spec.name` (13 cases) → `importMzML/importNmrML/importMzTab/importBamLike/importFasta/importFastq/importImzML/importJcampDx/importWatersMassLynx/importThermoRaw/importBrukerTimsTOF`. Each non-fasta/fastq importX builds a run (or image) then `writeAnalytical`/`writeGenomic` (`SpectralDataset.create`) — except `importImzML` writes the image via raw HDF5. Two phases: `phaseProgress.readerSink()` (0–50), `writerSink()` (50–100), `emitFinal()`.
- `ExportTask.call()` switches on `spec.name` (11 cases) → `exportMzML/exportMzTab/exportNmrML/exportJcampDx/exportIsa/exportBamLike/exportFastaReference/exportFastaReads/exportFastq/exportImzML`, using `pickRun()`/`pickGenomicRun()`/`toWritten()`. `toWritten` is now also `RunSelection.toWritten` (SDK).
- `ImportConfig` fields: `sourcePath, targetTio, datasetTitle, runName, cramReference, fastaTreatAs, fastqPhred`. `ExportConfig`: `targetPath, selectedRunName, cramReference, jcampEncoding, mzTabDialect, imzMlMode, fastaLineWidth, fastqPhred, gzipOutput`.
- `ImportFormatRegistry`: `all()`/`available()` over `SPECS` (13). `ExportFormatRegistry`: 11. Specs carry `name, readerClassFqn/writerClassFqn, sourceKind/eligibility, fileExts, extras(ExtraField), description, requiredBinary`. Availability via `Diagnostics`.
- SDK API (PR-J1): `ImporterRegistry.{specFor,registryKeys,normalize}` + `FormatSpec{key,displayName,extensions,requiredTool,reader}`; `ExporterRegistry` + `ExportSpec{...,writer}`; `ImportedDataset` (mutable fields + `write(Path,ProgressSink)`); `RunSelection.{analyticalRun,nmrRun,genomicRun,toWritten}`; `SpectralDataset.createWithImages`.

---

### Task GT1: Display-name → SDK-key bridge

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/SdkFormatKeys.java`
- Test: `tio-browser/src/test/java/global/thalion/ttio/browser/SdkFormatKeysTest.java`

A small map from each GUI display name to its SDK canonical key (and a "GUI-local" sentinel for fasta/fastq/variants). Used by both tasks for dispatch + registry delegation.

- [ ] **Step 1: Study** the GUI display names (ImportFormatRegistry SPECS `name` values + ExportFormatRegistry) and the SDK keys (`ImporterRegistry.registryKeys()` = mzml,mztab,imzml,nmrml,jcamp-dx,bruker-timstof,waters-masslynx,thermo-raw,bam,sam,cram; `ExporterRegistry.registryKeys()` = mzml,mztab,nmrml,imzml,jcamp-dx,isa,bam,cram).
- [ ] **Step 2: Failing test** — assert `SdkFormatKeys.importKey("mzML")=="mzml"`, `importKey("Bruker timsTOF")=="bruker-timstof"`, `importKey("FASTA")==null` (GUI-local), and `exportKey("mzML (indexed)")=="mzml"`, `exportKey("ISA-Tab/JSON")=="isa"`, `exportKey("FASTA (reference)")==null`, `exportKey("FASTQ")==null`.
- [ ] **Step 3: Implement** two static `Map<String,String>` (import display→key, export display→key) covering the 11 import + 8 export registry formats; `importKey(name)`/`exportKey(name)` return the key or `null` if GUI-local. (Import: mzML→mzml, mzTab→mztab, imzML→imzml, nmrML→nmrml, JCAMP-DX→jcamp-dx, Bruker timsTOF→bruker-timstof, Waters MassLynx→waters-masslynx, Thermo .raw→thermo-raw, BAM→bam, SAM→sam, CRAM→cram; FASTA/FASTQ→null. Export: mzML (indexed)→mzml, mzTab→mztab, nmrML→nmrml, imzML→imzml, JCAMP-DX→jcamp-dx, ISA-Tab/JSON→isa, BAM→bam, CRAM→cram; FASTA (reference)/FASTA (reads)/FASTQ→null.)
- [ ] **Step 4: Run — PASS. Step 5: Commit** `feat(tio-browser): SDK format-key bridge`.

---

### Task GT2: GUI format registries delegate metadata to the SDK

**Files:**
- Modify: `tio-browser/.../importers/ImportFormatRegistry.java`, `ImportFormatSpec.java`
- Modify: `tio-browser/.../exporters/ExportFormatRegistry.java`, `ExportFormatSpec.java`
- Modify: tests `ImportFormatRegistryTest`, `ExportFormatRegistryTest`, `*DiagnosticsTest`

For the registry-covered rows, source `fileExts` + `requiredBinary` from the SDK `FormatSpec`/`ExportSpec` (single source of truth), keeping GUI-only `SourceKind`/`ExtraField`/`description` + the fasta/fastq/variant rows local. Counts stay 13 import / 11 export.

- [ ] **Step 1: Study** the current `buildSpecs()` in both GUI registries + the `*DiagnosticsTest` assertions (binary-gated sets, exact `requiredBinary` strings, counts 13/11).
- [ ] **Step 2:** Adjust the failing tests first if the source-of-truth change alters any asserted value (it should NOT — SDK extensions/required-tools were copied from the GUI in PR-J1, so values match; verify and keep tests asserting 13/11 + the same names/binaries).
- [ ] **Step 3: Implement** `buildSpecs()` to, for each registry-covered display name, pull `extensions`/`requiredTool` from `ImporterRegistry.specFor(SdkFormatKeys.importKey(name))` (and export equiv), and construct the GUI spec with GUI-only fields. Append the fasta/fastq/variant rows with their existing hardcoded values. Keep `all()`/`available()`/`Diagnostics` behavior identical.
- [ ] **Step 4:** Run `cd ~/TTI-O/tio-browser && JAVA_HOME=~/jdk25 mvn -o -B test -Dhdf5.jar=/usr/share/java/jarhdf5.jar -Dtest='ImportFormatRegistryTest,ExportFormatRegistryTest,ImportFormatRegistryDiagnosticsTest,ExportFormatRegistryDiagnosticsTest'` — all green (after SDK `install` from the build block above).
- [ ] **Step 5: Commit** `refactor(tio-browser): GUI format registries delegate metadata to SDK`.

---

### Task GT3: ImportTask dispatches registry formats via SDK adapters

**Files:**
- Modify: `tio-browser/.../importers/ImportTask.java`
- Test: `tio-browser/.../importers/ImportTaskTest.java` (extend or create)

Replace the 11 registry-covered `importX` bodies with SDK-adapter calls preserving two-phase progress; keep `importFasta`/`importFastq` local. Build `opts` from `config`.

- [ ] **Step 1: Study** each registry-covered `importX` + `writeAnalytical`/`writeGenomic` + the `config` fields each uses (cramReference→`reference`, runName→`name`, datasetTitle, etc.), and the imzML raw-HDF5 path (now replaced by the SDK ImzMLReaderAdapter → `ImportedDataset.image` → `.write`).
- [ ] **Step 2: Failing test** — an `ImportTaskTest` that runs a real mzML import through `ImportTask` (or a new thin `dispatchViaRegistry` helper) and asserts the `.tio` is produced with the MS run; ideally also imzML (image present). Reuse existing GUI import-test fixtures (`grep -rn "ImportTask\|ImportConfig" tio-browser/src/test`).
- [ ] **Step 3: Implement** in `call()`: for a display name where `SdkFormatKeys.importKey(name) != null`, do:
  ```java
  String key = SdkFormatKeys.importKey(spec.name);
  Map<String,Object> opts = importOpts();   // build from config: name=runName, reference=cramReference, etc.
  List<String> inputs = List.of(config.sourcePath.toString());  // (+ ibd if applicable)
  ImportedDataset draft = ImporterRegistry.specFor(key).reader().read(inputs, opts, readerSink);
  if (config.datasetTitle != null && !config.datasetTitle.isEmpty()) draft.title = config.datasetTitle;
  draft.write(config.targetTio, writerSink);
  ```
  Keep the `case "FASTA"/"FASTQ"` branches calling the existing `importFasta`/`importFastq`. Delete the now-dead `importMzML/importNmrML/importMzTab/importImzML/importJcampDx/importBamLike/importWatersMassLynx/importThermoRaw/importBrukerTimsTOF` + `writeAnalytical`/`writeGenomic` (now unused). Preserve `phaseProgress.emitFinal()` + logging.
- [ ] **Step 4: Run** the import tests (after SDK install) — green; two-phase progress still emits (assert if the test harness checks samples).
- [ ] **Step 5: Commit** `refactor(tio-browser): ImportTask dispatches via SDK registry`.

---

### Task GT4: ExportTask dispatches registry formats via SDK; drop duplicated helpers

**Files:**
- Modify: `tio-browser/.../exporters/ExportTask.java`
- Test: `tio-browser/.../exporters/ExportTaskTest.java` (extend or create)

Replace the 8 registry-covered `exportX` bodies with SDK calls; keep `exportFastaReference`/`exportFastaReads`/`exportFastq` local; delete the GUI's private `toWritten`/`pickRun`/`pickGenomicRun` in favor of `RunSelection`.

- [ ] **Step 1: Study** each registry-covered `exportX` + the `config` fields → opts (jcampEncoding→`encoding`, cramReference→`reference`, mzTabDialect→`dialect`?, imzMlMode→`mode`?, selectedRunName→layer). NOTE: the SDK writer adapters (PR-J1) accept a limited opts set — confirm which opts each SDK writer reads (`encoding`, `reference`); GUI-only export options not supported by the SDK writer (e.g. mzTab dialect, imzML mode, gzip) either map to opts the SDK writer honors or remain a known limitation — if an SDK writer lacks an option the GUI exposed, FLAG it (the export may lose that knob; report rather than silently drop).
- [ ] **Step 2: Failing test** — an `ExportTaskTest` exporting a built `.tio` to mzML (+ one genomic, e.g. BAM) through `ExportTask`, asserting the output file exists/non-empty. Reuse existing export-test fixtures.
- [ ] **Step 3: Implement** in `call()`: for a display name where `SdkFormatKeys.exportKey(name) != null`:
  ```java
  String key = SdkFormatKeys.exportKey(spec.name);
  Map<String,Object> opts = exportOpts();   // encoding, reference, ...
  ExporterRegistry.export(key, config.sourceTio /*the opened .tio path*/, config.selectedRunName,
                          config.targetPath, opts);
  ```
  (Use `ExporterRegistry.export(...)` which opens the dataset + dispatches; OR if the GUI must thread the writer-phase sink, open the dataset in the GUI and call `ExporterRegistry.specFor(key).writer().write(ds, layer, target, opts)` with the writerSink-aware path — check whether the SDK writer adapters accept a ProgressSink; PR-J1's `Writer.write(ds, layer, output, opts)` has NO sink param, so GUI export progress is single-phase — preserve current behavior as closely as possible and FLAG any progress regression.) Keep the fasta/fastq cases local. Delete the GUI's private `toWritten` (use `RunSelection.toWritten` if any remaining local exporter needs it — fasta reads/fastq do: have them call `RunSelection.toWritten`/`RunSelection.genomicRun`), `pickRun`, `pickGenomicRun`.
- [ ] **Step 4: Run** export tests (after SDK install) — green.
- [ ] **Step 5: Commit** `refactor(tio-browser): ExportTask dispatches via SDK registry; drop duplicate helpers`.

---

### Task GT5: Full tio-browser suite + CHANGELOG

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1:** Build SDK then run the WHOLE tio-browser suite:
  ```
  cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -B install -DskipTests -Djacoco.skip=true
  cd ~/TTI-O/tio-browser && JAVA_HOME=~/jdk25 mvn -o -B test -Dhdf5.jar=/usr/share/java/jarhdf5.jar
  ```
  Green (0 failures/errors; skips OK). Fix real regressions in impl, not tests. If a GUI export option (mzTab dialect / imzML mode / gzip) is genuinely unsupported by the SDK writer, document it in KNOWN-ISSUES/CHANGELOG and (if it breaks a test) keep that one export GUI-local with a tracked follow-up rather than dropping the knob silently.
- [ ] **Step 2:** Add under `## [Unreleased]`:
  ```markdown
  ### Changed — tio-browser dispatches imports/exports via the SDK registry (Java)

  The desktop GUI's `ImportTask`/`ExportTask` now dispatch the registry-covered
  formats through the Java SDK `ImporterRegistry`/`ExporterRegistry` and shared
  `RunSelection` (replacing the per-format `importX`/`exportX` bodies and the
  duplicated `toWritten`/`pickRun`/`pickGenomicRun`); the GUI format registries
  source extensions/required-tool from the SDK. `fasta`/`fastq` (and the
  FASTA reference/reads export modes) remain GUI-local (CLI-delegated in the SDK).
  Two-phase import progress preserved; no `.tio` change. Completes the P2.6
  importer/exporter parity for Java (SDK in #214). ObjC port follows.
  ```
- [ ] **Step 3: Commit** `docs: changelog for tio-browser registry dispatch migration`.

---

## Self-review notes (author)

- **Spec coverage:** GUI delegates metadata (GT2) + dispatch migration (GT3/GT4) + dedup helpers (GT4) = the "full dispatch migration" the user chose, bounded by the parity fence (fasta/fastq GUI-local, per the user's GT-scope answer).
- **Risk watch:** (1) **two-phase progress** — import preserves it via `read(readerSink)`+`write(writerSink)`; export may regress to single-phase because the SDK `Writer` has no sink param — FLAG/measure, accept or add a sink-aware overload only if needed. (2) **GUI-only export knobs** (mzTab dialect, imzML mode, gzip, fasta line width) — the SDK writers may not honor all; surface any gap rather than silently dropping. (3) **imzML import** now goes through the SDK draft+`createWithImages` instead of the GUI's raw-HDF5 write — byte-identical (same `MSImage.writeTo`), but verify the GUI's imzML import test passes. (4) display-name↔key map must be exhaustive (GT1 test).
- **Type consistency:** `SdkFormatKeys.importKey/exportKey` → SDK key → `ImporterRegistry.specFor(key).reader()` / `ExporterRegistry.specFor(key).writer()`; `ImportedDataset.write(Path, ProgressSink)`; `RunSelection.{genomicRun,toWritten}` for the remaining local genomic exporters.
