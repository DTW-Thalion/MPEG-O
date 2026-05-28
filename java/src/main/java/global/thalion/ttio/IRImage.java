/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
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

    /**
     * Full constructor capturing every cube dimension and study-level
     * annotation.
     *
     * @param width              image width in pixels
     * @param height             image height in pixels
     * @param spectralPoints     points along the wavenumber axis
     * @param tileSize           chunk side for HDF5 storage; 0 means
     *                           use full-image chunking
     * @param pixelSizeX         pixel pitch in micrometres along X
     * @param pixelSizeY         pixel pitch in micrometres along Y
     * @param scanPattern        free-form scan pattern label
     * @param mode               IR acquisition mode (TRANSMITTANCE /
     *                           ABSORBANCE); null defaults to
     *                           TRANSMITTANCE
     * @param resolutionCmInv    spectral resolution in {@code cm^-1}
     * @param intensityCube      row-major flat cube of shape
     *                           {@code [height, width, spectralPoints]}
     * @param wavenumbers        per-band wavenumber axis values
     * @param title              study title; null becomes empty
     * @param isaInvestigationId ISA investigation identifier; null
     *                           becomes empty
     * @param identifications    dataset-level identifications; null
     *                           becomes empty
     * @param quantifications    dataset-level quantifications; null
     *                           becomes empty
     * @param provenanceRecords  dataset-level provenance chain; null
     *                           becomes empty
     */
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

    /**
     * Convenience constructor that omits study-level annotation lists
     * (title, identifications, etc.) and uses full-image chunking.
     */
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

    /** @return Image width in pixels. */
    public int width() { return width; }

    /** @return Image height in pixels. */
    public int height() { return height; }

    /** @return Number of points along the wavenumber axis. */
    public int spectralPoints() { return spectralPoints; }

    /** @return HDF5 chunk side for storage; 0 means full-image chunking. */
    public int tileSize() { return tileSize; }

    /** @return Pixel pitch in micrometres along X. */
    public double pixelSizeX() { return pixelSizeX; }

    /** @return Pixel pitch in micrometres along Y. */
    public double pixelSizeY() { return pixelSizeY; }

    /** @return Free-form scan-pattern label (e.g. {@code "raster"}). */
    public String scanPattern() { return scanPattern; }

    /** @return IR acquisition mode (TRANSMITTANCE or ABSORBANCE). */
    public IRMode mode() { return mode; }

    /** @return Spectral resolution in {@code cm^-1}. */
    public double resolutionCmInv() { return resolutionCmInv; }

    /** @return Row-major intensity cube of shape {@code [height, width, spectralPoints]}. */
    public double[] intensityCube() { return intensityCube; }

    /** @return Per-band wavenumber axis values. */
    public double[] wavenumbers() { return wavenumbers; }

    /** @return Study title (may be empty). */
    public String title() { return title; }

    /** @return ISA investigation identifier (may be empty). */
    public String isaInvestigationId() { return isaInvestigationId; }

    /** @return Unmodifiable list of dataset-level identifications. */
    public List<Identification> identifications() { return identifications; }

    /** @return Unmodifiable list of dataset-level quantifications. */
    public List<Quantification> quantifications() { return quantifications; }

    /** @return Unmodifiable list of dataset-level provenance records. */
    public List<ProvenanceRecord> provenanceRecords() { return provenanceRecords; }

    /**
     * @param row pixel row in {@code [0, height)}
     * @param col pixel column in {@code [0, width)}
     * @param s   spectral index in {@code [0, spectralPoints)}
     * @return    intensity at pixel {@code (row, col)} for spectral band {@code s}
     */
    public double valueAt(int row, int col, int s) {
        return intensityCube[(row * width + col) * spectralPoints + s];
    }

    /**
     * Materialize the full spectrum at a single pixel as a fresh array.
     *
     * @param row pixel row in {@code [0, height)}
     * @param col pixel column in {@code [0, width)}
     * @return    newly allocated array of length {@link #spectralPoints()}
     */
    public double[] spectrumAt(int row, int col) {
        int base = (row * width + col) * spectralPoints;
        double[] result = new double[spectralPoints];
        System.arraycopy(intensityCube, base, result, 0, spectralPoints);
        return result;
    }

    /**
     * Persist the image and its annotations under the {@code ir_image}
     * subgroup of {@code studyGroup}.
     *
     * @param studyGroup the {@code /study} group of an open dataset
     */
    public void writeTo(StorageGroup studyGroup) {
        try (StorageGroup ic = studyGroup.createGroup(GROUP_NAME)) {
            ic.setAttribute("width", (long) width);
            ic.setAttribute("height", (long) height);
            ic.setAttribute("spectral_points", (long) spectralPoints);
            ic.setAttribute("pixel_size_x", Double.valueOf(pixelSizeX));
            ic.setAttribute("pixel_size_y", Double.valueOf(pixelSizeY));
            // ir_mode written as i64 enum (0=TRANSMITTANCE, 1=ABSORBANCE)
            // for cross-language parity with Python's int(IRMode) convention.
            ic.setAttribute("ir_mode",
                    Long.valueOf(mode == IRMode.ABSORBANCE ? 1L : 0L));
            ic.setAttribute("resolution_cm_inv", Double.valueOf(resolutionCmInv));
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

    /**
     * Load an {@code IRImage} from the {@code ir_image} subgroup of
     * {@code studyGroup}.
     *
     * @param studyGroup the {@code /study} group of an open dataset
     * @return           newly constructed {@code IRImage}, or
     *                   {@code null} when no {@code ir_image} child is
     *                   present
     */
    public static IRImage readFrom(StorageGroup studyGroup) {
        if (!studyGroup.hasChild(GROUP_NAME)) return null;
        try (StorageGroup ic = studyGroup.openGroup(GROUP_NAME)) {
            int width = ((Number) ic.getAttribute("width")).intValue();
            int height = ((Number) ic.getAttribute("height")).intValue();
            int spectralPoints = ((Number) ic.getAttribute("spectral_points")).intValue();
            double pixelSizeX = ic.hasAttribute("pixel_size_x")
                    ? parseDoubleAttr(ic.getAttribute("pixel_size_x")) : 0.0;
            double pixelSizeY = ic.hasAttribute("pixel_size_y")
                    ? parseDoubleAttr(ic.getAttribute("pixel_size_y")) : 0.0;
            String scanPattern = ic.hasAttribute("scan_pattern")
                    ? (String) ic.getAttribute("scan_pattern") : null;
            int tileSize = ic.hasAttribute("tile_size")
                    ? ((Number) ic.getAttribute("tile_size")).intValue() : 0;
            IRMode mode = ic.hasAttribute("ir_mode")
                    ? parseIRModeAttr(ic.getAttribute("ir_mode"))
                    : IRMode.TRANSMITTANCE;
            double resolutionCmInv = ic.hasAttribute("resolution_cm_inv")
                    ? parseDoubleAttr(ic.getAttribute("resolution_cm_inv")) : 0.0;

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

    /**
     * Parse a double attribute that may be stored as either a
     * {@link Number} (new native-double form, written by this class
     * and by Python/ObjC since the cross-lang parity fix) or a
     * {@link String} (legacy form written by Java prior to the fix).
     *
     * <p>Copy-pasted from {@code RamanImage} deliberately: the helper
     * is small, and cross-class coupling via a shared utility would
     * require widening the package-private API surface without
     * meaningful benefit.</p>
     */
    private static double parseDoubleAttr(Object value) {
        if (value instanceof Number n) return n.doubleValue();
        return Double.parseDouble((String) value);
    }

    /**
     * Parse an {@code ir_mode} attribute that may be stored as either
     * a {@link Number} (new i64 enum form, 0=TRANSMITTANCE,
     * 1=ABSORBANCE — matches Python's {@code int(IRMode)}) or a
     * {@link String} (legacy form: "transmittance" / "absorbance").
     * Unknown values fall back to {@link IRMode#TRANSMITTANCE}.
     */
    private static IRMode parseIRModeAttr(Object value) {
        if (value instanceof Number n) {
            return n.longValue() == 1L ? IRMode.ABSORBANCE : IRMode.TRANSMITTANCE;
        }
        return "absorbance".equalsIgnoreCase((String) value)
                ? IRMode.ABSORBANCE : IRMode.TRANSMITTANCE;
    }
}
