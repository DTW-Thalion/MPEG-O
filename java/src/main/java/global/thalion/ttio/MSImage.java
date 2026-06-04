/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.Enums.ImageKind;
import global.thalion.ttio.Enums.Precision;
import global.thalion.ttio.Enums.SpectralAxisKind;
import global.thalion.ttio.importers.ImzMLReader;
import global.thalion.ttio.providers.StorageDataset;
import global.thalion.ttio.providers.StorageGroup;

import java.util.ArrayList;
import java.util.List;

/**
 * Imaging mass spectrometry dataset with spatial grid and tile access.
 *
 * <p>Stored as a 3-D intensity cube
 * ({@code height × width × spectralPoints}) under
 * {@code /study/image_cube/}.</p>
 *
 * <p>I/O routed through {@link StorageGroup} /
 * {@link StorageDataset}; this class no longer references the low-level
 * {@code Hdf5Group} / {@code Hdf5Dataset} types.</p>
 *
 * <p><b>Composition vs inheritance.</b> In Objective-C,
 * {@code TTIOMSImage} inherits from {@code TTIOSpectralDataset} so
 * dataset-level fields come for free. In Java,
 * {@code SpectralDataset} is a file-handle wrapper whose lifecycle
 * does not map cleanly to an MSImage subclass; composition is used
 * here (the five dataset-level fields live on {@code MSImage}
 * directly). This stylistic difference is recorded in
 * {@code docs/api-review-v0.6.md}.</p>
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOMSImage}, Python {@code ttio.ms_image.MSImage}.</p>
 *
 *
 */
public class MSImage extends Image {

    private final double[] mzAxis;     // NEW -- length 0 (legacy) or == spectralPoints

    /** Designated constructor (1.2.0): includes mzAxis. */
    public MSImage(int width, int height, int spectralPoints, int tileSize,
                   double pixelSizeX, double pixelSizeY, String scanPattern,
                   double[] intensityCube, double[] mzAxis,
                   String title, String isaInvestigationId,
                   List<Identification> identifications,
                   List<Quantification> quantifications,
                   List<ProvenanceRecord> provenanceRecords) {
        super(width, height, spectralPoints, tileSize,
              pixelSizeX, pixelSizeY, scanPattern, intensityCube,
              title, isaInvestigationId,
              identifications, quantifications, provenanceRecords);
        if (mzAxis == null) mzAxis = new double[0];
        if (mzAxis.length > 0 && mzAxis.length != spectralPoints) {
            throw new IllegalArgumentException(
                "mzAxis length " + mzAxis.length
                + " does not match spectralPoints=" + spectralPoints);
        }
        this.mzAxis = mzAxis;
    }

    /** Backwards-compat 13-arg ctor (1.1.x callers): defaults mzAxis to empty. */
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

    /** Convenience -- image-only construction (empty dataset-level metadata). */
    public MSImage(int width, int height, int spectralPoints,
                   double pixelSizeX, double pixelSizeY, String scanPattern,
                   double[] intensityCube) {
        this(width, height, spectralPoints, 0,
             pixelSizeX, pixelSizeY, scanPattern, intensityCube, new double[0],
             "", "", List.of(), List.of(), List.of());
    }

    /** The shared m/z axis when present; empty array for legacy files. */
    public double[] mzAxis() { return mzAxis; }

    @Override
    public ImageKind kind() { return ImageKind.MS; }

    @Override
    public double[] spectralAxis() { return mzAxis; }

    @Override
    public SpectralAxisKind spectralAxisKind() { return SpectralAxisKind.MZ; }

    /** Project this image as a list of {@link
     *  global.thalion.ttio.importers.ImzMLReader.PixelSpectrum} records
     *  in continuous mode (every pixel shares {@link #mzAxis}).
     *
     *  @throws IllegalStateException if {@code mzAxis} is empty.
     */
    public List<ImzMLReader.PixelSpectrum>
            toPixelSpectra() {
        if (mzAxis.length == 0) {
            throw new IllegalStateException(
                "MSImage has no mz_axis; cannot project to imzML pixels. "
                + "The .tio was written before format v1.2 added the spectral "
                + "axis. Re-import from a source format that carries m/z "
                + "calibration (imzML, mzML), or supply mz_axis explicitly.");
        }
        List<ImzMLReader.PixelSpectrum>
            pixels = new ArrayList<>(width * height);
        for (int row = 0; row < height; row++) {
            for (int col = 0; col < width; col++) {
                double[] intensity = spectrumAt(row, col);
                // x = col (image-plane), y = row, z = 1 (single plane).
                pixels.add(new ImzMLReader.PixelSpectrum(col, row, 1, mzAxis, intensity));
            }
        }
        return pixels;
    }

    /**
     * Parse a {@code pixel_size_x}/{@code pixel_size_y} attribute that may be
     * stored as a native-double (new form, written since 1.2.0 fix) or as a
     * VL_STRING (legacy form written by Java and Python before the fix).
     * Returns 0.0 when the attribute is absent.
     */
    private static double parseDoubleAttr(
            global.thalion.ttio.providers.StorageGroup grp, String attr) {
        if (!grp.hasAttribute(attr)) return 0.0;
        Object raw = grp.getAttribute(attr);
        if (raw instanceof Number n) return n.doubleValue();
        if (raw instanceof String s) return Double.parseDouble(s);
        return 0.0;
    }

    /** Write this image cube to a storage study group.
     *
     *  <p>emits the cube as a 3-D dataset via
     *  {@link StorageGroup#createDatasetND} so every backend can
     *  round-trip the spatial+spectral rank.</p> */
    public void writeTo(StorageGroup studyGroup) {
        try (StorageGroup ic = studyGroup.createGroup("image_cube")) {
            ic.setAttribute("width", (long) width);
            ic.setAttribute("height", (long) height);
            ic.setAttribute("spectral_points", (long) spectralPoints);
            ic.setAttribute("pixel_size_x", Double.valueOf(pixelSizeX));
            ic.setAttribute("pixel_size_y", Double.valueOf(pixelSizeY));
            if (scanPattern != null)
                ic.setAttribute("scan_pattern", scanPattern);

            long[] shape = { height, width, spectralPoints };
            long[] chunks = { 1, 1, spectralPoints };
            try (StorageDataset ds = ic.createDatasetND("intensity",
                    Precision.FLOAT64, shape, chunks,
                    Compression.ZLIB, 6)) {
                ds.writeAll(intensityCube);
            }

            if (mzAxis.length > 0) {
                long[] axisShape  = { spectralPoints };
                long[] axisChunks = { spectralPoints };
                try (StorageDataset axisDs = ic.createDatasetND("mz_axis",
                        Precision.FLOAT64, axisShape, axisChunks,
                        Compression.ZLIB, 6)) {
                    axisDs.writeAll(mzAxis);
                }
            }
        }
    }

    /** Read an image cube from a storage file.
     *
     *  <p>parameter type relaxed to {@link StorageGroup}.</p> */
    public static MSImage readFrom(StorageGroup studyGroup) {
        if (!studyGroup.hasChild("image_cube")) return null;
        try (StorageGroup ic = studyGroup.openGroup("image_cube")) {
            int width = ((Number) ic.getAttribute("width")).intValue();
            int height = ((Number) ic.getAttribute("height")).intValue();
            int spectralPoints = ((Number) ic.getAttribute("spectral_points")).intValue();
            double pixelSizeX = parseDoubleAttr(ic, "pixel_size_x");
            double pixelSizeY = parseDoubleAttr(ic, "pixel_size_y");
            String scanPattern = ic.hasAttribute("scan_pattern")
                    ? (String) ic.getAttribute("scan_pattern") : null;

            double[] cube;
            try (StorageDataset ds = ic.openDataset("intensity")) {
                // route through the storage protocol.
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
}
