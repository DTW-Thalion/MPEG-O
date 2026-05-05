/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.Enums.IRMode;
import global.thalion.ttio.Enums.Precision;
import global.thalion.ttio.providers.StorageDataset;
import global.thalion.ttio.providers.StorageGroup;

import java.util.List;

/**
 * Infrared hyperspectral imaging dataset: {@code width × height}
 * pixel grid, each pixel an IR spectrum of {@code spectralPoints}
 * intensity values sampled at a shared wavenumber axis.
 *
 * <p>Stored under {@code /study/ir_image_cube/} as a 3-D float64
 * intensity cube with a 1-D {@code wavenumbers} axis.</p>
 *
 * <p><b>API status:</b> Stable (v0.11, M73).</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOIRImage}, Python {@code ttio.ir_image.IRImage}.</p>
 *
 *
 */
public class IRImage {

    private static final String GROUP_NAME = "ir_image_cube";

    private final int width;
    private final int height;
    private final int spectralPoints;
    private final int tileSize;
    private final double pixelSizeX;
    private final double pixelSizeY;
    private final String scanPattern;
    private final IRMode mode;
    private final double resolutionCmInv;
    private final double[] intensityCube;
    private final double[] wavenumbers;

    private final String title;
    private final String isaInvestigationId;
    private final List<Identification> identifications;
    private final List<Quantification> quantifications;
    private final List<ProvenanceRecord> provenanceRecords;

    public IRImage(int width, int height, int spectralPoints, int tileSize,
                   double pixelSizeX, double pixelSizeY, String scanPattern,
                   IRMode mode, double resolutionCmInv,
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
        this.mode = mode != null ? mode : IRMode.TRANSMITTANCE;
        this.resolutionCmInv = resolutionCmInv;
        this.intensityCube = intensityCube;
        this.wavenumbers = wavenumbers;
        this.title = title != null ? title : "";
        this.isaInvestigationId = isaInvestigationId != null ? isaInvestigationId : "";
        this.identifications = identifications != null ? List.copyOf(identifications) : List.of();
        this.quantifications = quantifications != null ? List.copyOf(quantifications) : List.of();
        this.provenanceRecords = provenanceRecords != null ? List.copyOf(provenanceRecords) : List.of();
    }

    public IRImage(int width, int height, int spectralPoints,
                   double pixelSizeX, double pixelSizeY, String scanPattern,
                   IRMode mode, double resolutionCmInv,
                   double[] intensityCube, double[] wavenumbers) {
        this(width, height, spectralPoints, 0,
             pixelSizeX, pixelSizeY, scanPattern,
             mode, resolutionCmInv,
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
    public IRMode mode() { return mode; }
    public double resolutionCmInv() { return resolutionCmInv; }
    public double[] intensityCube() { return intensityCube; }
    public double[] wavenumbers() { return wavenumbers; }

    public String title() { return title; }
    public String isaInvestigationId() { return isaInvestigationId; }
    public List<Identification> identifications() { return identifications; }
    public List<Quantification> quantifications() { return quantifications; }
    public List<ProvenanceRecord> provenanceRecords() { return provenanceRecords; }

    public double valueAt(int row, int col, int s) {
        return intensityCube[(row * width + col) * spectralPoints + s];
    }

    public double[] spectrumAt(int row, int col) {
        int base = (row * width + col) * spectralPoints;
        double[] result = new double[spectralPoints];
        System.arraycopy(intensityCube, base, result, 0, spectralPoints);
        return result;
    }

    public void writeTo(StorageGroup studyGroup) {
        try (StorageGroup ic = studyGroup.createGroup(GROUP_NAME)) {
            ic.setAttribute("width", (long) width);
            ic.setAttribute("height", (long) height);
            ic.setAttribute("spectral_points", (long) spectralPoints);
            ic.setAttribute("pixel_size_x", String.valueOf(pixelSizeX));
            ic.setAttribute("pixel_size_y", String.valueOf(pixelSizeY));
            ic.setAttribute("ir_mode",
                    mode == IRMode.ABSORBANCE ? "absorbance" : "transmittance");
            ic.setAttribute("resolution_cm_inv", String.valueOf(resolutionCmInv));
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

    public static IRImage readFrom(StorageGroup studyGroup) {
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
            String scanPattern = ic.hasAttribute("scan_pattern")
                    ? (String) ic.getAttribute("scan_pattern") : null;
            int tileSize = ic.hasAttribute("tile_size")
                    ? ((Number) ic.getAttribute("tile_size")).intValue() : 0;
            String modeStr = ic.hasAttribute("ir_mode")
                    ? (String) ic.getAttribute("ir_mode") : "transmittance";
            IRMode mode = "absorbance".equalsIgnoreCase(modeStr)
                    ? IRMode.ABSORBANCE : IRMode.TRANSMITTANCE;
            double resolutionCmInv = Double.parseDouble(
                    ic.hasAttribute("resolution_cm_inv")
                            ? (String) ic.getAttribute("resolution_cm_inv") : "0");

            double[] cube;
            try (StorageDataset ds = ic.openDataset("intensity")) {
                cube = (double[]) ds.readAll();
            }
            double[] wn;
            try (StorageDataset ds = ic.openDataset("wavenumbers")) {
                wn = (double[]) ds.readAll();
            }
            return new IRImage(width, height, spectralPoints, tileSize,
                    pixelSizeX, pixelSizeY, scanPattern,
                    mode, resolutionCmInv,
                    cube, wn,
                    "", "", List.of(), List.of(), List.of());
        }
    }
}
