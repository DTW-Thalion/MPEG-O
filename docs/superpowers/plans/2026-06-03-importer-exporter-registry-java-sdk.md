# Importer / Exporter Registry — Java SDK (PR-J1) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Bring the Java SDK to importer/exporter registry parity with the merged Python port (PR #213): uniform `Reader`/`Writer` interfaces dispatching through a normalized `ImportedDataset` draft, two SDK registries, and a unified `encode`/`export` CLI. **No tio-browser changes** — that is PR-J2 (full GUI dispatch migration), written after this lands.

**Architecture:** A `Reader` produces an in-memory `ImportedDataset`; a single `ImportedDataset.write()` is the lone dataset-write call site (delegating to `SpectralDataset.createMixed`, extended to write images). A `Writer` takes an opened `SpectralDataset` + layer. Registries map a canonical format key → `Reader`/`Writer` instance, mirroring Python's key/alias/extension/required-tool tables.

**Tech Stack:** Java 22 (records, sealed types OK), JUnit 5, htsjdk, jarhdf5. Build/test in WSL with a **login** shell: `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -Djacoco.skip=true test` (or `-Dtest=<Class>`). Push from Windows git. (Local cross-lang Java leg fails with the known JDK 21-vs-22 class-file-66 mismatch; CI is the gate.)

**Hard invariants:**
- **No `.tio` wire/on-disk change.** Image writing reuses `MSImage.writeTo(StorageGroup)` verbatim (the exact bytes the GUI writes today); image-free datasets must be byte-identical to current `create()` output.
- **Mirror Python's registry contents** — same canonical keys, aliases, extensions, required tools for the 11 import / 8 export formats. `fasta`/`fastq` stay CLI-delegated (NOT in the registry), exactly as Python. A cross-language golden-list test asserts the key/alias sets match Python's.
- **No behavior change** to any existing importer/exporter or to `SpectralDataset.create(...)` public overloads (the new image path is additive).
- Out of scope: tio-browser (PR-J2), ObjC (separate), new formats.

**Reference:** combined spec `docs/superpowers/specs/2026-06-03-importer-exporter-registry-parity-design.md`; the merged Python plan `…-python.md` (proven shape); the investigation in this session (signatures table). Package root: `java/src/main/java/global/thalion/ttio/`.

**Verified facts (baseline `main` @ afb71bd2):**
- No `writeMinimal` exists; the one-shot writer is private `SpectralDataset.createMixed(pathOrUrl, title, isaInvestigationId, List<AcquisitionRun> runs, List<WrittenGenomicRun> genomicRuns, Collection<String> genomicRunNames, List<Identification>, List<Quantification>, List<ProvenanceRecord>, List<Subject>, List<Sample>, FeatureFlags, ProgressSink)` (`SpectralDataset.java:1057`), reached via the public `create(...)` overload family (`:748`–`:981`, incl. the mixed-`Map` overload `:890`).
- Images are NOT in any `create` path; the GUI writes them via `MSImage.writeTo(study)` after `FeatureFlags.defaultCurrent().writeTo(root)` + `root.createGroup("study")` (`ImportTask.java:289-305`). `SpectralDataset` already reads them: `image()` `:230`, `ramanImage()` `:234`, `irImage()` `:238`.
- Reader return types (investigation): mzML/Thermo/Waters → `AcquisitionRun` (static `read`); mzTab → `MzTabImport` (record); imzML → `ImzMLImport` (record); nmrML → `NmrMLResult` (`.run()`); JCAMP → `Spectrum` (static `readSpectrum`); BAM/SAM/CRAM → `WrittenGenomicRun` (instance `toGenomicRun`); Bruker → writes `.tio` inline (`read(Path,Path output)`).
- Exporters mostly static; run-selection (`pickRun`/`pickGenomicRun`) lives only in GUI `ExportTask` (`:276`,`:289`).

---

### Task JT1: Image-write support in the dataset write path

**Files:**
- Modify: `java/src/main/java/global/thalion/ttio/SpectralDataset.java`
- Test: `java/src/test/java/global/thalion/ttio/ImageWriteTest.java`

Add MS/Raman/IR image writing to `createMixed` (and one public overload) by relocating the GUI's proven `img.writeTo(study)` calls. Byte-identical to the GUI path by construction.

- [ ] **Step 1: Study** `ImportTask.importImzML` (`tio-browser/.../importers/ImportTask.java:247-305`) for the exact image-write sequence (`FeatureFlags.defaultCurrent().writeTo(root)`, `study` group, `img.writeTo(study)`), and `SpectralDataset.createMixed` (`SpectralDataset.java:1057-1215`) for where the `study` group is created and how `image`/`ramanImage`/`irImage` are read back on open. Confirm `MSImage`, `RamanImage`, `IRImage` each expose `writeTo(StorageGroup)`.

- [ ] **Step 2: Write the failing test**

```java
// java/src/test/java/global/thalion/ttio/ImageWriteTest.java
package global.thalion.ttio;

import static org.junit.jupiter.api.Assertions.*;
import java.nio.file.Path;
import java.util.List;
import org.junit.jupiter.api.Test;

class ImageWriteTest {
    @Test
    void writesAndReadsBackAnMsImage(@org.junit.jupiter.api.io.TempDir Path tmp) throws Exception {
        int w = 3, h = 2, sp = 4;
        double[] cube = new double[w * h * sp];
        for (int i = 0; i < cube.length; i++) cube[i] = i + 1;
        double[] mzAxis = {100.0, 101.0, 102.0, 103.0};
        MSImage img = new MSImage(w, h, sp, 0, 1.0, 1.0, "flyback",
            cube, mzAxis, "imgtitle", "", List.of(), List.of(), List.of());
        Path out = tmp.resolve("img.tio");
        // New public overload: create a dataset carrying only an MS image.
        SpectralDataset.createWithImages(out.toString(), "imgtitle", "TTIO:img",
            img, null, null);
        try (SpectralDataset ds = SpectralDataset.open(out.toString())) {
            assertNotNull(ds.image());
            assertEquals(w, ds.image().width());
            assertEquals(h, ds.image().height());
        }
    }
}
```
> Adjust `MSImage` constructor args and the accessor names (`width()`/`height()`) to the real ones found in Step 1 — match exactly.

- [ ] **Step 3: Run it — expect compile failure** (`createWithImages` missing).

Run: `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -Djacoco.skip=true -Dtest=ImageWriteTest test`
Expected: compilation error / method not found.

- [ ] **Step 4: Implement**
  - Add three nullable params `MSImage image, RamanImage ramanImage, IRImage irImage` to the private `createMixed(...)` (append to the param list; thread `null` from all existing callers so their behavior is unchanged).
  - In `createMixed`, immediately after the `study` group is created/opened and its `title` attribute is set, write any non-null image: `if (image != null) image.writeTo(study);` (and the same for `ramanImage`/`irImage`). Place it consistently with the GUI ordering (after feature flags + title, before/after run sections — match the GUI's effective layout; since images live under `study`, ordering relative to run subgroups does not change run bytes).
  - Add ONE public convenience overload `public static Path createWithImages(String path, String title, String isaInvestigationId, MSImage image, RamanImage ramanImage, IRImage irImage)` that calls `createMixed` with empty run lists + the images. (This is what `ImportedDataset.write()` and the imzML reader use.)
  - Do NOT change any existing public `create(...)` signature; they pass `null, null, null` for images.

- [ ] **Step 5: Run the test — expect PASS.** Then run the existing dataset/create tests to prove image-free output is unchanged:

Run: `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -Djacoco.skip=true -Dtest='ImageWriteTest,SpectralDatasetTest,ImportExportTest' test`
Expected: all green. (If `SpectralDatasetTest` is named differently, run the create-related suite.)

- [ ] **Step 6: Commit**

```bash
cd ~/TTI-O && git add java/src/main/java/global/thalion/ttio/SpectralDataset.java java/src/test/java/global/thalion/ttio/ImageWriteTest.java && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "feat(java): image-write support in SpectralDataset.createMixed"
```

---

### Task JT2: `ImportedDataset` Java draft

**Files:**
- Create: `java/src/main/java/global/thalion/ttio/importers/ImportedDataset.java`
- Test: `java/src/test/java/global/thalion/ttio/importers/ImportedDatasetTest.java`

A record + builder bundling built runs + metadata + images, with `write(Path)` as the single dataset-write call site.

- [ ] **Step 1: Failing test** — build an `ImportedDataset` with one `AcquisitionRun` (use the existing test helper/factory other tests use to build a minimal `AcquisitionRun`; find it via `grep -rn "new AcquisitionRun" java/src/test`), call `.write(tmp)`, reopen, assert `ds.msRuns()` non-empty. Also a test with an `MSImage` asserting `ds.image()` after write.

- [ ] **Step 2: Run — expect compile failure.**

- [ ] **Step 3: Implement**

```java
package global.thalion.ttio.importers;

import global.thalion.ttio.*;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import java.nio.file.Path;
import java.util.*;

/** Normalized in-memory draft every importer produces; its {@link #write}
 *  is the single dataset-write call site. Cross-language equivalent:
 *  Python {@code ttio.importers.imported_dataset.ImportedDataset}. */
public final class ImportedDataset {
    public String title = "";
    public String isaInvestigationId = "";
    public final List<AcquisitionRun> runs = new ArrayList<>();
    public final List<WrittenGenomicRun> genomicRuns = new ArrayList<>();
    public final List<Identification> identifications = new ArrayList<>();
    public final List<Quantification> quantifications = new ArrayList<>();
    public final List<ProvenanceRecord> provenance = new ArrayList<>();
    public final List<Subject> subjects = new ArrayList<>();
    public final List<Sample> samples = new ArrayList<>();
    public MSImage image;
    public RamanImage ramanImage;
    public IRImage irImage;

    public Path write(Path output) { return write(output, null); }

    public Path write(Path output, ProgressSink progress) {
        return SpectralDataset.create(
            output.toString(),
            title.isEmpty() ? "imported" : title,
            isaInvestigationId,
            runs, genomicRuns,
            identifications, quantifications, provenance,
            // images + subjects/samples via the genomic-aware overload;
            // see JT1 for the image params:
            image, ramanImage, irImage,
            subjects, samples,
            progress);
    }
}
```
> The exact `SpectralDataset.create(...)` overload to call depends on JT1. If JT1 added images only to `createMixed` + `createWithImages`, then add ONE more public `create(...)` overload in JT1 (or here) that accepts runs+genomicRuns+metadata+images+subjects/samples+progress and forwards to `createMixed`. Keep the call site single. Adjust to the real signature; if no single overload fits, add it in JT1 rather than splitting the write across calls.

- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** `feat(java-importers): ImportedDataset normalized draft`.

---

### Task JT3: `Reader` and `Writer` interfaces

**Files:**
- Create: `java/src/main/java/global/thalion/ttio/importers/Reader.java`
- Create: `java/src/main/java/global/thalion/ttio/exporters/Writer.java`
- Test: `java/src/test/java/global/thalion/ttio/importers/ReaderWriterInterfaceTest.java`

- [ ] **Step 1: Failing test** — a local stub `class OkReader implements Reader` returning `new ImportedDataset()` compiles and is assignable to `Reader`; same for `Writer`.
- [ ] **Step 2: Run — expect compile failure.**
- [ ] **Step 3: Implement**

```java
// importers/Reader.java
package global.thalion.ttio.importers;
import global.thalion.ttio.ProgressSink;
import java.io.IOException;
import java.util.List;
import java.util.Map;

/** Uniform importer interface: parse sources into an {@link ImportedDataset};
 *  do not write any .tio (the registry/caller calls {@code .write()}).
 *  Cross-language: Python {@code Reader}, ObjC {@code TTIOReader}. */
public interface Reader {
    ImportedDataset read(List<String> inputs, Map<String, Object> opts,
                         ProgressSink progress) throws IOException;
}
```

```java
// exporters/Writer.java
package global.thalion.ttio.exporters;
import global.thalion.ttio.SpectralDataset;
import java.io.IOException;
import java.nio.file.Path;
import java.util.Map;

/** Uniform exporter interface: serialize one layer of an opened dataset.
 *  Cross-language: Python {@code Writer}, ObjC {@code TTIOWriter}. */
public interface Writer {
    void write(SpectralDataset ds, String layer, Path output,
               Map<String, Object> opts) throws IOException;
}
```

- [ ] **Step 4: Run — expect PASS. Step 5: Commit** `feat(java): Reader/Writer interfaces`.

---

### Task JT4: Shared run selection

**Files:**
- Create: `java/src/main/java/global/thalion/ttio/exporters/RunSelection.java`
- Test: `java/src/test/java/global/thalion/ttio/exporters/RunSelectionTest.java`

Port the GUI's `ExportTask.pickRun` (`ExportTask.java:276`) and `pickGenomicRun` (`:289`) into SDK statics, plus an NMR-aware selector matching Python's `_nmr_run`/`_analytical_run` semantics (select by layer name; else the sole run; else error). Used by writers (JT7).

- [ ] **Step 1: Study** `ExportTask.pickRun`/`pickGenomicRun` + Python `exporters/_select.py` for the selection + error-message semantics. Mirror Python's messages where the GUI has none (Python is the cross-language reference).
- [ ] **Step 2: Failing test** — build a `SpectralDataset` with two MS runs; assert `RunSelection.analyticalRun(ds, "run_b")` returns the named one, and `analyticalRun(ds, null)` throws when ambiguous / returns the sole run when unambiguous.
- [ ] **Step 3: Implement** `analyticalRun(SpectralDataset, String layer)`, `nmrRun(SpectralDataset, String layer)`, `genomicRun(SpectralDataset, String layer)` (static). Match Python's KeyError/ValueError message text.
- [ ] **Step 4: Run — PASS. Step 5: Commit** `feat(java-exporters): shared RunSelection helpers`.

---

### Task JT5: Bruker `readDataset` returns a draft

**Files:**
- Modify: `java/src/main/java/global/thalion/ttio/importers/BrukerTDFReader.java`
- Test: `java/src/test/java/global/thalion/ttio/importers/BrukerReaderDatasetTest.java` (skip-guarded; real fixture gated)

Bruker is the one inline-writing importer (`read(Path dDir, Path output)` `:161`). Extract `readDataset(Path dDir, boolean ms2, ProgressSink) -> ImportedDataset`; make `read(...)` delegate via `readDataset(...).write(output)`. Same as Python JT/P4.

- [ ] **Step 1: Study** the run/metadata assembly before the inline write in `read(...)`.
- [ ] **Step 2: Skip-guarded test** asserting `readDataset` exists + returns `ImportedDataset` (mirror Python's P4 guarded test; real round-trip stays gated behind the Bruker fixture/helper).
- [ ] **Step 3: Implement** the extraction; preserve `read`'s public signature + return (`Path`).
- [ ] **Step 4: Run** `-Dtest=BrukerReaderDatasetTest` + any existing Bruker test — pass/skip, none fail.
- [ ] **Step 5: Commit** `refactor(java-importers): Bruker readDataset returns a draft`.

---

### Task JT6: Per-format Reader adapters

**Files:**
- Create: `java/src/main/java/global/thalion/ttio/importers/readers/*.java` (one per format) — or a single `Readers.java` with nested/static classes; match the codebase's preference (check whether small one-class-per-file is the norm in `importers/`).
- Test: `java/src/test/java/global/thalion/ttio/importers/FormatReadersTest.java`

One `Reader`-implementing adapter per format, each normalizing its importer's output into an `ImportedDataset`. Behavior identical to the GUI's per-format `importX` methods (`ImportTask.java`) and to the Python readers.

Adapters (return-type normalization per the investigation table):
- `MzMLReaderAdapter` → `ImportedDataset` with `runs=[MzMLReader.read(inputs[0], progress)]`.
- `ThermoRawReaderAdapter`, `WatersMassLynxReaderAdapter` → `runs=[X.read(inputs[0])]` (no progress param).
- `MzTabReaderAdapter` → from `MzTabReader.read(...)` (`MzTabImport`): build runs + identifications/quantifications (mirror the GUI/Python mapping).
- `NmrMLReaderAdapter` → `runs=[NmrMLReader.read(inputs[0], progress).run()]`.
- `JcampDxReaderAdapter` → wrap `JcampDxReader.readSpectrum(...)` into a single-spectrum `AcquisitionRun` (mirror `ImportTask.importJcampDx` mode selection: Raman/IR/UV-Vis → AcquisitionMode).
- `ImzMLReaderAdapter` → from `ImzMLReader.read(inputs[0], ibd, progress)`: project pixel spectra into an `MSImage` (port `ImportTask.importImzML` cube-building, `:268-289`) and set `draft.image`.
- `BrukerReaderAdapter` → `BrukerTDFReader.readDataset(inputs[0], opts ms2, progress)`.
- `BamReaderAdapter`/`SamReaderAdapter`/`CramReaderAdapter` → `genomicRuns=[ new XReader(inputs[0]).toGenomicRun(name, region, sample, progress) ]` with `name=opts.getOrDefault("name","genomic_0001")`, `region=opts.get("region")`, `sample=opts.get("sample")`; CRAM needs `reference` from `opts`.

opts keys mirror Python: `name`, `sample`, `region`, `reference`, `ms2`, `ibd`, `encoding`. `inputs.get(1)` is the imzML `.ibd` fallback.

- [ ] **Step 1: Study** each importer signature (investigation table) + `ImportTask`'s per-format `importX` for the exact mapping (especially mzTab ident/quant and imzML cube). 
- [ ] **Step 2: Failing test** — `MzMLReaderAdapter().read([mzmlPath], {}, null)` returns an `ImportedDataset` whose `.write(tmp)` reopens with `ds.msRuns()` non-empty; a `@Test` asserting every adapter class implements `Reader`. (Build the mzML fixture by writing a tiny dataset then `MzMLWriter.write(run, path)`, mirroring the Python plan's `_write_mzml`.)
- [ ] **Step 3: Implement** the adapters per the mapping above. Lazy/Direct imports as the codebase prefers.
- [ ] **Step 4: Run — PASS. Step 5: Commit** `feat(java-importers): per-format Reader adapters`.

---

### Task JT7: Per-format Writer adapters

**Files:**
- Create: `java/src/main/java/global/thalion/ttio/exporters/writers/*.java` (mzML, mzTab, nmrML, imzML, JCAMP-DX, ISA, BAM, CRAM)
- Test: `java/src/test/java/global/thalion/ttio/exporters/FormatWritersTest.java`

One `Writer` per export format; bodies mirror the GUI `ExportTask.exportX` (`ExportTask.java`) and Python `exporters/writers.py`, using `RunSelection` (JT4) for run picking and the passed opened `ds`.

- `MzMLWriterAdapter` → `MzMLWriter.write(RunSelection.analyticalRun(ds, layer), output.toString())`.
- `MzTabWriterAdapter` → `MzTabWriter.write(...)` from `ds` idents/quants.
- `NmrMLWriterAdapter` → `NmrMLWriter.write(RunSelection.nmrRun(ds, layer), output.toString())` (with the NMR-type guard + Python's error text).
- `JcampDxWriterAdapter` → pick analytical run, dispatch first spectrum to `JcampDxWriter.write{Raman,IR,UVVis}Spectrum(...)`, `encoding=opts.getOrDefault("encoding","affn")`; same "not vibrational" error text as Python.
- `ImzMLWriterAdapter` → from `ds.image()` (null-guard with Python's message), `ImzMLWriter.write(...)` with the `.ibd` sibling.
- `IsaWriterAdapter` → `ISAExporter.exportTab(ds, outputDir)` (or exportJson per extension).
- `BamWriterAdapter` → `new BamWriter(output).write(RunSelection.genomicRun(ds, layer), ds.provenance()?, sort)` — match the GUI's `ExportTask` BAM call (provenance + sort args).
- `CramWriterAdapter` → requires `opts.reference` (Python's error text), `new CramWriter(output, reference).write(...)`.

- [ ] **Step 1: Study** `ExportTask.exportX` for exact writer calls (BAM provenance/sort args, ISA tab-vs-json, imzML ibd) + Python writers for error text.
- [ ] **Step 2: Failing test** — `MzMLWriterAdapter().write(ds, null, out, {})` produces a non-empty file; a `@Test` that all 8 adapters implement `Writer`.
- [ ] **Step 3: Implement. Step 4: Run — PASS. Step 5: Commit** `feat(java-exporters): per-format Writer adapters`.

---

### Task JT8: ImporterRegistry + ExporterRegistry

**Files:**
- Create: `java/src/main/java/global/thalion/ttio/importers/ImporterRegistry.java`
- Create: `java/src/main/java/global/thalion/ttio/exporters/ExporterRegistry.java`
- Test: `java/src/test/java/global/thalion/ttio/importers/ImporterRegistryTest.java`, `.../exporters/ExporterRegistryTest.java`
- Create (golden list): `java/src/test/resources/registry_keys_golden.txt` (or assert inline)

Registries keyed by canonical format key → `Reader`/`Writer` instance, with `displayName`/`extensions`/`requiredTool`, alias normalization, and `encode`/`export` dispatch. Mirror Python's tables EXACTLY (11 import / 8 export; `fasta`/`fastq` are `CLI_DELEGATED`, not registered).

- [ ] **Step 1: Copy the canonical tables from Python** (`python/src/ttio/importers/registry.py` `_SPECS`+`_ALIASES`+`CLI_DELEGATED`; `exporters/registry.py` likewise). Keys: import `mzml, mztab, imzml, nmrml, jcamp-dx, bruker-timstof, waters-masslynx, thermo-raw, bam, sam, cram`; export `mzml, mztab, nmrml, imzml, jcamp-dx, isa, bam, cram`. Aliases per Python.
- [ ] **Step 2: Failing test** — `ImporterRegistry.registryKeys()` equals the 11-key set; `normalize("thermo")=="thermo-raw"`; `specFor("ome").` throws `UnknownFormatError`; `supportedEncodeFormats()` == registry ∪ {fasta,fastq}; a golden-list test asserting the Java import+export key sets and alias map equal Python's (read the golden file checked in from Python's `registry_keys()`/`registry_keys()` + aliases — generate it once and commit).
- [ ] **Step 3: Implement** a `FormatSpec` (record: `key, displayName, extensions, requiredTool, reader`) + registry statics: `normalize`, `isRegistryFormat`, `specFor`, `registryKeys`, `supportedEncodeFormats`, `encode(String fmt, List<String> inputs, Path output, Map<String,Object> opts)` → `specFor(fmt).reader().read(inputs, opts, progress).write(output)`. `ExporterRegistry` analogous with `export(fmt, tioPath, layer, output, opts)` opening the dataset and calling the writer. `UnknownFormatError extends IllegalArgumentException`.
- [ ] **Step 4: Run — PASS. Step 5: Commit** `feat(java): importer/exporter registries`.

---

### Task JT9: `encode` / `export` CLI

**Files:**
- Create: `java/src/main/java/global/thalion/ttio/tools/EncodeCli.java`, `ExportCli.java`
- Test: `java/src/test/java/global/thalion/ttio/tools/EncodeCliTest.java`

Hand-rolled arg parsing (project convention — `TransportEncodeCli.java`: `for (String a: args)`, usage to stderr, `System.exit(2)`). Dispatch via the registries. `--format`, inputs (1+), `--output`, `--layer`, `--extra k=v` → opts, `--list-formats`.

- [ ] **Step 1: Study** `tools/TransportEncodeCli.java` for the arg-loop + exit-code convention, and Python `tools/workbench_cli.py` `cmd_encode`/`cmd_export` for flag semantics + exit codes (unknown format → 3; importer failure → 2).
- [ ] **Step 2: Failing test** — invoke a testable `EncodeCli.run(String[])` (return int; `main` wraps with `System.exit`): unknown `--format` → 3; a real mzML encode → 0 and output exists; `--list-formats` prints the supported set. (Mirror Python's `test_encode_formats.py` CLI cases.)
- [ ] **Step 3: Implement** `run(String[]) -> int` + `main`. `fasta`/`fastq` → print "delegated; not available via this command yet" and a clear exit (document the parity note; full fasta/fastq + GUI come in PR-J2).
- [ ] **Step 4: Run — PASS. Step 5: Commit** `feat(java-tools): encode/export CLI`.

---

### Task JT10: Full Java suite + CHANGELOG

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1:** `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -Djacoco.skip=true test` — green (the SDK suite; tio-browser is a separate module/PR). Fix any real regression in impl, not tests.
- [ ] **Step 2:** Add under `## [Unreleased]`:

```markdown
### Changed — Importer/exporter dispatch unified behind Reader/Writer interfaces (Java SDK)

The Java SDK gains uniform `Reader`/`Writer` interfaces, an `ImportedDataset`
draft (single dataset-write call site, now incl. images), `ImporterRegistry`/
`ExporterRegistry` mirroring the Python registries, and a unified `encode`/
`export` CLI. `SpectralDataset.createMixed` learned image writing (reusing
`MSImage.writeTo`; image-free output byte-identical). No `.tio` wire change;
supported formats/aliases match Python. tio-browser delegation is the next PR
(PR-J2). Second of the 3-SDK P2.6 ports (Python #213 shipped; ObjC follows).
```

- [ ] **Step 3: Commit** `docs: changelog for Java importer/exporter registry (SDK)`.

---

## Self-review notes (author)

- **Spec coverage:** ImportedDataset (JT2) ✓ · Reader/Writer (JT3) ✓ · registries mirroring Python (JT8) ✓ · CLI (JT9) ✓ · image parity via write-path expansion (JT1, per the user's Fork-1 decision) ✓ · run-selection shared (JT4) ✓ · Bruker draft (JT5) ✓. tio-browser full dispatch migration is **PR-J2** (deliberately deferred; this PR leaves the GUI untouched and working).
- **Type consistency:** `Reader.read(List<String>, Map<String,Object>, ProgressSink) -> ImportedDataset` and `Writer.write(SpectralDataset, String, Path, Map) ` used identically in adapters (JT6/JT7), registries (JT8), and CLI (JT9). `ImportedDataset.write(Path[,ProgressSink])` is the lone create call site. `RunSelection.{analyticalRun,nmrRun,genomicRun}` names consistent JT4↔JT7.
- **Risk watch:** JT1 is wire-adjacent — the "image-free datasets byte-identical" fence (existing create tests must pass unchanged) is mandatory; if relocating `img.writeTo(study)` perturbs run-section bytes, BLOCK. mzTab ident/quant mapping (JT6) and BAM provenance/sort args (JT7) must match the GUI exactly — study before coding. `fasta`/`fastq` intentionally CLI-delegated (Python parity); full support + GUI in PR-J2.
