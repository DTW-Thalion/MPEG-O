# Shared `Image` Base — Java + tio-browser (PR-2) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox (`- [ ]`) steps.

**Goal:** Java + tio-browser slice of P2.5 (mirrors merged Python #219): extract an abstract `Image` base from `MSImage`/`RamanImage`/`IRImage` (+ `ImageKind`/`SpectralAxisKind`, a generic `spectralAxis()`), replace `SpectralDataset`'s `image()`/`ramanImage()`/`irImage()` with `imageForKind(ImageKind)` + `images()`, and migrate every Java + tio-browser consumer. No `.tio` wire / transport-protocol change.

**Architecture:** `Image` is an abstract class holding the common fields + getters + `kind()` + `spectralAxis()`; the three subclasses extend it (their **public constructors keep identical signatures**, delegating common fields via `super(...)`) and keep their own on-disk group + `writeTo`/`readFrom`. `SpectralDataset.imageForKind(kind)` returns the `Image` base; consumers needing typed access cast (`(MSImage) ds.imageForKind(ImageKind.MS)`).

**Tech Stack:** Java 22, JUnit 5. SDK test: `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -Djacoco.skip=true -Dtest=<Class> test` (full `verify` for the ≥0.84 gate). tio-browser: install SDK then `cd ~/TTI-O/tio-browser && JAVA_HOME=~/jdk25 mvn -o -B test -P linux-x64 -Dhdf5.jar=/usr/share/java/jarhdf5.jar` (the `-P linux-x64` JavaFX profile is REQUIRED). Push from Windows git.

**Hard invariants:**
- **No `.tio` wire change** — each subclass's `writeTo`/`readFrom` bytes + group names (`image_cube`/`raman_image_cube`/`ir_image_cube`) untouched; the base only relocates the common fields (accessed via the same getters). Round-trip fence.
- **No transport protocol change** — `DatasetWalker`'s `visitImage`/`visitRamanImage`/`visitIRImage` + the `AccessUnitVisitor` interface + `TransportWriter`'s `writeImage`/etc. stay; only the accessor they read changes to `imageForKind`. Transport conformance fixtures unchanged.
- **Public image-class constructor signatures unchanged** (subclasses delegate to a protected base ctor) — no construction-site churn.
- **jacoco BUNDLE line ≥0.84** holds (run `mvn verify`).

**Reference:** spec `docs/superpowers/specs/2026-06-04-shared-image-base-design.md`; merged Python PR #219 for the shape. Classes: `java/src/main/java/global/thalion/ttio/{MSImage,RamanImage,IRImage}.java`. Accessors: `SpectralDataset.java:230-238`. Enums: `Enums.java` (IRMode at `:237`).

**Verified facts:**
- Image classes have `private final` common fields + positional public constructors (overloads at MSImage `:64/:94/:108`, etc.) + `writeTo(StorageGroup)`/`readFrom(StorageGroup)` + per-class `GROUP_NAME`. Common fields: `width,height,spectralPoints,tileSize,pixelSizeX,pixelSizeY,scanPattern,intensityCube(double[]),title,isaInvestigationId,identifications,quantifications,provenanceRecords`. Distinct: MS `mzAxis`; Raman `wavenumbers,excitationWavelengthNm,laserPowerMw`; IR `wavenumbers,mode(IRMode),resolutionCmInv`. (Java field is `intensityCube`, not `intensity`.)
- `SpectralDataset.image()`/`ramanImage()`/`irImage()` return the cached field (`:230-238`); lazy/eager read happens in `open`/`readFrom`.
- 20 consumer sites / 6 files: `transport/TransportWriter.java` (`:992-1046`), `transport/DatasetWalker.java` (`:95-102`), `exporters/writers/ImzMLWriterAdapter.java` (`:34`), `tools/TransportEncodeCli.java` (`:68`), tio-browser `exporters/ExportTask.java` (`:130`) + `exporters/ExportEligibility.java` (`:32`). Plus tests.

---

### Task JIT1: `Image` abstract base + enums + subclass MS/Raman/IR

**Files:**
- Create: `java/src/main/java/global/thalion/ttio/Image.java`
- Modify: `Enums.java`, `MSImage.java`, `RamanImage.java`, `IRImage.java`
- Test: `java/src/test/java/global/thalion/ttio/ImageBaseTest.java`

- [ ] **Step 1: Study** the three image classes fully — common vs distinct fields, ALL constructor overloads (param order), `writeTo`/`readFrom`/`toPixelSpectra`, getters. Note how `writeTo`/`readFrom` access fields (direct `this.x` — will become inherited protected fields or `getX()`). Study `Enums.java` for the enum-declaration style (`public enum IRMode { ... }`).
- [ ] **Step 2: Write the fence test** `ImageBaseTest.java`: for each kind, build a populated image, `writeTo(study)` into a fresh `.tio`/group, `readFrom(study)`, assert field-identical round-trip (cube via `Arrays.equals`, axis, all common + distinct fields). Assert `image instanceof Image`, `image.kind() == ImageKind.MS/...`, `image.spectralAxis()` returns the mz/wavenumber array, `spectralAxisKind()` MZ/WAVENUMBER. Run against current code → the round-trip portion PASSES (baseline), base assertions fail.
- [ ] **Step 3: Add enums** to `Enums.java` (matching the nested/sibling style):
  ```java
  public enum ImageKind { MS, RAMAN, IR }
  public enum SpectralAxisKind { MZ, WAVENUMBER }
  ```
- [ ] **Step 4: Create `Image.java`** — `public abstract class Image` with the 13 common fields as `protected final`, a `protected Image(...)` constructor taking them, public getters (`width()`, `height()`, … `intensityCube()`, `title()`, …) lifted from the subclasses, and `public abstract ImageKind kind();` + `public abstract double[] spectralAxis();` + `public abstract SpectralAxisKind spectralAxisKind();`. (Move the common getters' bodies here; they were identical across the three.)
- [ ] **Step 5: Subclass the three** — `public final class MSImage extends Image`: keep only the distinct field(s) (`mzAxis`) + its getter, remove the common fields/getters (now inherited). Each public constructor keeps its IDENTICAL signature but delegates the common params via `super(width, height, …)` and sets the distinct field(s). Implement `kind()` → `ImageKind.MS`, `spectralAxis()` → `mzAxis`, `spectralAxisKind()` → `MZ` (Raman/IR → `wavenumbers`/`WAVENUMBER`). Keep `writeTo`/`readFrom`/`GROUP_NAME`/`toPixelSpectra` UNCHANGED (they now read inherited fields via the protected fields or getters — adjust `this.width` → `width()` / inherited field access as needed, but emit the SAME bytes). `readFrom` (static factory) constructs via the subclass constructor — unchanged.
- [ ] **Step 6: Run** the fence + existing image tests:
  `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -Djacoco.skip=true -Dtest='ImageBaseTest,*Image*' test` → all green, byte-identical round-trips. (Find existing image test classes: `ls java/src/test -R | grep -i image`.)
- [ ] **Step 7: Commit** `refactor(java-image): extract Image base + ImageKind from MS/Raman/IR images`.

---

### Task JIT2: `SpectralDataset` collection + migrate Java SDK consumers

**Files:**
- Modify: `SpectralDataset.java` (remove 3 accessors; add `imageForKind`/`images`)
- Modify: `transport/TransportWriter.java`, `transport/DatasetWalker.java`, `exporters/writers/ImzMLWriterAdapter.java`, `tools/TransportEncodeCli.java`
- Test: `java/src/test/java/global/thalion/ttio/SpectralDatasetImagesTest.java` + migrate existing tests

- [ ] **Step 1: Study** `SpectralDataset.image()`/`ramanImage()`/`irImage()` (`:230-238`) + the backing fields/lazy read. Inventory the SDK consumers (the 4 files above).
- [ ] **Step 2: Failing test** `SpectralDatasetImagesTest.java`: open a `.tio` with an MSImage; assert `ds.imageForKind(ImageKind.MS)` returns it (as `Image`; `instanceof MSImage`), `ds.imageForKind(ImageKind.RAMAN)` is null, `ds.images()` contains only present kinds. (The removal of the old accessors is enforced by the compiler — migrated consumers won't compile against the old names.)
- [ ] **Step 3: Implement on `SpectralDataset`** — remove `image()`/`ramanImage()`/`irImage()`; add `public Image imageForKind(ImageKind kind)` (dispatch to the existing per-kind backing fields/lazy read) + `public Map<ImageKind, Image> images()` (or `List<Image>`; choose Map for typed get — present kinds only). Preserve the lazy/cached read.
- [ ] **Step 4: Migrate the 4 SDK consumers** (cast where typed access needed):
  - `DatasetWalker.java:95-102`: `MSImage ms = (MSImage) dataset.imageForKind(ImageKind.MS); if (ms != null) visitor.visitImage(this, ms);` (+ raman/ir). Visitor calls UNCHANGED.
  - `TransportWriter.java:992-1046`: the has-image checks (`imageForKind(MS) != null`) + `writeImage((MSImage) imageForKind(MS))` etc. `writeImage`/`writeRamanImage`/`writeIRImage` signatures UNCHANGED.
  - `ImzMLWriterAdapter.java:34`: `MSImage img = (MSImage) ds.imageForKind(ImageKind.MS);`.
  - `TransportEncodeCli.java:68`: `tw.writeImageProcessed((MSImage) ds.imageForKind(ImageKind.MS));`.
- [ ] **Step 5: Migrate SDK tests** — every test calling `ds.image()`/`.ramanImage()`/`.irImage()` → `(XImage) ds.imageForKind(...)`. (`grep -rn "\.image()\|\.ramanImage()\|\.irImage()" java/src/test`.)
- [ ] **Step 6: Run** the SDK image/transport/exporter tests:
  `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -Djacoco.skip=true -Dtest='SpectralDatasetImagesTest,*Image*,*Transport*,*ImzML*' test` → green; transport conformance unchanged.
- [ ] **Step 7: Commit** `refactor(java): replace SpectralDataset image accessors with imageForKind/images`.

---

### Task JIT3: tio-browser migration

**Files:**
- Modify: `tio-browser/.../exporters/ExportTask.java` (`:130`), `exporters/ExportEligibility.java` (`:32`)
- Test: adjust any tio-browser test referencing the old accessors

- [ ] **Step 1:** Install the JIT1/JIT2 SDK (`cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -B install -DskipTests -Djacoco.skip=true`). Study the two GUI sites: `ExportTask.java:130` (`dataset.image() == null`) and `ExportEligibility.java:32` (`d.dataset().image() != null`).
- [ ] **Step 2:** Migrate both → `dataset.imageForKind(ImageKind.MS) == null` / `!= null` (import `ImageKind`). Grep the whole tio-browser for any other `.image()`/`.ramanImage()`/`.irImage()` site + migrate.
- [ ] **Step 3: Run** the tio-browser suite:
  `cd ~/TTI-O/tio-browser && JAVA_HOME=~/jdk25 mvn -o -B test -P linux-x64 -Dhdf5.jar=/usr/share/java/jarhdf5.jar 2>&1 | tail -12` → green (0 failures).
- [ ] **Step 4: Commit** `refactor(tio-browser): migrate image accessors to imageForKind`.

---

### Task JIT4: Regression (jacoco gate) + CHANGELOG

- [ ] **Step 1: Java FULL verify** (the coverage gate):
  `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o verify -B 2>&1 | tail -15` → BUILD SUCCESS, "All coverage checks have been met" (≥0.84). The new `Image` base + `imageForKind`/`images` + `ImageBaseTest`/`SpectralDatasetImagesTest` should hold or improve coverage; if it dips below 0.84, add focused tests for the uncovered new lines (real assertions) — do NOT lower the gate.
- [ ] **Step 2:** Re-confirm tio-browser green (from JIT3).
- [ ] **Step 3: CHANGELOG** under `## [Unreleased]`:
  ```markdown
  ### Changed — Shared Image base + uniform image collection (Java + tio-browser)

  `MSImage`/`RamanImage`/`IRImage` now share an abstract `Image` base (common
  geometry, intensity cube, metadata) with an `ImageKind` discriminator and a
  generic `spectralAxis()`. `SpectralDataset`'s `image()`/`ramanImage()`/
  `irImage()` are replaced by `imageForKind(ImageKind)` + `images()`; the
  transport writer/walker, exporter adapter, CLI, and tio-browser export
  eligibility migrated. No `.tio` wire/format or transport-protocol change;
  image-class constructor signatures unchanged. Second of the 3-SDK P2.5 ports
  (Python #219; ObjC follows). (OO-assessment P2.5.)
  ```
- [ ] **Step 4: Commit** `docs: changelog for Java/tio-browser shared Image base (P2.5)`.

---

## Self-review notes (author)
- **No wire change** — base extraction relocates common fields only; subclass `writeTo`/`readFrom`/group untouched (round-trip fence). **No transport protocol change** — visitor + writer signatures stay; only the accessor read changes.
- **No construction churn** — public ctors keep their signatures (delegate to `protected Image(...)`); compiler catches any accessor-removal miss (Java won't build).
- **Casts** at typed consumer sites are expected (`imageForKind` returns `Image`); the transport walker/writer dispatch by type anyway.
- **jacoco gate** is the explicit regression check (JIT4); tio-browser uses `-Djacoco.skip` (no gate).
- ObjC (PR-3) follows with its own plan.
