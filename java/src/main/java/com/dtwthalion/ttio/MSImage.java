/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio;

import com.dtwthalion.ttio.Enums.Compression;
import com.dtwthalion.ttio.Enums.Precision;
import com.dtwthalion.ttio.providers.StorageDataset;
import com.dtwthalion.ttio.providers.StorageGroup;

import java.util.List;

/**
 * Imaging mass spectrometry dataset with spatial grid and tile access.
 *
 * <p>Stored as a 3-D intensity cube
 * ({@code height × width × spectralPoints}) under
 * {@code /study/image_cube/}.</p>
 *
 * <p>v0.7 M44: I/O routed through {@link StorageGroup} /
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
 * @since 0.6
 */
public class MSImage {

    private final int width;
    private final int height;
    private final int spectralPoints;
    private final int tileSize;
    private final double pixelSizeX;
    private final double pixelSizeY;
    private final String scanPattern;
    private final double[] intensityCube;

    // Dataset-level composition fields
    private final String title;
    private final String isaInvestigationId;
    private final List<Identification> identifications;
    private final List<Quantification> quantifications;
    private final List<ProvenanceRecord> provenanceRecords;

    public MSImage(int width, int height, int spectralPoints, int tileSize,
                   double pixelSizeX, double pixelSizeY, String scanPattern,
                   double[] intensityCube,
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
        this.title = title != null ? title : "";
        this.isaInvestigationId = isaInvestigationId != null ? isaInvestigationId : "";
        this.identifications = identifications != null ? List.copyOf(identifications) : List.of();
        this.quantifications = quantifications != null ? List.copyOf(quantifications) : List.of();
        this.provenanceRecords = provenanceRecords != null ? List.copyOf(provenanceRecords) : List.of();
    }

    /** Convenience — image-only construction (empty dataset-level metadata). */
    public MSImage(int width, int height, int spectralPoints,
                   double pixelSizeX, double pixelSizeY, String scanPattern,
                   double[] intensityCube) {
        this(width, height, spectralPoints, 0,
             pixelSizeX, pixelSizeY, scanPattern, intensityCube,
             "", "", List.of(), List.of(), List.of());
    }

    public int width() { return width; }
    public int height() { return height; }
    public int spectralPoints() { return spectralPoints; }
    public int tileSize() { return tileSize; }
    public double pixelSizeX() { return pixelSizeX; }
    public double pixelSizeY() { return pixelSizeY; }
    public String scanPattern() { return scanPattern; }
    public double[] intensityCube() { return intensityCube; }

    public String title() { return title; }
    public String isaInvestigationId() { return isaInvestigationId; }
    public List<Identification> identifications() { return identifications; }
    public List<Quantification> quantifications() { return quantifications; }
    public List<ProvenanceRecord> provenanceRecords() { return provenanceRecords; }

    /** Get intensity at pixel (row, col) for spectral index s. */
    public double valueAt(int row, int col, int s) {
        return intensityCube[(row * width + col) * spectralPoints + s];
    }

    /** Get the full spectrum at pixel (row, col). */
    public double[] spectrumAt(int row, int col) {
        int base = (row * width + col) * spectralPoints;
        double[] result = new double[spectralPoints];
        System.arraycopy(intensityCube, base, result, 0, spectralPoints);
        return result;
    }

    /** Write this image cube to a storage study group.
     *
     *  <p>v0.7 M44: emits the cube as a 3-D dataset via
     *  {@link StorageGroup#createDatasetND} so every backend can
     *  round-trip the spatial+spectral rank.</p> */
    public void writeTo(StorageGroup studyGroup) {
        try (StorageGroup ic = studyGroup.createGroup("image_cube")) {
            ic.setAttribute("width", (long) width);
            ic.setAttribute("height", (long) height);
            ic.setAttribute("spectral_points", (long) spectralPoints);
            ic.setAttribute("pixel_size_x", String.valueOf(pixelSizeX));
            ic.setAttribute("pixel_size_y", String.valueOf(pixelSizeY));
            if (scanPattern != null)
                ic.setAttribute("scan_pattern", scanPattern);

            long[] shape = { height, width, spectralPoints };
            long[] chunks = { 1, 1, spectralPoints };
            try (StorageDataset ds = ic.createDatasetND("intensity",
                    Precision.FLOAT64, shape, chunks,
                    Compression.ZLIB, 6)) {
                ds.writeAll(intensityCube);
            }
        }
    }

    /** Read an image cube from a storage file.
     *
     *  <p>v0.7 M44: parameter type relaxed to {@link StorageGroup}.</p> */
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
                // v0.7 M44: route through the storage protocol.
                cube = (double[]) ds.readAll();
            }
            return new MSImage(width, height, spectralPoints,
                    pixelSizeX, pixelSizeY, scanPattern, cube);
        }
    }
}
