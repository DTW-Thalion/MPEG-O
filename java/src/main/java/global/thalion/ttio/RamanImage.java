/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.Enums.Precision;
import global.thalion.ttio.providers.StorageDataset;
import global.thalion.ttio.providers.StorageGroup;

import java.util.List;

/**
 * Raman hyperspectral imaging dataset: {@code width × height} pixel
 * grid, each pixel a Raman spectrum of {@code spectralPoints}
 * intensity values sampled at a shared wavenumber axis.
 *
 * <p>Stored under {@code /study/raman_image_cube/} as a 3-D
 * float64 intensity cube with a 1-D {@code wavenumbers} axis.</p>
 *
 * <p>Composition vs inheritance notes match {@link MSImage}.</p>
 *
 * <p><b>API status:</b> Stable (v0.11, M73).</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIORamanImage}, Python
 * {@code ttio.raman_image.RamanImage}.</p>
 *
 *
 */
public class RamanImage {

    private static final String GROUP_NAME = "raman_image_cube";

    private final int width;
    private final int height;
    private final int spectralPoints;
    private final int tileSize;
    private final double pixelSizeX;
    private final double pixelSizeY;
    private final String scanPattern;
    private final double excitationWavelengthNm;
    private final double laserPowerMw;
    private final double[] intensityCube;
    private final double[] wavenumbers;

    private final String title;
    private final String isaInvestigationId;
    private final List<Identification> identifications;
    private final List<Quantification> quantifications;
    private final List<ProvenanceRecord> provenanceRecords;

    public RamanImage(int width, int height, int spectralPoints, int tileSize,
                      double pixelSizeX, double pixelSizeY, String scanPattern,
                      double excitationWavelengthNm, double laserPowerMw,
                      double[] intensityCube, double[] wavenumbers,
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
        this.excitationWavelengthNm = excitationWavelengthNm;
        this.laserPowerMw = laserPowerMw;
        this.intensityCube = intensityCube;
        this.wavenumbers = wavenumbers;
        this.title = title != null ? title : "";
        this.isaInvestigationId = isaInvestigationId != null ? isaInvestigationId : "";
        this.identifications = identifications != null ? List.copyOf(identifications) : List.of();
        this.quantifications = quantifications != null ? List.copyOf(quantifications) : List.of();
        this.provenanceRecords = provenanceRecords != null ? List.copyOf(provenanceRecords) : List.of();
    }

    /** Convenience — image-only construction (empty dataset-level metadata). */
    public RamanImage(int width, int height, int spectralPoints,
                      double pixelSizeX, double pixelSizeY, String scanPattern,
                      double excitationWavelengthNm, double laserPowerMw,
                      double[] intensityCube, double[] wavenumbers) {
        this(width, height, spectralPoints, 0,
             pixelSizeX, pixelSizeY, scanPattern,
             excitationWavelengthNm, laserPowerMw,
             intensityCube, wavenumbers,
             "", "", List.of(), List.of(), List.of());
    }

    public int width() { return width; }
    public int height() { return height; }
    public int spectralPoints() { return spectralPoints; }
    public int tileSize() { return tileSize; }
    public double pixelSizeX() { return pixelSizeX; }
    public double pixelSizeY() { return pixelSizeY; }
    public String scanPattern() { return scanPattern; }
    public double excitationWavelengthNm() { return excitationWavelengthNm; }
    public double laserPowerMw() { return laserPowerMw; }
    public double[] intensityCube() { return intensityCube; }
    public double[] wavenumbers() { return wavenumbers; }

    public String title() { return title; }
    public String isaInvestigationId() { return isaInvestigationId; }
    public List<Identification> identifications() { return identifications; }
    public List<Quantification> quantifications() { return quantifications; }
    public List<ProvenanceRecord> provenanceRecords() { return provenanceRecords; }

    /** Intensity at pixel ({@code row}, {@code col}), spectral index {@code s}. */
    public double valueAt(int row, int col, int s) {
        return intensityCube[(row * width + col) * spectralPoints + s];
    }

    /** Full spectrum at pixel ({@code row}, {@code col}). */
    public double[] spectrumAt(int row, int col) {
        int base = (row * width + col) * spectralPoints;
        double[] result = new double[spectralPoints];
        System.arraycopy(intensityCube, base, result, 0, spectralPoints);
        return result;
    }

    /** Write this image cube as an HDF5 sub-group of {@code studyGroup}. */
    public void writeTo(StorageGroup studyGroup) {
        try (StorageGroup ic = studyGroup.createGroup(GROUP_NAME)) {
            ic.setAttribute("width", (long) width);
            ic.setAttribute("height", (long) height);
            ic.setAttribute("spectral_points", (long) spectralPoints);
            ic.setAttribute("pixel_size_x", String.valueOf(pixelSizeX));
            ic.setAttribute("pixel_size_y", String.valueOf(pixelSizeY));
            ic.setAttribute("excitation_wavelength_nm", String.valueOf(excitationWavelengthNm));
            ic.setAttribute("laser_power_mw", String.valueOf(laserPowerMw));
            if (scanPattern != null)
                ic.setAttribute("scan_pattern", scanPattern);
            if (tileSize > 0)
                ic.setAttribute("tile_size", (long) tileSize);

            long chunkSize = tileSize > 0 ? tileSize : 1;
            long[] shape = { height, width, spectralPoints };
            long[] chunks = { chunkSize, chunkSize, spectralPoints };
            try (StorageDataset ds = ic.createDatasetND("intensity",
                    Precision.FLOAT64, shape, chunks,
                    Compression.ZLIB, 6)) {
                ds.writeAll(intensityCube);
            }

            long[] axisShape = { spectralPoints };
            long[] axisChunks = { spectralPoints };
            try (StorageDataset wn = ic.createDatasetND("wavenumbers",
                    Precision.FLOAT64, axisShape, axisChunks,
                    Compression.NONE, 0)) {
                wn.writeAll(wavenumbers);
            }
        }
    }

    /** Read a Raman image cube from a study group, or {@code null} if absent. */
    public static RamanImage readFrom(StorageGroup studyGroup) {
        if (!studyGroup.hasChild(GROUP_NAME)) return null;
        try (StorageGroup ic = studyGroup.openGroup(GROUP_NAME)) {
            int width = ((Number) ic.getAttribute("width")).intValue();
            int height = ((Number) ic.getAttribute("height")).intValue();
            int spectralPoints = ((Number) ic.getAttribute("spectral_points")).intValue();
            double pixelSizeX = Double.parseDouble(
                    ic.hasAttribute("pixel_size_x")
                            ? (String) ic.getAttribute("pixel_size_x") : "0");
            double pixelSizeY = Double.parseDouble(
                    ic.hasAttribute("pixel_size_y")
                            ? (String) ic.getAttribute("pixel_size_y") : "0");
            double excitationWavelengthNm = Double.parseDouble(
                    ic.hasAttribute("excitation_wavelength_nm")
                            ? (String) ic.getAttribute("excitation_wavelength_nm") : "0");
            double laserPowerMw = Double.parseDouble(
                    ic.hasAttribute("laser_power_mw")
                            ? (String) ic.getAttribute("laser_power_mw") : "0");
            String scanPattern = ic.hasAttribute("scan_pattern")
                    ? (String) ic.getAttribute("scan_pattern") : null;
            int tileSize = ic.hasAttribute("tile_size")
                    ? ((Number) ic.getAttribute("tile_size")).intValue() : 0;

            double[] cube;
            try (StorageDataset ds = ic.openDataset("intensity")) {
                cube = (double[]) ds.readAll();
            }
            double[] wn;
            try (StorageDataset ds = ic.openDataset("wavenumbers")) {
                wn = (double[]) ds.readAll();
            }
            return new RamanImage(width, height, spectralPoints, tileSize,
                    pixelSizeX, pixelSizeY, scanPattern,
                    excitationWavelengthNm, laserPowerMw,
                    cube, wn,
                    "", "", List.of(), List.of(), List.of());
        }
    }
}
