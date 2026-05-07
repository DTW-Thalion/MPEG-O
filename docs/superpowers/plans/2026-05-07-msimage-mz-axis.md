# MSImage `mz_axis` cross-language parity — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persisted `mz_axis` to `MSImage` in all three reference languages (Java, Python, ObjC), plus the `SpectralDataset.image()` accessors needed to navigate to it, so tio-browser's imzML export can call `MSImage.toPixelSpectra()` and feed `ImzMLWriter.write()`.

**Architecture:** Composition pattern — `MSImage` stays a standalone value class in Java/Python (matching today's shape) while ObjC retains its `TTIOMSImage : TTIOSpectralDataset` subclass relationship (also matching today). One additive 1-D HDF5 dataset (`/study/image_cube/mz_axis`, FLOAT64, length=`spectral_points`) under the existing `image_cube` group. Legacy v1.1.x files read as empty axis. Library version bumps `1.1.0 → 1.2.0` (additive minor).

**Tech Stack:** Java 17 + Maven + JUnit 5 (h5py via JNA HDF5 bindings); Python 3.11 + h5py + pytest; Objective-C + GNUstep + raw `<hdf5.h>` (libhdf5-dev on WSL). Conformance test orchestrated from Python invoking Java + ObjC reader binaries as subprocesses.

**Spec:** `docs/superpowers/specs/2026-05-07-msimage-mz-axis-design.md` (committed at `a2d5658`).

---

## Cross-cutting conventions

- **Working directory:** all WSL commands run inside `~/TTI-O.worktrees/msimage-mz-axis`. Never `cd` to `/home/toddw/TTI-O` (that's the main worktree) or to `~/TTI-O.worktrees/tio-browser` (that's the Phase 9 worktree).
- **Build dispatch from Windows:** `wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis && <cmd>'`. Build runs in WSL; pushes use Windows-side git per memory pattern `feedback_git_push_via_windows.md`.
- **Commits:** small, frequent, conventional-commit prefixes (`feat:`, `fix:`, `test:`, `docs:`, `refactor:`, `chore:`). One commit per task step labelled "Commit".
- **Tests:** TDD throughout. Every new public method/class lands with the failing test that drove it.
- **Build envs:**
  - Java: `mvn -B test -Dhdf5.jar=/usr/share/java/jarhdf5.jar`
  - Python: `pip install -e python/[dev]` then `pytest python/tests/`
  - ObjC: `cd objc && make` (assumes GNUstep env per memory `feedback_verify_env_on_start.md`)

---

# Phase 0 — Java parity

**Goal:** Java `MSImage` carries `mzAxis`; `SpectralDataset` exposes `image()`; both have unit-test coverage including legacy round-trip. Phase 0 is self-contained — Phase 1 depends on this passing.

**Files:**
- Modify: `java/src/main/java/global/thalion/ttio/MSImage.java`
- Modify: `java/src/main/java/global/thalion/ttio/SpectralDataset.java`
- Create: `java/src/test/java/global/thalion/ttio/MSImageMzAxisTest.java`
- Modify: `java/src/test/java/global/thalion/ttio/SpectralDatasetTest.java`

---

## Task 0.1: Java — failing test for `MSImage.mzAxis` round-trip

**Files:**
- Create: `java/src/test/java/global/thalion/ttio/MSImageMzAxisTest.java`

- [ ] **Step 1: Write the failing test**

Create `java/src/test/java/global/thalion/ttio/MSImageMzAxisTest.java`:

```java
/* TTI-O Java tests / SPDX-License-Identifier: Apache-2.0 */
package global.thalion.ttio;

import global.thalion.ttio.providers.Hdf5Provider;
import global.thalion.ttio.providers.StorageGroup;
import global.thalion.ttio.providers.hdf5.Hdf5File;
import global.thalion.ttio.providers.hdf5.Hdf5Group;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

class MSImageMzAxisTest {

    @Test
    void mzAxisRoundTrip(@TempDir Path tmp) {
        int w = 4, h = 3, sp = 8;
        double[] cube = new double[w * h * sp];
        for (int i = 0; i < cube.length; i++) cube[i] = i * 0.1;
        double[] mz = new double[sp];
        for (int i = 0; i < sp; i++) mz[i] = 100.0 + i * 100.0;

        MSImage img = new MSImage(w, h, sp, 0, 10.0, 10.0, "raster",
                cube, mz, "", "", List.of(), List.of(), List.of());

        String path = tmp.resolve("mz_axis_test.tio").toString();
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.createGroup("study")) {
            img.writeTo(Hdf5Provider.adapterForGroup(study));
        }

        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study")) {
            MSImage read = MSImage.readFrom(Hdf5Provider.adapterForGroup(study));
            assertNotNull(read);
            assertArrayEquals(mz, read.mzAxis(), 0.0,
                "mz_axis byte-equal after round-trip");
        }
    }

    @Test
    void legacyFileReturnsEmptyMzAxis(@TempDir Path tmp) {
        // Write a file via the legacy 7-arg ctor (no mzAxis); confirm
        // read-back returns an empty axis without throwing.
        int w = 2, h = 2, sp = 3;
        double[] cube = new double[w * h * sp];
        MSImage legacy = new MSImage(w, h, sp, 5.0, 5.0, "raster", cube);

        String path = tmp.resolve("legacy.tio").toString();
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.createGroup("study")) {
            legacy.writeTo(Hdf5Provider.adapterForGroup(study));
        }

        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study")) {
            MSImage read = MSImage.readFrom(Hdf5Provider.adapterForGroup(study));
            assertNotNull(read);
            assertEquals(0, read.mzAxis().length,
                "legacy file with no mz_axis dataset returns empty");
        }
    }

    @Test
    void mzAxisLengthMismatchRejected() {
        int w = 2, h = 2, sp = 4;
        double[] cube = new double[w * h * sp];
        double[] badMz = new double[sp + 1];   // wrong length
        assertThrows(IllegalArgumentException.class, () ->
            new MSImage(w, h, sp, 0, 0.0, 0.0, "raster", cube, badMz,
                "", "", List.of(), List.of(), List.of()));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Command:
```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/java && mvn -B test -Dtest=MSImageMzAxisTest -Dhdf5.jar=/usr/share/java/jarhdf5.jar'
```

Expected: COMPILATION FAILURE — `MSImage` doesn't have a 15-arg constructor with `double[] mzAxis`, no `mzAxis()` accessor.

- [ ] **Step 3: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis && git add java/src/test/java/global/thalion/ttio/MSImageMzAxisTest.java && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "test(java): failing tests for MSImage.mzAxis round-trip + legacy fallback + ctor validation"'
```

---

## Task 0.2: Java — `MSImage.mzAxis` field + 15-arg ctor

**Files:**
- Modify: `java/src/main/java/global/thalion/ttio/MSImage.java`

- [ ] **Step 1: Add `mzAxis` field, new ctor, accessor**

Replace the existing class body (between the existing class declaration and the existing methods) with:

```java
public class MSImage {

    private final int width;
    private final int height;
    private final int spectralPoints;
    private final int tileSize;
    private final double pixelSizeX;
    private final double pixelSizeY;
    private final String scanPattern;
    private final double[] intensityCube;
    private final double[] mzAxis;     // NEW — length 0 (legacy) or == spectralPoints

    // Dataset-level composition fields
    private final String title;
    private final String isaInvestigationId;
    private final List<Identification> identifications;
    private final List<Quantification> quantifications;
    private final List<ProvenanceRecord> provenanceRecords;

    /** Designated constructor (1.2.0): includes mzAxis. */
    public MSImage(int width, int height, int spectralPoints, int tileSize,
                   double pixelSizeX, double pixelSizeY, String scanPattern,
                   double[] intensityCube, double[] mzAxis,
                   String title, String isaInvestigationId,
                   List<Identification> identifications,
                   List<Quantification> quantifications,
                   List<ProvenanceRecord> provenanceRecords) {
        this.width = width;
        this.height = height;
        this.spectralPoints = spectralPoints;
        this.tileSize = tileSize;
        this.pixelSizeX = pixelSizeX;
        this.pixelSizeY = pixelSizeY;
        this.scanPattern = scanPattern;
        this.intensityCube = intensityCube;
        if (mzAxis == null) mzAxis = new double[0];
        if (mzAxis.length > 0 && mzAxis.length != spectralPoints) {
            throw new IllegalArgumentException(
                "mzAxis length " + mzAxis.length
                + " does not match spectralPoints=" + spectralPoints);
        }
        this.mzAxis = mzAxis;
        this.title = title != null ? title : "";
        this.isaInvestigationId = isaInvestigationId != null ? isaInvestigationId : "";
        this.identifications = identifications != null ? List.copyOf(identifications) : List.of();
        this.quantifications = quantifications != null ? List.copyOf(quantifications) : List.of();
        this.provenanceRecords = provenanceRecords != null ? List.copyOf(provenanceRecords) : List.of();
    }

    /** Backwards-compat 14-arg ctor (1.1.x callers): defaults mzAxis to empty. */
    public MSImage(int width, int height, int spectralPoints, int tileSize,
                   double pixelSizeX, double pixelSizeY, String scanPattern,
                   double[] intensityCube,
                   String title, String isaInvestigationId,
                   List<Identification> identifications,
                   List<Quantification> quantifications,
                   List<ProvenanceRecord> provenanceRecords) {
        this(width, height, spectralPoints, tileSize,
             pixelSizeX, pixelSizeY, scanPattern, intensityCube, new double[0],
             title, isaInvestigationId,
             identifications, quantifications, provenanceRecords);
    }

    /** Convenience — image-only construction (empty dataset-level metadata). */
    public MSImage(int width, int height, int spectralPoints,
                   double pixelSizeX, double pixelSizeY, String scanPattern,
                   double[] intensityCube) {
        this(width, height, spectralPoints, 0,
             pixelSizeX, pixelSizeY, scanPattern, intensityCube, new double[0],
             "", "", List.of(), List.of(), List.of());
    }
```

- [ ] **Step 2: Add `mzAxis()` accessor** (insert below `intensityCube()`)

```java
    /** The shared m/z axis when present; empty array for legacy files. */
    public double[] mzAxis() { return mzAxis; }
```

- [ ] **Step 3: Run mismatch validation test**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/java && mvn -B test -Dtest=MSImageMzAxisTest#mzAxisLengthMismatchRejected -Dhdf5.jar=/usr/share/java/jarhdf5.jar'
```

Expected: PASS. The other tests still fail (no read/write of mz_axis yet).

- [ ] **Step 4: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis && git add java/src/main/java/global/thalion/ttio/MSImage.java && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "feat(java): MSImage.mzAxis field + 15-arg ctor + length validation"'
```

---

## Task 0.3: Java — `MSImage.writeTo` writes `mz_axis` dataset

**Files:**
- Modify: `java/src/main/java/global/thalion/ttio/MSImage.java`

- [ ] **Step 1: Extend `writeTo` to write `mz_axis` when non-empty**

Locate the existing `writeTo(StorageGroup studyGroup)` method. After the `try (StorageDataset ds = ic.createDatasetND("intensity", ...))` block, before the close of the outer `try`, add:

```java
            if (mzAxis.length > 0) {
                long[] axisShape  = { spectralPoints };
                long[] axisChunks = { spectralPoints };
                try (StorageDataset axisDs = ic.createDatasetND("mz_axis",
                        Precision.FLOAT64, axisShape, axisChunks,
                        Compression.ZLIB, 6)) {
                    axisDs.writeAll(mzAxis);
                }
            }
```

- [ ] **Step 2: Run round-trip test (still expected to fail at read side)**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/java && mvn -B test -Dtest=MSImageMzAxisTest#mzAxisRoundTrip -Dhdf5.jar=/usr/share/java/jarhdf5.jar'
```

Expected: FAIL — readFrom doesn't read mz_axis yet, so the read MSImage has empty mz_axis.

- [ ] **Step 3: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -am "feat(java): MSImage.writeTo persists mz_axis dataset when non-empty"'
```

---

## Task 0.4: Java — `MSImage.readFrom` reads `mz_axis` dataset

**Files:**
- Modify: `java/src/main/java/global/thalion/ttio/MSImage.java`

- [ ] **Step 1: Extend `readFrom` to read mz_axis if present**

Replace the existing `readFrom(StorageGroup)` method body. The current implementation reads `intensity` and constructs via the 7-arg ctor — change it to also read `mz_axis` and use the 15-arg ctor:

```java
    public static MSImage readFrom(StorageGroup studyGroup) {
        if (!studyGroup.hasChild("image_cube")) return null;
        try (StorageGroup ic = studyGroup.openGroup("image_cube")) {
            int width = ((Number) ic.getAttribute("width")).intValue();
            int height = ((Number) ic.getAttribute("height")).intValue();
            int spectralPoints = ((Number) ic.getAttribute("spectral_points")).intValue();
            double pixelSizeX = Double.parseDouble(
                    ic.hasAttribute("pixel_size_x")
                            ? (String) ic.getAttribute("pixel_size_x") : "0");
            double pixelSizeY = Double.parseDouble(
                    ic.hasAttribute("pixel_size_y")
                            ? (String) ic.getAttribute("pixel_size_y") : "0");
            String scanPattern = ic.hasAttribute("scan_pattern")
                    ? (String) ic.getAttribute("scan_pattern") : null;

            double[] cube;
            try (StorageDataset ds = ic.openDataset("intensity")) {
                cube = (double[]) ds.readAll();
            }

            double[] mzAxis = new double[0];
            if (ic.hasChild("mz_axis")) {
                try (StorageDataset axisDs = ic.openDataset("mz_axis")) {
                    mzAxis = (double[]) axisDs.readAll();
                }
            }

            return new MSImage(width, height, spectralPoints, 0,
                    pixelSizeX, pixelSizeY, scanPattern, cube, mzAxis,
                    "", "", List.of(), List.of(), List.of());
        }
    }
```

- [ ] **Step 2: Run all three tests**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/java && mvn -B test -Dtest=MSImageMzAxisTest -Dhdf5.jar=/usr/share/java/jarhdf5.jar'
```

Expected: PASS — all three tests (`mzAxisRoundTrip`, `legacyFileReturnsEmptyMzAxis`, `mzAxisLengthMismatchRejected`).

- [ ] **Step 3: Run full Java suite (regression check)**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/java && mvn -B test -Dhdf5.jar=/usr/share/java/jarhdf5.jar 2>&1 | tail -10'
```

Expected: 809 PASS / 0 FAIL / 4 SKIPPED (matches baseline).

- [ ] **Step 4: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -am "feat(java): MSImage.readFrom reads mz_axis dataset; constructs via 15-arg ctor"'
```

---

## Task 0.5: Java — `MSImage.toPixelSpectra()` for imzML bridge

**Files:**
- Modify: `java/src/main/java/global/thalion/ttio/MSImage.java`
- Modify: `java/src/test/java/global/thalion/ttio/MSImageMzAxisTest.java`

- [ ] **Step 1: Add failing test for `toPixelSpectra()` happy path + empty-axis raise**

Append to `MSImageMzAxisTest.java`:

```java
    @Test
    void toPixelSpectraReturnsContinuousModeList() {
        int w = 2, h = 2, sp = 3;
        double[] cube = new double[w * h * sp];
        for (int i = 0; i < cube.length; i++) cube[i] = i * 1.0;
        double[] mz = { 100.0, 200.0, 300.0 };
        MSImage img = new MSImage(w, h, sp, 0, 1.0, 1.0, "raster",
                cube, mz, "", "", List.of(), List.of(), List.of());

        var pixels = img.toPixelSpectra();
        assertEquals(w * h, pixels.size());
        // Pixel (row=0, col=0): cube indices [0..2]
        var p0 = pixels.get(0);
        assertEquals(0, p0.x());
        assertEquals(0, p0.y());
        assertArrayEquals(mz, p0.mz(), 0.0);
        assertArrayEquals(new double[] {0.0, 1.0, 2.0}, p0.intensity(), 0.0);
        // Pixel (row=1, col=1): cube indices [9..11]
        var p3 = pixels.get(3);
        assertEquals(1, p3.x());
        assertEquals(1, p3.y());
        assertArrayEquals(mz, p3.mz(), 0.0);
        assertArrayEquals(new double[] {9.0, 10.0, 11.0}, p3.intensity(), 0.0);
    }

    @Test
    void toPixelSpectraRaisesWithEmptyAxis() {
        int w = 2, h = 2, sp = 3;
        double[] cube = new double[w * h * sp];
        MSImage img = new MSImage(w, h, sp, 0, 1.0, 1.0, "raster",
                cube, new double[0], "", "", List.of(), List.of(), List.of());
        IllegalStateException e = assertThrows(IllegalStateException.class,
                img::toPixelSpectra);
        assertTrue(e.getMessage().contains("mz_axis"),
                "error must mention mz_axis: " + e.getMessage());
    }
```

- [ ] **Step 2: Verify tests fail to compile**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/java && mvn -B test -Dtest=MSImageMzAxisTest -Dhdf5.jar=/usr/share/java/jarhdf5.jar 2>&1 | tail -5'
```

Expected: COMPILATION FAILURE — `toPixelSpectra` doesn't exist on MSImage.

- [ ] **Step 3: Implement `toPixelSpectra()`**

Add to `MSImage.java` (after the `spectrumAt` method):

```java
    /** Project this image as a list of {@link
     *  global.thalion.ttio.importers.ImzMLReader.PixelSpectrum} records
     *  in continuous mode (every pixel shares {@link #mzAxis}).
     *
     *  @throws IllegalStateException if {@code mzAxis} is empty.
     */
    public java.util.List<global.thalion.ttio.importers.ImzMLReader.PixelSpectrum>
            toPixelSpectra() {
        if (mzAxis.length == 0) {
            throw new IllegalStateException(
                "MSImage has no mz_axis; cannot project to imzML pixels. "
                + "The .tio was written before format v1.2 added the spectral "
                + "axis. Re-import from a source format that carries m/z "
                + "calibration (imzML, mzML), or supply mz_axis explicitly.");
        }
        java.util.List<global.thalion.ttio.importers.ImzMLReader.PixelSpectrum>
            pixels = new java.util.ArrayList<>(width * height);
        for (int row = 0; row < height; row++) {
            for (int col = 0; col < width; col++) {
                double[] intensity = spectrumAt(row, col);
                // x = col (image-plane), y = row, z = 1 (single plane).
                pixels.add(new global.thalion.ttio.importers.ImzMLReader
                    .PixelSpectrum(col, row, 1, mzAxis, intensity));
            }
        }
        return pixels;
    }
```

- [ ] **Step 4: Run tests**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/java && mvn -B test -Dtest=MSImageMzAxisTest -Dhdf5.jar=/usr/share/java/jarhdf5.jar'
```

Expected: 5 tests PASS.

- [ ] **Step 5: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -am "feat(java): MSImage.toPixelSpectra() continuous-mode projection for imzML export"'
```

---

## Task 0.6: Java — `SpectralDataset.image()` accessor

**Files:**
- Modify: `java/src/main/java/global/thalion/ttio/SpectralDataset.java`
- Modify: `java/src/test/java/global/thalion/ttio/SpectralDatasetTest.java`

- [ ] **Step 1: Add failing tests**

Append to `SpectralDatasetTest.java` (alongside the existing `msImageRoundTrip` test):

```java
    @Test
    void imageAccessorReturnsMaterialisedMSImage() throws java.io.IOException {
        java.nio.file.Path path = tempDir.resolve("ds_with_image.tio");
        int w = 2, h = 2, sp = 4;
        double[] cube = new double[w * h * sp];
        for (int i = 0; i < cube.length; i++) cube[i] = i * 0.5;
        double[] mz = { 100.0, 200.0, 300.0, 400.0 };
        MSImage img = new MSImage(w, h, sp, 0, 1.0, 1.0, "raster",
                cube, mz, "", "", List.of(), List.of(), List.of());

        try (Hdf5File f = Hdf5File.create(path.toString());
             Hdf5Group root = f.rootGroup()) {
            FeatureFlags.defaultCurrent()
                    .with(FeatureFlags.OPT_NATIVE_MSIMAGE_CUBE)
                    .writeTo(root);
            try (Hdf5Group study = root.createGroup("study")) {
                img.writeTo(global.thalion.ttio.providers.Hdf5Provider
                        .adapterForGroup(study));
            }
        }

        try (SpectralDataset ds = SpectralDataset.open(path.toString())) {
            MSImage materialised = ds.image();
            assertNotNull(materialised, "image() should return non-null when present");
            assertEquals(w, materialised.width());
            assertEquals(h, materialised.height());
            assertEquals(sp, materialised.spectralPoints());
            assertArrayEquals(mz, materialised.mzAxis(), 0.0);
        }
    }

    @Test
    void imageAccessorReturnsNullWhenAbsent() {
        // full_ms.tio has no image_cube
        String fixture = getFixturePath("full_ms.tio");
        try (SpectralDataset ds = SpectralDataset.open(fixture)) {
            assertNull(ds.image(), "image() returns null on non-imaging .tio");
        }
    }
```

- [ ] **Step 2: Verify tests fail**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/java && mvn -B test -Dtest=SpectralDatasetTest#imageAccessorReturnsMaterialisedMSImage -Dhdf5.jar=/usr/share/java/jarhdf5.jar 2>&1 | tail -5'
```

Expected: COMPILATION FAILURE — `image()` doesn't exist on `SpectralDataset`.

- [ ] **Step 3: Add `image` field, populate in `open()`, expose accessor**

In `SpectralDataset.java`:

(a) Add the field next to `references` (around line 58):

```java
    private final MSImage image;  // null when /study/image_cube absent
```

(b) Add the field to the existing private constructor (the 12-arg one starting at line 70). New parameter list:

```java
    private SpectralDataset(StorageProvider provider, Hdf5File file,
                            FeatureFlags featureFlags,
                            String title, String isaInvestigationId,
                            Map<String, AcquisitionRun> msRuns,
                            Map<String, GenomicRun> genomicRuns,
                            Map<String, global.thalion.ttio.genomics.ReferenceImport> references,
                            MSImage image,
                            List<Identification> identifications,
                            List<Quantification> quantifications,
                            List<ProvenanceRecord> provenanceRecords,
                            String encryptedAlgorithm) {
```

In its body, add `this.image = image;` next to `this.references = ...`.

The forwarding constructors above (the 11-arg, 9-arg, and 8-arg variants) all need their `this(...)` calls updated to pass `null` in the `image` slot. For example, the 11-arg variant becomes:

```java
        this(provider, file, featureFlags, title, isaId, msRuns,
                genomicRuns, Map.of(), null, idents, quants, prov, encryptedAlg);
```

(c) Modify the `open()` method (around line 294). The `image` variable must be declared **outside** the inner `if (root.hasChild("study"))` block so its assignment scope reaches the `return` statement.

Before the `if (root.hasChild("study"))` block, alongside the existing `MSRuns runs = new LinkedHashMap<>();` declarations (around line 308), add:

```java
            MSImage image = null;
```

Inside the `try (Hdf5Group study = root.openGroup("study"))` block, after the `references` read block (around line 374) and before `idents = readIdentifications(study);`, add:

```java
                    // /study/image_cube — eagerly materialise into a value object (1.2.0).
                    if (study.hasChild("image_cube")) {
                        image = MSImage.readFrom(
                            global.thalion.ttio.providers.Hdf5Provider
                                .adapterForGroup(study));
                    }
```

Then update the `return new SpectralDataset(...)` call inside `open()` to pass `image` in the new slot:

```java
            return new SpectralDataset(provider, file, flags, title, isaId, runs,
                    genomicRuns, references, image, idents, quants, prov, encryptedAlg);
```

(e) Add the accessor method (next to `references()`, around line 175):

```java
    /** The embedded MSImage when /study/image_cube is present; null otherwise.
     *  @since 1.2.0 */
    public MSImage image() { return image; }
```

- [ ] **Step 4: Run accessor tests**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/java && mvn -B test -Dtest=SpectralDatasetTest#imageAccessorReturnsMaterialisedMSImage,SpectralDatasetTest#imageAccessorReturnsNullWhenAbsent -Dhdf5.jar=/usr/share/java/jarhdf5.jar'
```

Expected: 2 PASS.

- [ ] **Step 5: Run full Java suite (regression check)**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/java && mvn -B test -Dhdf5.jar=/usr/share/java/jarhdf5.jar 2>&1 | tail -8'
```

Expected: 809+ PASS / 0 FAIL.

- [ ] **Step 6: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -am "feat(java): SpectralDataset.image() accessor — eagerly materialises /study/image_cube on open()"'
```

---

## Phase 0 acceptance gate

- [ ] All 5 `MSImageMzAxisTest` tests pass.
- [ ] Both new `SpectralDatasetTest` accessor tests pass.
- [ ] Full Java suite green (no regressions vs baseline).
- [ ] `git log --oneline | head -6` shows the 6 task commits in order.

Phase 0 is complete when this gate passes. Do not proceed to Phase 1 until all boxes ticked.

---

# Phase 1 — Python parity

**Goal:** Python `MSImage` carries `mz_axis`; standalone `write_to`/`read_from` methods mirror Java's API; `SpectralDataset.write_minimal(image=...)` kwarg integrates the high-level path; `SpectralDataset.image` property reads back lazily on open. Phase 1 is self-contained — Phase 2 doesn't depend on it.

**Files:**
- Modify: `python/src/ttio/ms_image.py`
- Modify: `python/src/ttio/spectral_dataset.py`
- Create: `python/tests/test_ms_image_mz_axis.py`

---

## Task 1.1: Python — failing test for `MSImage.mz_axis` round-trip

**Files:**
- Create: `python/tests/test_ms_image_mz_axis.py`

- [ ] **Step 1: Write the failing test**

Create `python/tests/test_ms_image_mz_axis.py`:

```python
"""Cross-language parity test: MSImage.mz_axis round-trip via standalone API."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ttio import MSImage
from ttio.providers import open_provider


def _build_image(w: int, h: int, sp: int) -> MSImage:
    cube = np.arange(h * w * sp, dtype=np.float64).reshape(h, w, sp) * 0.1
    mz = np.linspace(100.0, 100.0 + (sp - 1) * 100.0, sp)
    return MSImage(
        width=w, height=h, spectral_points=sp,
        intensity=cube,
        mz_axis=mz,
        pixel_size_x=10.0, pixel_size_y=10.0, scan_pattern="raster",
    )


def test_mz_axis_round_trip(tmp_path: Path) -> None:
    img = _build_image(4, 3, 8)
    out = tmp_path / "mz_axis.tio"
    with open_provider(str(out), provider="hdf5", mode="w") as sp:
        root = sp.root_group()
        study = root.create_group("study")
        img.write_to(study)
    with open_provider(str(out), provider="hdf5", mode="r") as sp:
        root = sp.root_group()
        study = root.open_group("study")
        read = MSImage.read_from(study)
    assert read is not None
    np.testing.assert_array_equal(read.mz_axis, img.mz_axis)
    np.testing.assert_array_equal(read.intensity, img.intensity)


def test_legacy_file_returns_empty_mz_axis(tmp_path: Path) -> None:
    """A file written without mz_axis reads back with an empty axis."""
    img = MSImage(
        width=2, height=2, spectral_points=3,
        intensity=np.zeros((2, 2, 3), dtype=np.float64),
        # mz_axis defaults to empty
        pixel_size_x=1.0, pixel_size_y=1.0, scan_pattern="raster",
    )
    out = tmp_path / "legacy.tio"
    with open_provider(str(out), provider="hdf5", mode="w") as sp:
        root = sp.root_group()
        study = root.create_group("study")
        img.write_to(study)
    with open_provider(str(out), provider="hdf5", mode="r") as sp:
        root = sp.root_group()
        study = root.open_group("study")
        read = MSImage.read_from(study)
    assert read is not None
    assert read.mz_axis.size == 0


def test_mz_axis_length_mismatch_rejected() -> None:
    cube = np.zeros((2, 2, 3), dtype=np.float64)
    bad_mz = np.linspace(0.0, 1.0, 4)  # wrong length (4 vs 3)
    with pytest.raises(ValueError, match="mz_axis"):
        MSImage(
            width=2, height=2, spectral_points=3,
            intensity=cube, mz_axis=bad_mz,
        )


def test_to_pixel_spectra_continuous_mode() -> None:
    img = _build_image(2, 2, 3)
    pixels = img.to_pixel_spectra()
    assert len(pixels) == 4
    # Pixel (row=0, col=0)
    p0 = pixels[0]
    assert p0.x == 0 and p0.y == 0
    np.testing.assert_array_equal(p0.mz, img.mz_axis)
    np.testing.assert_array_equal(p0.intensity, img.intensity[0, 0])
    # Pixel (row=1, col=1)
    p3 = pixels[3]
    assert p3.x == 1 and p3.y == 1
    np.testing.assert_array_equal(p3.mz, img.mz_axis)
    np.testing.assert_array_equal(p3.intensity, img.intensity[1, 1])


def test_to_pixel_spectra_raises_with_empty_axis() -> None:
    img = MSImage(
        width=2, height=2, spectral_points=3,
        intensity=np.zeros((2, 2, 3), dtype=np.float64),
    )
    with pytest.raises(RuntimeError, match="mz_axis"):
        img.to_pixel_spectra()
```

- [ ] **Step 2: Run tests to verify they fail**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/python && pytest tests/test_ms_image_mz_axis.py -v 2>&1 | tail -15'
```

Expected: FAILS — `MSImage` has no `mz_axis` field, no `write_to` / `read_from` / `to_pixel_spectra` methods.

- [ ] **Step 3: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis && git add python/tests/test_ms_image_mz_axis.py && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "test(python): failing tests for MSImage.mz_axis + write_to/read_from + to_pixel_spectra"'
```

---

## Task 1.2: Python — `MSImage.mz_axis` field with validation

**Files:**
- Modify: `python/src/ttio/ms_image.py`

- [ ] **Step 1: Add `mz_axis` field + validation**

Modify `python/src/ttio/ms_image.py` to add the field and validation (in dataclass body and `__post_init__`):

```python
    width: int = 0
    height: int = 0
    spectral_points: int = 0
    pixel_size_x: float = 0.0
    pixel_size_y: float = 0.0
    intensity: np.ndarray = field(default_factory=lambda: np.zeros((0, 0, 0)))
    mz_axis: np.ndarray = field(default_factory=lambda: np.zeros(0))   # NEW
    scan_pattern: str = ""
    tile_size: int = 0

    # Dataset-level composition fields (ObjC inherits from TTIOSpectralDataset)
    title: str = ""
    isa_investigation_id: str = ""
    identifications: list = field(default_factory=list)
    quantifications: list = field(default_factory=list)
    provenance_records: list = field(default_factory=list)

    def __post_init__(self) -> None:
        if self.width == 0 and self.height == 0 and self.spectral_points == 0:
            return  # empty default OK
        if self.intensity.ndim != 3:
            raise ValueError(
                f"intensity must be rank-3, got shape={self.intensity.shape}"
            )
        h, w, sp = self.intensity.shape
        if (h, w, sp) != (self.height, self.width, self.spectral_points):
            raise ValueError(
                f"intensity shape {(h, w, sp)} does not match "
                f"(height, width, spectral_points)="
                f"{(self.height, self.width, self.spectral_points)}"
            )
        if self.mz_axis.size > 0:
            if self.mz_axis.ndim != 1 or self.mz_axis.shape[0] != self.spectral_points:
                raise ValueError(
                    f"mz_axis shape {self.mz_axis.shape} does not match "
                    f"spectral_points={self.spectral_points}"
                )
```

- [ ] **Step 2: Run mismatch test**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/python && pytest tests/test_ms_image_mz_axis.py::test_mz_axis_length_mismatch_rejected -v'
```

Expected: PASS.

- [ ] **Step 3: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -am "feat(python): MSImage.mz_axis dataclass field + ndim/length validation"'
```

---

## Task 1.3: Python — `MSImage.write_to` + `read_from` + `to_pixel_spectra`

**Files:**
- Modify: `python/src/ttio/ms_image.py`

- [ ] **Step 1: Add the three new methods**

Append to `MSImage` class body (before the `__all__` list at module bottom):

```python
    def write_to(self, study_group) -> None:
        """Write this image cube under ``<study_group>/image_cube/``.

        Mirrors :meth:`global.thalion.ttio.MSImage.writeTo` — intensity
        as a 3-D ``[h, w, sp]`` dataset, optional ``mz_axis`` 1-D
        dataset when populated.
        """
        from ttio.enums import Compression, Precision
        ic = study_group.create_group("image_cube")
        ic.set_attribute("width", int(self.width))
        ic.set_attribute("height", int(self.height))
        ic.set_attribute("spectral_points", int(self.spectral_points))
        ic.set_attribute("pixel_size_x", str(self.pixel_size_x))
        ic.set_attribute("pixel_size_y", str(self.pixel_size_y))
        if self.scan_pattern:
            ic.set_attribute("scan_pattern", self.scan_pattern)

        intensity_ds = ic.create_dataset_nd(
            "intensity", Precision.FLOAT64,
            shape=(self.height, self.width, self.spectral_points),
            chunks=(1, 1, self.spectral_points),
            compression=Compression.ZLIB, compression_level=6,
        )
        intensity_ds.write(np.ascontiguousarray(self.intensity, dtype=np.float64))

        if self.mz_axis.size > 0:
            axis_ds = ic.create_dataset_nd(
                "mz_axis", Precision.FLOAT64,
                shape=(self.spectral_points,),
                chunks=(self.spectral_points,),
                compression=Compression.ZLIB, compression_level=6,
            )
            axis_ds.write(np.ascontiguousarray(self.mz_axis, dtype=np.float64))

    @classmethod
    def read_from(cls, study_group) -> "MSImage | None":
        """Read an MSImage cube from a study group; return None if absent."""
        if not study_group.has_child("image_cube"):
            return None
        ic = study_group.open_group("image_cube")
        width = int(ic.get_attribute("width"))
        height = int(ic.get_attribute("height"))
        spectral_points = int(ic.get_attribute("spectral_points"))
        pixel_size_x = (float(ic.get_attribute("pixel_size_x"))
                         if ic.has_attribute("pixel_size_x") else 0.0)
        pixel_size_y = (float(ic.get_attribute("pixel_size_y"))
                         if ic.has_attribute("pixel_size_y") else 0.0)
        scan_pattern = (ic.get_attribute("scan_pattern")
                         if ic.has_attribute("scan_pattern") else "")

        intensity_raw = np.asarray(ic.open_dataset("intensity").read())
        intensity = intensity_raw.reshape(height, width, spectral_points)

        if ic.has_child("mz_axis"):
            mz_axis = np.asarray(ic.open_dataset("mz_axis").read(), dtype=np.float64)
        else:
            mz_axis = np.zeros(0)

        return cls(
            width=width, height=height, spectral_points=spectral_points,
            pixel_size_x=pixel_size_x, pixel_size_y=pixel_size_y,
            intensity=intensity, mz_axis=mz_axis, scan_pattern=scan_pattern,
        )

    def to_pixel_spectra(self):
        """Project this image as a list of continuous-mode pixel records.

        Returns a list of :class:`ttio.importers.imzml.ImzMLPixelSpectrum`
        objects, one per pixel, all sharing :attr:`mz_axis` as their
        ``mz`` array.

        Raises ``RuntimeError`` when ``mz_axis`` is empty (legacy file).
        """
        if self.mz_axis.size == 0:
            raise RuntimeError(
                "MSImage has no mz_axis; cannot project to imzML pixels. "
                "The .tio was written before format v1.2 added the spectral "
                "axis. Re-import from a source format that carries m/z "
                "calibration (imzML, mzML), or supply mz_axis explicitly."
            )
        from ttio.importers.imzml import ImzMLPixelSpectrum
        pixels = []
        for row in range(self.height):
            for col in range(self.width):
                pixels.append(ImzMLPixelSpectrum(
                    x=col, y=row, z=1,
                    mz=self.mz_axis,
                    intensity=self.intensity[row, col],
                ))
        return pixels
```

- [ ] **Step 2: Run all Phase 1 tests**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/python && pytest tests/test_ms_image_mz_axis.py -v'
```

Expected: 5 PASS.

- [ ] **Step 3: Run full Python suite (regression check)**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/python && pytest 2>&1 | tail -10'
```

Expected: full suite green.

- [ ] **Step 4: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -am "feat(python): MSImage.write_to / read_from / to_pixel_spectra (mirrors Java API)"'
```

---

## Task 1.4: Python — `SpectralDataset.image` lazy property + `write_minimal(image=...)` kwarg

**Files:**
- Modify: `python/src/ttio/spectral_dataset.py`
- Modify: `python/tests/test_ms_image_mz_axis.py`

- [ ] **Step 1: Add failing test for the property and kwarg**

Append to `python/tests/test_ms_image_mz_axis.py`:

```python
def test_spectral_dataset_image_property(tmp_path: Path) -> None:
    """SpectralDataset.write_minimal(image=...) persists the cube;
    SpectralDataset.image property reads it back."""
    from ttio import SpectralDataset

    img = _build_image(2, 2, 4)
    out = tmp_path / "ds_with_image.tio"
    SpectralDataset.write_minimal(
        out, title="img-test", isa_investigation_id="",
        runs={}, image=img,
    )

    with SpectralDataset.open(out) as ds:
        materialised = ds.image
        assert materialised is not None
        assert materialised.width == 2
        np.testing.assert_array_equal(materialised.mz_axis, img.mz_axis)


def test_spectral_dataset_image_property_returns_none_when_absent(tmp_path: Path) -> None:
    from ttio import SpectralDataset
    out = tmp_path / "no_image.tio"
    SpectralDataset.write_minimal(out, title="", isa_investigation_id="", runs={})
    with SpectralDataset.open(out) as ds:
        assert ds.image is None
```

- [ ] **Step 2: Verify failures**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/python && pytest tests/test_ms_image_mz_axis.py::test_spectral_dataset_image_property -v 2>&1 | tail -5'
```

Expected: FAIL — `write_minimal` doesn't accept `image=`, `SpectralDataset.image` property doesn't exist.

- [ ] **Step 3: Add `image` kwarg to `SpectralDataset.write_minimal`**

Modify `python/src/ttio/spectral_dataset.py`. Locate the `write_minimal` signature (around line 730) and add the parameter:

```python
    @classmethod
    def write_minimal(
        cls,
        path: str | Path,
        *,
        title: str,
        isa_investigation_id: str,
        runs: Mapping[str, "WrittenRun"],
        genomic_runs: Mapping[str, WrittenGenomicRun] | None = None,
        identifications: list[Identification] | None = None,
        quantifications: list[Quantification] | None = None,
        provenance: list[ProvenanceRecord] | None = None,
        features: list[str] | None = None,
        provider: str | StorageProvider = "hdf5",
        image: "MSImage | None" = None,           # NEW (1.2.0)
    ) -> Path:
```

Then locate the HDF5 fast-path block (around line 805 — the `with h5py.File(p, "w") as f:` section). After the existing `study = f.create_group("study")` and the writes for runs/refs/idents/quants/prov, before the `with` block exits, add:

```python
                if image is not None:
                    # Wrap the raw h5py.Group in the package-private adapter
                    # so MSImage.write_to (which expects a StorageGroup) works
                    # uniformly across both the fast-path and protocol-path branches.
                    from ttio.providers.hdf5 import _Group as _Hdf5Group
                    image.write_to(_Hdf5Group(study))
```

For the protocol-mode path (non-HDF5 providers, locate the block following `if isinstance(provider, str) and provider in ("hdf5", "h5", "h5py"):` — typically around line 940+; the `else` branch where `open_provider(...)` is used). After that branch's `study` group creation:

```python
        if image is not None:
            image.write_to(study)   # study is already a StorageGroup here
```

Add `from ttio.ms_image import MSImage` to the top-of-file imports of `spectral_dataset.py` (place near the other ttio-internal imports).

- [ ] **Step 4: Add the lazy `image` property**

Locate the `SpectralDataset` class body. After the `references` accessor (search for `def references`), add:

```python
    @property
    def image(self) -> "MSImage | None":
        """The embedded MSImage if /study/image_cube is present.

        Lazy: reads the cube on first access, caches the result.
        Returns ``None`` when no image group exists.

        :since: 1.2.0
        """
        if not hasattr(self, "_image_cache_loaded"):
            self._image_cache_loaded = True
            self._image_cache: "MSImage | None" = None
            try:
                root = self._provider.root_group()
                if root.has_child("study"):
                    study = root.open_group("study")
                    self._image_cache = MSImage.read_from(study)
            except Exception:
                self._image_cache = None
        return self._image_cache
```

Top-of-file: ensure `from ttio.ms_image import MSImage` is imported (move from inside the method if added separately).

- [ ] **Step 5: Run accessor tests**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/python && pytest tests/test_ms_image_mz_axis.py -v'
```

Expected: 7 PASS (5 from earlier + 2 new accessor tests).

- [ ] **Step 6: Run full Python suite (regression check)**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/python && pytest 2>&1 | tail -10'
```

Expected: full suite green.

- [ ] **Step 7: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -am "feat(python): SpectralDataset.image property + write_minimal(image=) kwarg"'
```

---

## Phase 1 acceptance gate

- [ ] All 7 `test_ms_image_mz_axis.py` tests pass.
- [ ] Full Python suite green (no regressions vs baseline).
- [ ] `git log --oneline | head -4` shows the 4 task commits in order (1.1 + 1.2 + 1.3 + 1.4).

---

# Phase 2 — ObjC parity

**Goal:** ObjC `TTIOMSImage` carries `mzAxis`; `TTIOPixelSpectrum` value class added; `TTIOSpectralDataset.msImage` accessor exposes the materialised image. Subclass relationship preserved.

**Files:**
- Modify: `objc/Source/Image/TTIOMSImage.h`
- Modify: `objc/Source/Image/TTIOMSImage.m`
- Create: `objc/Source/Image/TTIOPixelSpectrum.h`
- Create: `objc/Source/Image/TTIOPixelSpectrum.m`
- Modify: `objc/Source/Dataset/TTIOSpectralDataset.h`
- Modify: `objc/Source/Dataset/TTIOSpectralDataset.m`
- Modify: `objc/Source/GNUmakefile`
- Create: `objc/Tests/TestMSImageMzAxis.m`
- Modify: `objc/Tests/TTIOTestRunner.m`
- Modify: `objc/Tests/GNUmakefile`

---

## Task 2.1: ObjC — failing test for `TTIOMSImage.mzAxis`

**Files:**
- Create: `objc/Tests/TestMSImageMzAxis.m`
- Modify: `objc/Tests/TTIOTestRunner.m`
- Modify: `objc/Tests/GNUmakefile`

- [ ] **Step 1: Write the failing test**

Create `objc/Tests/TestMSImageMzAxis.m`:

```objc
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Image/TTIOMSImage.h"
#import "Image/TTIOPixelSpectrum.h"
#import "HDF5/TTIOHDF5Errors.h"
#import <unistd.h>

static NSString *axisPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_test_axis_%d_%@.tio",
            (int)getpid(), suffix];
}

void testMSImageMzAxis(void)
{
    const NSUInteger W = 4, H = 3, SP = 8;
    NSMutableData *cube = [NSMutableData dataWithLength:W * H * SP * sizeof(double)];
    double *p = cube.mutableBytes;
    for (NSUInteger i = 0; i < W * H * SP; i++) p[i] = i * 0.1;

    NSMutableData *mz = [NSMutableData dataWithLength:SP * sizeof(double)];
    double *m = mz.mutableBytes;
    for (NSUInteger i = 0; i < SP; i++) m[i] = 100.0 + i * 100.0;

    TTIOMSImage *img =
        [[TTIOMSImage alloc] initWithTitle:@""
                        isaInvestigationId:@""
                           identifications:@[]
                           quantifications:@[]
                         provenanceRecords:@[]
                                     width:W
                                    height:H
                            spectralPoints:SP
                                  tileSize:0
                                pixelSizeX:10.0
                                pixelSizeY:10.0
                               scanPattern:@"raster"
                                      cube:cube
                                    mzAxis:mz];
    PASS(img != nil, "TTIOMSImage with mzAxis constructible");
    PASS(img.mzAxis.length == SP * sizeof(double), "mzAxis length matches");

    NSString *path = axisPath(@"image");
    unlink([path fileSystemRepresentation]);
    NSError *err = nil;
    PASS([img writeToFilePath:path error:&err], "writes to HDF5");
    PASS(err == nil, "no error on write");

    TTIOMSImage *back = [TTIOMSImage readFromFilePath:path error:&err];
    PASS(back != nil, "reads back");
    PASS([back.mzAxis isEqualToData:mz], "mzAxis bytes round-trip exactly");
    PASS([back.cube isEqualToData:cube], "cube bytes round-trip exactly");

    NSArray<TTIOPixelSpectrum *> *pixels = [back pixelSpectra];
    PASS(pixels.count == W * H, "pixelSpectra returns one per pixel");
    TTIOPixelSpectrum *p0 = pixels[0];
    PASS(p0.x == 0 && p0.y == 0, "first pixel at (0, 0)");
    PASS([p0.mz isEqualToData:mz], "shared mz axis");

    unlink([path fileSystemRepresentation]);
}

void testMSImageLegacyMzAxisAbsent(void)
{
    // Use the 5-arg ctor (no mzAxis) — legacy round-trip.
    const NSUInteger W = 2, H = 2, SP = 3;
    NSMutableData *cube = [NSMutableData dataWithLength:W * H * SP * sizeof(double)];
    TTIOMSImage *img = [[TTIOMSImage alloc] initWithWidth:W
                                                    height:H
                                            spectralPoints:SP
                                                  tileSize:0
                                                      cube:cube];
    PASS(img.mzAxis == nil || img.mzAxis.length == 0,
         "legacy ctor leaves mzAxis nil/empty");

    NSString *path = axisPath(@"legacy");
    unlink([path fileSystemRepresentation]);
    NSError *err = nil;
    PASS([img writeToFilePath:path error:&err], "writes legacy file");

    TTIOMSImage *back = [TTIOMSImage readFromFilePath:path error:&err];
    PASS(back != nil, "reads back");
    PASS(back.mzAxis == nil || back.mzAxis.length == 0,
         "legacy file -> empty mzAxis");
    unlink([path fileSystemRepresentation]);
}
```

- [ ] **Step 2: Register in test runner**

Modify `objc/Tests/TTIOTestRunner.m` — add forward declarations and calls (search for `testMSImage` to find insertion site):

```objc
extern void testMSImageMzAxis(void);
extern void testMSImageLegacyMzAxisAbsent(void);
```

In the test-runner main function (or wherever existing test functions are called), add:

```objc
    testMSImageMzAxis();
    testMSImageLegacyMzAxisAbsent();
```

- [ ] **Step 3: Add to test makefile**

Modify `objc/Tests/GNUmakefile` — add `TestMSImageMzAxis.m` to the test-runner OBJC_FILES list (search for `TestMSImage.m` to find insertion site).

- [ ] **Step 4: Verify failure**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/objc && . /usr/share/GNUstep/Makefiles/GNUstep.sh && make 2>&1 | tail -10'
```

Expected: COMPILATION FAILURE — `TTIOPixelSpectrum.h` doesn't exist; new initialiser signature with `mzAxis:` doesn't match `TTIOMSImage`.

- [ ] **Step 5: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis && git add objc/Tests/TestMSImageMzAxis.m objc/Tests/TTIOTestRunner.m objc/Tests/GNUmakefile && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "test(objc): failing tests for TTIOMSImage.mzAxis + TTIOPixelSpectrum"'
```

---

## Task 2.2: ObjC — `TTIOPixelSpectrum` value class

**Files:**
- Create: `objc/Source/Image/TTIOPixelSpectrum.h`
- Create: `objc/Source/Image/TTIOPixelSpectrum.m`
- Modify: `objc/Source/GNUmakefile`

- [ ] **Step 1: Write the header**

Create `objc/Source/Image/TTIOPixelSpectrum.h`:

```objc
#ifndef TTIO_PIXEL_SPECTRUM_H
#define TTIO_PIXEL_SPECTRUM_H

#import <Foundation/Foundation.h>

/**
 * A single pixel from an MSImage projected as a (mz, intensity) record.
 *
 * <p>Output format of {@code -[TTIOMSImage pixelSpectra]}; consumed by
 * the imzML writer (continuous mode — every pixel shares the same
 * <code>mz</code> NSData buffer).</p>
 */
@interface TTIOPixelSpectrum : NSObject

@property (readonly) NSUInteger x;
@property (readonly) NSUInteger y;
@property (readonly) NSUInteger z;

/** Length-spectralPoints float64 m/z values. Shared across pixels in
 *  continuous mode. */
@property (readonly, copy) NSData *mz;

/** Length-spectralPoints float64 intensity values. */
@property (readonly, copy) NSData *intensity;

- (instancetype)initWithX:(NSUInteger)x
                        y:(NSUInteger)y
                        z:(NSUInteger)z
                       mz:(NSData *)mz
                intensity:(NSData *)intensity;

@end

#endif
```

- [ ] **Step 2: Write the implementation**

Create `objc/Source/Image/TTIOPixelSpectrum.m`:

```objc
/*
 * TTIOPixelSpectrum.m
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOPixelSpectrum.h"

@implementation TTIOPixelSpectrum

- (instancetype)initWithX:(NSUInteger)x
                        y:(NSUInteger)y
                        z:(NSUInteger)z
                       mz:(NSData *)mz
                intensity:(NSData *)intensity
{
    self = [super init];
    if (self) {
        _x = x;
        _y = y;
        _z = z;
        _mz = [mz copy];
        _intensity = [intensity copy];
    }
    return self;
}

@end
```

- [ ] **Step 3: Register in source makefile**

Modify `objc/Source/GNUmakefile` — add `Image/TTIOPixelSpectrum.m` to the OBJC_FILES list (search for `Image/TTIOMSImage.m`).

- [ ] **Step 4: Confirm compilation**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/objc && . /usr/share/GNUstep/Makefiles/GNUstep.sh && make Source 2>&1 | tail -5'
```

Expected: compiles (the test still fails because TTIOMSImage doesn't have the new initialiser yet).

- [ ] **Step 5: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis && git add objc/Source/Image/TTIOPixelSpectrum.h objc/Source/Image/TTIOPixelSpectrum.m objc/Source/GNUmakefile && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "feat(objc): TTIOPixelSpectrum value class for MSImage->imzML projection"'
```

---

## Task 2.3: ObjC — `TTIOMSImage.mzAxis` property + persistence

**Files:**
- Modify: `objc/Source/Image/TTIOMSImage.h`
- Modify: `objc/Source/Image/TTIOMSImage.m`

- [ ] **Step 1: Add `mzAxis` property + new initialiser declaration**

Modify `objc/Source/Image/TTIOMSImage.h`. After the `scanPattern` property:

```objc
/** Length-spectralPoints float64 array; nil for legacy files. */
@property (readonly, copy, nullable) NSData *mzAxis;
```

After the existing 13-arg initialiser, add the new 14-arg variant:

```objc
/**
 * Designated initialiser including mzAxis (1.2.0+).
 */
- (instancetype)initWithTitle:(NSString *)title
           isaInvestigationId:(NSString *)isaId
              identifications:(NSArray *)identifications
              quantifications:(NSArray *)quantifications
            provenanceRecords:(NSArray *)provenance
                        width:(NSUInteger)width
                       height:(NSUInteger)height
               spectralPoints:(NSUInteger)spectralPoints
                     tileSize:(NSUInteger)tileSize
                   pixelSizeX:(double)pixelSizeX
                   pixelSizeY:(double)pixelSizeY
                  scanPattern:(NSString *)scanPattern
                         cube:(NSData *)cube
                       mzAxis:(nullable NSData *)mzAxis;
```

Also declare the projection method:

```objc
/** Project this image as a continuous-mode pixel list. Raises
 *  NSInternalInconsistencyException when mzAxis is nil/empty. */
- (NSArray<TTIOPixelSpectrum *> *)pixelSpectra;
```

Add `@class TTIOPixelSpectrum;` near the top of the header file.

- [ ] **Step 2: Implement new initialiser, persistence, and `pixelSpectra`**

Modify `objc/Source/Image/TTIOMSImage.m`. Replace the existing 13-arg `initWithTitle:...` initialiser body to delegate to the new 14-arg form, and add the new initialiser:

```objc
- (instancetype)initWithTitle:(NSString *)title
           isaInvestigationId:(NSString *)isaId
              identifications:(NSArray *)identifications
              quantifications:(NSArray *)quantifications
            provenanceRecords:(NSArray *)provenance
                        width:(NSUInteger)width
                       height:(NSUInteger)height
               spectralPoints:(NSUInteger)spectralPoints
                     tileSize:(NSUInteger)tileSize
                   pixelSizeX:(double)pixelSizeX
                   pixelSizeY:(double)pixelSizeY
                  scanPattern:(NSString *)scanPattern
                         cube:(NSData *)cube
{
    return [self initWithTitle:title
            isaInvestigationId:isaId
               identifications:identifications
               quantifications:quantifications
             provenanceRecords:provenance
                         width:width
                        height:height
                spectralPoints:spectralPoints
                      tileSize:tileSize
                    pixelSizeX:pixelSizeX
                    pixelSizeY:pixelSizeY
                   scanPattern:scanPattern
                          cube:cube
                        mzAxis:nil];
}

- (instancetype)initWithTitle:(NSString *)title
           isaInvestigationId:(NSString *)isaId
              identifications:(NSArray *)identifications
              quantifications:(NSArray *)quantifications
            provenanceRecords:(NSArray *)provenance
                        width:(NSUInteger)width
                       height:(NSUInteger)height
               spectralPoints:(NSUInteger)spectralPoints
                     tileSize:(NSUInteger)tileSize
                   pixelSizeX:(double)pixelSizeX
                   pixelSizeY:(double)pixelSizeY
                  scanPattern:(NSString *)scanPattern
                         cube:(NSData *)cube
                       mzAxis:(NSData *)mzAxis
{
    NSParameterAssert(cube.length == width * height * spectralPoints * sizeof(double));
    if (mzAxis != nil && mzAxis.length != spectralPoints * sizeof(double)) {
        [NSException raise:NSInvalidArgumentException
                    format:@"mzAxis length %lu does not match spectralPoints=%lu",
                           (unsigned long)mzAxis.length,
                           (unsigned long)(spectralPoints * sizeof(double))];
    }
    self = [super initWithTitle:title
             isaInvestigationId:isaId
                         msRuns:@{}
                        nmrRuns:@{}
                identifications:identifications
                quantifications:quantifications
              provenanceRecords:provenance
                    transitions:nil];
    if (self) {
        _width          = width;
        _height         = height;
        _spectralPoints = spectralPoints;
        _tileSize       = tileSize > 0 ? tileSize : 32;
        _pixelSizeX     = pixelSizeX;
        _pixelSizeY     = pixelSizeY;
        _scanPattern    = [scanPattern copy];
        _cube           = [cube copy];
        _mzAxis         = [mzAxis copy];
    }
    return self;
}
```

Update `writeImageCubeUnderGroup` to also write `mz_axis` when non-nil. After the existing scan_pattern attribute write, insert:

```objc
    // mz_axis 1-D dataset (1.2.0+)
    extern NSData *currentMzAxis;  // captured below; see caller
```

Actually, since `writeImageCubeUnderGroup` is a static C function, the simplest threading is to add an NSData parameter. Replace the function signature:

```objc
static BOOL writeImageCubeUnderGroup(hid_t parentGid,
                                      NSUInteger width,
                                      NSUInteger height,
                                      NSUInteger sp,
                                      NSUInteger tileSize,
                                      double pxX, double pxY,
                                      NSString *scanPattern,
                                      const void *cubeBytes,
                                      NSData *mzAxis,           // NEW
                                      NSError **error)
```

Inside, after the scan_pattern attribute write, before the macro `#undef` lines, add the mz_axis dataset write:

```objc
    if (mzAxis != nil && mzAxis.length == sp * sizeof(double)) {
        hsize_t axisDims[1] = { (hsize_t)sp };
        hid_t axisSpace = H5Screate_simple(1, axisDims, NULL);
        hid_t axisPlist = H5Pcreate(H5P_DATASET_CREATE);
        H5Pset_chunk(axisPlist, 1, axisDims);
        H5Pset_deflate(axisPlist, 6);
        hid_t axisDid = H5Dcreate2(imageGroup, "mz_axis",
                                    H5T_NATIVE_DOUBLE, axisSpace,
                                    H5P_DEFAULT, axisPlist, H5P_DEFAULT);
        if (axisDid >= 0) {
            H5Dwrite(axisDid, H5T_NATIVE_DOUBLE,
                     H5S_ALL, H5S_ALL, H5P_DEFAULT, mzAxis.bytes);
            H5Dclose(axisDid);
        }
        H5Pclose(axisPlist);
        H5Sclose(axisSpace);
    }
```

Update the caller `-writeAdditionalStudyContent:` to pass `_mzAxis`:

```objc
- (BOOL)writeAdditionalStudyContent:(TTIOHDF5Group *)studyGroup
                              error:(NSError **)error
{
    if (_width == 0 || _height == 0 || _spectralPoints == 0) return YES;
    return writeImageCubeUnderGroup(studyGroup.groupId,
                                     _width, _height, _spectralPoints, _tileSize,
                                     _pixelSizeX, _pixelSizeY, _scanPattern,
                                     _cube.bytes, _mzAxis, error);
}
```

Update `readImageMetaFromGroup` to also try reading the `mz_axis` dataset. After the scan_pattern attribute read:

```objc
    out->mzAxis = nil;  // populated below if dataset present
```

Add to the `ttio_image_meta_t` struct:

```objc
typedef struct {
    NSUInteger width, height, sp, tileSize;
    double pixelSizeX, pixelSizeY;
    char *scanPattern;
    NSData *mzAxis;             // NEW — nil for legacy
} ttio_image_meta_t;
```

Add a new helper to read the mz_axis dataset:

```objc
static NSData *readMzAxisFromGroup(hid_t imageGroup, NSUInteger sp)
{
    if (H5Lexists(imageGroup, "mz_axis", H5P_DEFAULT) <= 0) return nil;
    hid_t did = H5Dopen2(imageGroup, "mz_axis", H5P_DEFAULT);
    if (did < 0) return nil;
    NSMutableData *axis = [NSMutableData dataWithLength:sp * sizeof(double)];
    herr_t s = H5Dread(did, H5T_NATIVE_DOUBLE,
                       H5S_ALL, H5S_ALL, H5P_DEFAULT, axis.mutableBytes);
    H5Dclose(did);
    return s < 0 ? nil : [axis copy];
}
```

In `-readAdditionalStudyContent:`, after the existing `cube` read:

```objc
    NSData *axis = readMzAxisFromGroup(imageGroup, meta.sp);
    H5Gclose(imageGroup);
    if (!cube) { ... return NO; }

    // ... existing field assignments ...
    _mzAxis        = axis;
```

In the legacy v0.1 path inside `+readFromFilePath:`, also call `readMzAxisFromGroup` and pass it through to the new initialiser:

```objc
            NSData *axis = readMzAxisFromGroup(legacyGroup, meta.sp);
            // ...
            TTIOMSImage *img = [[TTIOMSImage alloc]
                                 initWithTitle:@"" isaInvestigationId:@""
                                 identifications:@[] quantifications:@[]
                                 provenanceRecords:@[]
                                 width:meta.width height:meta.height
                                 spectralPoints:meta.sp tileSize:meta.tileSize
                                 pixelSizeX:meta.pixelSizeX pixelSizeY:meta.pixelSizeY
                                 scanPattern:meta.scanPattern ? @(meta.scanPattern) : @""
                                 cube:cube mzAxis:axis];
```

Add the `-pixelSpectra` method (next to `-isEqual`):

```objc
#pragma mark - imzML projection

- (NSArray<TTIOPixelSpectrum *> *)pixelSpectra
{
    if (_mzAxis == nil || _mzAxis.length == 0) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"TTIOMSImage has no mzAxis; cannot project to "
                           @"imzML pixels. The .tio was written before format "
                           @"v1.2 added the spectral axis."];
    }
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:_width * _height];
    const double *cubeP = (const double *)_cube.bytes;
    for (NSUInteger row = 0; row < _height; row++) {
        for (NSUInteger col = 0; col < _width; col++) {
            NSUInteger base = (row * _width + col) * _spectralPoints;
            NSData *intensity =
                [NSData dataWithBytes:cubeP + base
                               length:_spectralPoints * sizeof(double)];
            [out addObject:[[TTIOPixelSpectrum alloc]
                              initWithX:col y:row z:1
                                     mz:_mzAxis
                              intensity:intensity]];
        }
    }
    return [out copy];
}
```

Add `#import "TTIOPixelSpectrum.h"` at the top of `TTIOMSImage.m`.

- [ ] **Step 3: Build + run tests**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/objc && . /usr/share/GNUstep/Makefiles/GNUstep.sh && make 2>&1 | tail -10'
```

Expected: builds clean.

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/objc && . /usr/share/GNUstep/Makefiles/GNUstep.sh && cd Tests && make && ./obj/TTIOTestRunner 2>&1 | grep -E "MSImageMzAxis|MSImageLegacy" | tail -20'
```

Expected: PASS lines for both new test functions.

- [ ] **Step 4: Run full ObjC test suite (regression check)**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/objc && . /usr/share/GNUstep/Makefiles/GNUstep.sh && cd Tests && ./obj/TTIOTestRunner 2>&1 | grep -E "^(PASS|FAIL)" | wc -l'
```

Expected: 3123+ tests, all PASS.

- [ ] **Step 5: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -am "feat(objc): TTIOMSImage.mzAxis property + persistence + pixelSpectra projection"'
```

---

## Task 2.4: ObjC — `TTIOSpectralDataset.msImage` accessor (category)

**Files:**
- Modify: `objc/Source/Dataset/TTIOSpectralDataset.h`
- Modify: `objc/Source/Dataset/TTIOSpectralDataset.m`

- [ ] **Step 1: Declare the property**

Append to `objc/Source/Dataset/TTIOSpectralDataset.h` (before `@end` of the main `@interface` block):

```objc
@class TTIOMSImage;

@interface TTIOSpectralDataset (Image)
/** The embedded MSImage when /study/image_cube is present; nil otherwise.
 *  For an open TTIOMSImage instance, returns self (the subclass relationship
 *  makes this trivial).
 *  @since 1.2.0 */
@property (readonly, nullable) TTIOMSImage *msImage;
@end
```

- [ ] **Step 2: Implement the category**

Append to `objc/Source/Dataset/TTIOSpectralDataset.m`:

```objc
#import "../Image/TTIOMSImage.h"

@implementation TTIOSpectralDataset (Image)

- (TTIOMSImage *)msImage
{
    if ([self isKindOfClass:[TTIOMSImage class]]) {
        return (TTIOMSImage *)self;
    }
    NSString *path = [self filePath];
    if (path == nil) return nil;
    NSError *err = nil;
    TTIOMSImage *img = [TTIOMSImage readFromFilePath:path error:&err];
    return img;
}

@end
```

(Note: this property is computed every call; if perf becomes a concern,
add a cached ivar. For v1.2.0 the read is rare and cheap.)

- [ ] **Step 3: Add a quick test in `TestMSImageMzAxis.m`**

Append to `objc/Tests/TestMSImageMzAxis.m`:

```objc
void testSpectralDatasetMsImageAccessor(void)
{
    const NSUInteger W = 2, H = 2, SP = 3;
    NSMutableData *cube = [NSMutableData dataWithLength:W * H * SP * sizeof(double)];
    NSMutableData *mz = [NSMutableData dataWithLength:SP * sizeof(double)];
    double *mp = mz.mutableBytes;
    for (NSUInteger i = 0; i < SP; i++) mp[i] = 100.0 * (i + 1);

    TTIOMSImage *img =
        [[TTIOMSImage alloc] initWithTitle:@"" isaInvestigationId:@""
                           identifications:@[] quantifications:@[]
                         provenanceRecords:@[]
                                     width:W height:H spectralPoints:SP
                                  tileSize:0 pixelSizeX:1.0 pixelSizeY:1.0
                               scanPattern:@"raster" cube:cube mzAxis:mz];

    NSString *path = axisPath(@"accessor");
    unlink([path fileSystemRepresentation]);
    NSError *err = nil;
    PASS([img writeToFilePath:path error:&err], "wrote image .tio");

    TTIOSpectralDataset *plain =
        [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(plain != nil, "opened as plain TTIOSpectralDataset");
    TTIOMSImage *via = plain.msImage;
    PASS(via != nil, "msImage accessor materialises image");
    PASS([via.mzAxis isEqualToData:mz], "mzAxis byte-equal via accessor");
    unlink([path fileSystemRepresentation]);
}
```

Register in `TTIOTestRunner.m` and add to test makefile (same pattern as Task 2.1).

- [ ] **Step 4: Build + run**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/objc && . /usr/share/GNUstep/Makefiles/GNUstep.sh && make && cd Tests && make && ./obj/TTIOTestRunner 2>&1 | grep -E "MsImageAccessor|msImage accessor" | tail -10'
```

Expected: PASS lines for new test.

- [ ] **Step 5: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -am "feat(objc): TTIOSpectralDataset.msImage accessor (category) + test"'
```

---

## Phase 2 acceptance gate

- [ ] All `TestMSImageMzAxis.m` tests pass.
- [ ] Full ObjC suite green (3123+ PASS / 0 FAIL).
- [ ] `git log --oneline | head -4` shows the 4 task commits in order (2.1 + 2.2 + 2.3 + 2.4).

---

# Phase 3 — Cross-language conformance

**Goal:** A single Python pytest writes a deterministic `.tio` with a populated `mz_axis`, then invokes Java + ObjC reader binaries as subprocesses. All three readers agree byte-equal on the 64-byte axis payload.

**Files:**
- Create: `java/src/test/java/global/thalion/ttio/conformance/MsImageXLangReader.java`
- Create: `objc/Tools/TtioMsImageXLangReader.m`
- Modify: `objc/Tools/GNUmakefile`
- Create: `python/tests/conformance/test_msimage_xlang.py`

---

## Task 3.1: Java reader CLI

**Files:**
- Create: `java/src/test/java/global/thalion/ttio/conformance/MsImageXLangReader.java`

- [ ] **Step 1: Write the reader**

Create `java/src/test/java/global/thalion/ttio/conformance/MsImageXLangReader.java`:

```java
/* TTI-O Java conformance helpers / SPDX-License-Identifier: Apache-2.0 */
package global.thalion.ttio.conformance;

import global.thalion.ttio.MSImage;
import global.thalion.ttio.SpectralDataset;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** CLI: reads a .tio's MSImage.mzAxis and writes the bytes to stdout
 *  in little-endian float64. Used by python/tests/conformance/test_msimage_xlang.py.
 */
public final class MsImageXLangReader {

    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            System.err.println("usage: MsImageXLangReader <path.tio>");
            System.exit(2);
        }
        try (SpectralDataset ds = SpectralDataset.open(args[0])) {
            MSImage img = ds.image();
            if (img == null) {
                System.err.println("no MSImage in " + args[0]);
                System.exit(3);
            }
            double[] axis = img.mzAxis();
            ByteBuffer buf = ByteBuffer.allocate(axis.length * 8)
                    .order(ByteOrder.LITTLE_ENDIAN);
            for (double v : axis) buf.putDouble(v);
            System.out.write(buf.array());
            System.out.flush();
        }
    }
}
```

- [ ] **Step 2: Verify compilation**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/java && mvn -B test-compile -Dhdf5.jar=/usr/share/java/jarhdf5.jar 2>&1 | tail -5'
```

Expected: BUILD SUCCESS.

- [ ] **Step 3: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis && git add java/src/test/java/global/thalion/ttio/conformance/MsImageXLangReader.java && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "test(java): MsImageXLangReader CLI for cross-language mz_axis byte-equality"'
```

---

## Task 3.2: ObjC reader CLI

**Files:**
- Create: `objc/Tools/TtioMsImageXLangReader.m`
- Modify: `objc/Tools/GNUmakefile`

- [ ] **Step 1: Write the reader**

Create `objc/Tools/TtioMsImageXLangReader.m`:

```objc
/*
 * TtioMsImageXLangReader.m — CLI for cross-language conformance.
 *
 * Reads a .tio's MSImage.mzAxis and writes the bytes to stdout
 * in little-endian float64. Used by
 * python/tests/conformance/test_msimage_xlang.py.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Image/TTIOMSImage.h"
#import <stdio.h>

int main(int argc, const char *argv[])
{
    if (argc != 2) {
        fprintf(stderr, "usage: TtioMsImageXLangReader <path.tio>\n");
        return 2;
    }
    @autoreleasepool {
        NSError *err = nil;
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        TTIOMSImage *img = [TTIOMSImage readFromFilePath:path error:&err];
        if (img == nil || img.mzAxis == nil) {
            fprintf(stderr, "no MSImage or mzAxis in %s\n", argv[1]);
            return 3;
        }
        fwrite(img.mzAxis.bytes, 1, img.mzAxis.length, stdout);
        fflush(stdout);
    }
    return 0;
}
```

- [ ] **Step 2: Register in tools makefile**

Modify `objc/Tools/GNUmakefile` — add the new tool. Search for `TtioRefXLangReader` (the references-conformance equivalent) for the pattern, then add a parallel block:

```makefile
TOOL_NAME += TtioMsImageXLangReader
TtioMsImageXLangReader_OBJC_FILES = TtioMsImageXLangReader.m
TtioMsImageXLangReader_TOOL_LIBS  = -lTTIO -lhdf5
```

(Match exactly the form of the existing `TtioRefXLangReader` block.)

- [ ] **Step 3: Build**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/objc && . /usr/share/GNUstep/Makefiles/GNUstep.sh && cd Tools && make 2>&1 | tail -5'
```

Expected: builds clean; `objc/Tools/obj/TtioMsImageXLangReader` exists.

- [ ] **Step 4: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis && git add objc/Tools/TtioMsImageXLangReader.m objc/Tools/GNUmakefile && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "test(objc): TtioMsImageXLangReader CLI for cross-language mz_axis byte-equality"'
```

---

## Task 3.3: Python conformance test driver

**Files:**
- Create: `python/tests/conformance/test_msimage_xlang.py`

- [ ] **Step 1: Write the conformance test**

Create `python/tests/conformance/test_msimage_xlang.py`:

```python
"""Cross-language parity for MSImage.mz_axis (1.2.0).

Python writes a deterministic .tio with a populated mz_axis. Java +
ObjC reader CLIs are invoked as subprocesses; each emits the 64-byte
mz_axis payload to stdout in little-endian float64. The test asserts
byte-equality across all three languages.

Pattern follows test_references_xlang.py (Phase 0 of tio-browser).

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import numpy as np
import pytest

from ttio import MSImage
from ttio.providers import open_provider


# ─── Paths ──────────────────────────────────────────────────────────

_REPO = Path(__file__).resolve().parents[3]
_JAVA = _REPO / "java"
_OBJC = _REPO / "objc"

_JAVA_CLASSES = _JAVA / "target" / "classes"
_JAVA_TEST_CLASSES = _JAVA / "target" / "test-classes"
_JAVA_CLASSPATH_TXT = _JAVA / "target" / "classpath.txt"
_JAVA_HDF5_JAR = Path("/usr/share/java/jarhdf5.jar")

_OBJC_BIN = _OBJC / "Tools" / "obj"
_OBJC_LIB = _OBJC / "Source" / "obj"


# ─── Canonical fixture ──────────────────────────────────────────────

W, H, SP = 4, 3, 8
MZ_AXIS = np.linspace(100.0, 800.0, SP)   # 100, 200, ..., 800
INTENSITY = np.arange(H * W * SP, dtype=np.float64).reshape(H, W, SP) * 0.1


# ─── Skip helpers ───────────────────────────────────────────────────

def _java_runtime_available() -> bool:
    if not _JAVA_CLASSES.is_dir() or not _JAVA_TEST_CLASSES.is_dir():
        return False
    if not _JAVA_CLASSPATH_TXT.is_file():
        return False
    if not _JAVA_HDF5_JAR.is_file():
        return False
    if shutil.which("java") is None:
        return False
    return (_JAVA_TEST_CLASSES
            / "global/thalion/ttio/conformance/MsImageXLangReader.class").is_file()


def _objc_runtime_available() -> bool:
    return ((_OBJC_BIN / "TtioMsImageXLangReader").is_file()
            and _OBJC_LIB.is_dir())


def _java_classpath() -> str:
    return ":".join((
        str(_JAVA_CLASSES),
        str(_JAVA_TEST_CLASSES),
        _JAVA_CLASSPATH_TXT.read_text().strip(),
        str(_JAVA_HDF5_JAR),
    ))


def _objc_env() -> dict:
    env = os.environ.copy()
    extra = [str(_OBJC_LIB), "/usr/local/lib"]
    cur = env.get("LD_LIBRARY_PATH", "")
    if cur:
        extra.append(cur)
    env["LD_LIBRARY_PATH"] = ":".join(extra)
    return env


# ─── Test ───────────────────────────────────────────────────────────

def test_mz_axis_byte_equal_xlang(tmp_path: Path) -> None:
    """Python writes; Java + ObjC read; mz_axis bytes match Python's."""
    out = tmp_path / "xlang.tio"
    img = MSImage(
        width=W, height=H, spectral_points=SP,
        intensity=INTENSITY, mz_axis=MZ_AXIS,
        pixel_size_x=10.0, pixel_size_y=10.0, scan_pattern="raster",
    )
    with open_provider(str(out), provider="hdf5", mode="w") as sp:
        root = sp.root_group()
        study = root.create_group("study")
        img.write_to(study)

    # Python's ground-truth bytes
    expected = np.ascontiguousarray(MZ_AXIS, dtype="<f8").tobytes()
    assert len(expected) == SP * 8

    # Java reader
    if _java_runtime_available():
        java_proc = subprocess.run(
            ["java", "-cp", _java_classpath(),
             "global.thalion.ttio.conformance.MsImageXLangReader", str(out)],
            check=True, capture_output=True, timeout=60,
        )
        assert java_proc.stdout == expected, (
            f"Java mz_axis bytes differ: got {len(java_proc.stdout)} bytes")
    else:
        pytest.skip("Java conformance reader not built")

    # ObjC reader
    if _objc_runtime_available():
        objc_proc = subprocess.run(
            [str(_OBJC_BIN / "TtioMsImageXLangReader"), str(out)],
            check=True, capture_output=True, timeout=60, env=_objc_env(),
        )
        assert objc_proc.stdout == expected, (
            f"ObjC mz_axis bytes differ: got {len(objc_proc.stdout)} bytes")
    else:
        pytest.skip("ObjC conformance reader not built")
```

- [ ] **Step 2: Build prerequisites and run**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/java && mvn -B test-compile dependency:build-classpath -Dmdep.outputFile=target/classpath.txt -Dhdf5.jar=/usr/share/java/jarhdf5.jar 2>&1 | tail -3'
```

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/objc && . /usr/share/GNUstep/Makefiles/GNUstep.sh && cd Tools && make 2>&1 | tail -3'
```

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/python && pytest tests/conformance/test_msimage_xlang.py -v'
```

Expected: PASS — Python's bytes match Java's match ObjC's, all 64 bytes byte-equal.

- [ ] **Step 3: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis && git add python/tests/conformance/test_msimage_xlang.py && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "test(conformance): MSImage.mz_axis byte-equality across Python / Java / ObjC"'
```

---

## Phase 3 acceptance gate

- [ ] `test_msimage_xlang.py` passes.
- [ ] All three readers emit identical 64-byte payloads.

---

# Phase 4 — Version bump + docs + push PR

**Goal:** Stamp 1.2.0 on the library, add CHANGELOG entry, push the branch and open a library PR.

---

## Task 4.1: Bump library version 1.1.0 → 1.2.0

**Files:**
- Modify: `java/pom.xml`
- Modify: `python/pyproject.toml`
- Modify: `objc/Source/TTIOVersion.h` (or equivalent — search for `1.1.0`)

- [ ] **Step 1: Locate version constants**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis && grep -rln "1\\.1\\.0" --include="pom.xml" --include="pyproject.toml" --include="*.h" 2>/dev/null | head -10'
```

- [ ] **Step 2: Bump Java**

In `java/pom.xml` change `<version>1.1.0</version>` (project version, NOT dependency declarations) to `<version>1.2.0</version>`.

- [ ] **Step 3: Bump Python**

In `python/pyproject.toml` change `version = "1.1.0"` to `version = "1.2.0"`.

- [ ] **Step 4: Bump ObjC**

Search for the ObjC version constant and change. If it's a `#define` like `TTIO_VERSION_STRING`, change `"1.1.0"` to `"1.2.0"`.

- [ ] **Step 5: Run all three test suites again**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/java && mvn -B test -Dhdf5.jar=/usr/share/java/jarhdf5.jar 2>&1 | tail -3'
```

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/python && pytest 2>&1 | tail -3'
```

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis/objc && . /usr/share/GNUstep/Makefiles/GNUstep.sh && cd Tests && ./obj/TTIOTestRunner 2>&1 | grep -cE "^FAIL"'
```

Expected: all green; ObjC `FAIL` count = 0.

- [ ] **Step 6: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -am "chore: bump library version 1.1.0 -> 1.2.0 (3 langs)"'
```

---

## Task 4.2: CHANGELOG entry

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add entry**

Insert at the top of `CHANGELOG.md`, above the existing `[Unreleased]` (or between `[Unreleased]` and the previous version):

```markdown
## [1.2.0] — 2026-05-07

### Added
- **`MSImage.mz_axis`**: shared m/z spectral axis on `MSImage` across
  Java, Python, and ObjC. Persisted as a 1-D FLOAT64 dataset under
  `/study/image_cube/mz_axis`. Required for imzML export of an
  `MSImage`-bearing `.tio`.
- **`MSImage.toPixelSpectra()` / `to_pixel_spectra()` / `-pixelSpectra`**:
  continuous-mode projection of the cube into per-pixel `(mz, intensity)`
  records suitable for `ImzMLWriter.write`.
- **`SpectralDataset.image()` / `.image` / `-msImage`**: accessor on the
  open dataset returning the materialised `MSImage` if `/study/image_cube`
  is present. Pattern mirrors the 1.1.0 `references()` accessor.
- **Python `SpectralDataset.write_minimal(image=...)`**: high-level
  kwarg writes the image cube alongside runs.
- **Python `MSImage.write_to(study_group)` / `MSImage.read_from(study_group)`**:
  standalone storage methods mirroring Java's `writeTo` / `readFrom`.
- **ObjC `TTIOPixelSpectrum`**: new value class for `-pixelSpectra` output.

### Backwards compatibility
- v1.1.x `.tio` files without `mz_axis` read as empty axis; the imzML
  exporter raises a clear error pointing at re-import.
- v1.1.x readers transparently skip the `mz_axis` dataset when reading
  v1.2.0-written files.

### Cross-language conformance
- New `python/tests/conformance/test_msimage_xlang.py` asserts byte-equal
  `mz_axis` payloads when written by Python and read back by Java + ObjC.
```

- [ ] **Step 2: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/msimage-mz-axis && git add CHANGELOG.md && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "docs: CHANGELOG entry for 1.2.0 (MSImage.mz_axis cross-language parity)"'
```

---

## Task 4.3: Push branch + open library PR

**Files:** none (git operations)

- [ ] **Step 1: Push the branch**

```
"/c/Program Files/Git/bin/git.exe" -c safe.directory='*' -C '//wsl.localhost/Ubuntu/home/toddw/TTI-O.worktrees/msimage-mz-axis' push -u origin msimage-mz-axis
```

Expected: branch push succeeds.

- [ ] **Step 2: Compose PR body**

Write `C:\Users\toddw\AppData\Local\Temp\msimage-pr-body.md`:

```markdown
## Summary

Closes the cross-language gap that prevented imzML export from a `.tio`-embedded `MSImage`. Adds `mz_axis` as a 1-D FLOAT64 dataset under `/study/image_cube/`, plus `toPixelSpectra()` / `to_pixel_spectra()` / `-pixelSpectra` projection methods and `SpectralDataset.image()` accessors across all three reference languages.

- **Java** — `MSImage.mzAxis` field, 15-arg ctor, `writeTo`/`readFrom` updates, `toPixelSpectra()`. `SpectralDataset.image()` materialises eagerly on `open()`.
- **Python** — `MSImage.mz_axis` dataclass field with validation, standalone `write_to`/`read_from` methods, `to_pixel_spectra()`. `SpectralDataset.write_minimal(image=...)` kwarg + lazy `image` property.
- **ObjC** — `TTIOMSImage.mzAxis` property, new 14-arg initialiser, persistence via existing override hooks, `-pixelSpectra` projection. New `TTIOPixelSpectrum` value class. `TTIOSpectralDataset.msImage` accessor (category).
- **Cross-language conformance** — `test_msimage_xlang.py` asserts byte-equal `mz_axis` between Python writer and Java + ObjC readers.

Library bump 1.1.0 → 1.2.0 (additive minor — new optional field + new accessor; no wire-breaking change). Legacy v1.1.x `.tio` files without `mz_axis` read transparently with empty axis.

Spec: `docs/superpowers/specs/2026-05-07-msimage-mz-axis-design.md`.

## Test plan

- [x] Java: `MSImageMzAxisTest` (5 tests) + `SpectralDatasetTest` accessor tests (2) — `mvn -B test`.
- [x] Python: `test_ms_image_mz_axis.py` (7 tests) — `pytest python/tests/test_ms_image_mz_axis.py`.
- [x] ObjC: `TestMSImageMzAxis.m` (3 PASS groups) — `cd objc/Tests && ./obj/TTIOTestRunner`.
- [x] Cross-language: `test_msimage_xlang.py` — Python writes, Java + ObjC readers emit byte-equal 64-byte mz_axis payloads.
- [x] No regressions: full Java (809+) / Python / ObjC (3123+) suites green.

## Follow-up after merge

- Update tio-browser PR #29 to depend on `global.thalion:ttio:1.2.0`, replace the imzML stub in `ExportTask.exportImzML()` with `dataset.image().toPixelSpectra()` + `ImzMLWriter.write(...)`, add an MSImage round-trip test.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

- [ ] **Step 3: Open the PR**

```
gh pr create --repo DTW-Thalion/TTI-O --base main --head msimage-mz-axis --title 'feat: MSImage.mz_axis cross-language parity (1.1.0 -> 1.2.0)' --body-file 'C:\Users\toddw\AppData\Local\Temp\msimage-pr-body.md'
```

Expected: PR URL printed.

- [ ] **Step 4: Verify branch tracks remote**

```
"/c/Program Files/Git/bin/git.exe" -c safe.directory='*' -C '//wsl.localhost/Ubuntu/home/toddw/TTI-O.worktrees/msimage-mz-axis' status -sb
```

Expected: `## msimage-mz-axis...origin/msimage-mz-axis`.

---

## Phase 4 acceptance gate

- [ ] All three language test suites green at 1.2.0.
- [ ] CHANGELOG entry committed.
- [ ] Branch pushed to `origin/msimage-mz-axis`.
- [ ] PR opened and URL recorded.

---

# Post-merge follow-up (not part of this plan)

After the library PR merges:

1. Switch to the Phase 9 worktree: `cd ~/TTI-O.worktrees/tio-browser`.
2. `git fetch origin && git rebase origin/main` on `phase-9-export-dialog`.
3. Bump `<ttio.version>` from `1.1.0` to `1.2.0` in `tio-browser/pom.xml`.
4. Replace the `imzML` stub in `tio-browser/src/main/java/global/thalion/ttio/browser/exporters/ExportTask.java` with:

   ```java
   case "imzML" -> exportImzML();
   ```

   And implement:

   ```java
   private void exportImzML() {
       MSImage img = dataset.image();
       if (img == null) {
           throw new IllegalStateException(
               "imzML export requires an MSImage in /study/image_cube; "
               + "this .tio has none.");
       }
       List<ImzMLReader.PixelSpectrum> pixels = img.toPixelSpectra();
       ImzMLWriter.write(pixels, config.targetPath, /* ibdPath */ null,
           config.imzMlMode,
           img.width(), img.height(), 1,
           img.pixelSizeX(), img.pixelSizeY(),
           img.scanPattern(), /* uuidHex */ null);
   }
   ```

5. Add a round-trip test: write a synthesized `MSImage`-bearing `.tio` in test setup, export to imzML, re-import via Phase 8's `ImportTask`, assert `mz_axis` and `intensity` byte-equal.
6. Push update to PR #29.

This follow-up is tracked separately from this implementation plan.
