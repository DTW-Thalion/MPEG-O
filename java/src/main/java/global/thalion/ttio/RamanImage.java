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
public class RamanImage extends Image {

    private static final String GROUP_NAME = "raman_image_cube";

    private final double excitationWavelengthNm;
    private final double laserPowerMw;
    private final double[] wavenumbers;

    /**
     * Full constructor capturing every cube dimension, laser metadata,
     * and study-level annotation.
     *
     * @param width                   image width in pixels
     * @param height                  image height in pixels
     * @param spectralPoints          points along the Raman shift axis
     * @param tileSize                HDF5 chunk side; 0 means full-image
     *                                chunking
     * @param pixelSizeX              pixel pitch in micrometres along X
     * @param pixelSizeY              pixel pitch in micrometres along Y
     * @param scanPattern             free-form scan-pattern label
     * @param excitationWavelengthNm  laser excitation wavelength in nm
     * @param laserPowerMw            laser power at the sample in mW
     * @param intensityCube           row-major flat cube of shape
     *                                {@code [height, width, spectralPoints]}
     * @param wavenumbers             per-band Raman-shift values
     * @param title                   study title; null becomes empty
     * @param isaInvestigationId      ISA investigation identifier; null
     *                                becomes empty
     * @param identifications         dataset-level identifications;
     *                                null becomes empty
     * @param quantifications         dataset-level quantifications;
     *                                null becomes empty
     * @param provenanceRecords       dataset-level provenance chain;
     *                                null becomes empty
     */
    public RamanImage(int width, int height, int spectralPoints, int tileSize,
                      double pixelSizeX, double pixelSizeY, String scanPattern,
                      double excitationWavelengthNm, double laserPowerMw,
                      double[] intensityCube, double[] wavenumbers,
                      String title, String isaInvestigationId,
                      List<Identification> identifications,
                      List<Quantification> quantifications,
                      List<ProvenanceRecord> provenanceRecords) {
        super(width, height, spectralPoints, tileSize,
              pixelSizeX, pixelSizeY, scanPattern, intensityCube,
              title, isaInvestigationId,
              identifications, quantifications, provenanceRecords);
        this.excitationWavelengthNm = excitationWavelengthNm;
        this.laserPowerMw = laserPowerMw;
        this.wavenumbers = wavenumbers;
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

    /** @return Laser excitation wavelength in nm. */
    public double excitationWavelengthNm() { return excitationWavelengthNm; }

    /** @return Laser power at the sample in mW. */
    public double laserPowerMw() { return laserPowerMw; }

    /** @return Per-band Raman-shift values in {@code cm^-1}. */
    public double[] wavenumbers() { return wavenumbers; }

    @Override
    public ImageKind kind() { return ImageKind.RAMAN; }

    @Override
    public double[] spectralAxis() { return wavenumbers; }

    @Override
    public SpectralAxisKind spectralAxisKind() { return SpectralAxisKind.WAVENUMBER; }

    /** Write this image cube as an HDF5 sub-group of {@code studyGroup}. */
    public void writeTo(StorageGroup studyGroup) {
        try (StorageGroup ic = studyGroup.createGroup(GROUP_NAME)) {
            ic.setAttribute("width", (long) width);
            ic.setAttribute("height", (long) height);
            ic.setAttribute("spectral_points", (long) spectralPoints);
            ic.setAttribute("pixel_size_x", Double.valueOf(pixelSizeX));
            ic.setAttribute("pixel_size_y", Double.valueOf(pixelSizeY));
            ic.setAttribute("excitation_wavelength_nm", Double.valueOf(excitationWavelengthNm));
            ic.setAttribute("laser_power_mw", Double.valueOf(laserPowerMw));
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
                    Compression.ZLIB, 6)) {
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
            double pixelSizeX = ic.hasAttribute("pixel_size_x")
                    ? parseDoubleAttr(ic.getAttribute("pixel_size_x")) : 0.0;
            double pixelSizeY = ic.hasAttribute("pixel_size_y")
                    ? parseDoubleAttr(ic.getAttribute("pixel_size_y")) : 0.0;
            double excitationWavelengthNm = ic.hasAttribute("excitation_wavelength_nm")
                    ? parseDoubleAttr(ic.getAttribute("excitation_wavelength_nm")) : 0.0;
            double laserPowerMw = ic.hasAttribute("laser_power_mw")
                    ? parseDoubleAttr(ic.getAttribute("laser_power_mw")) : 0.0;
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

    /**
     * Parse a double attribute that may be stored as either a
     * {@link Number} (new native-double form) or a {@link String}
     * (legacy form written before the PR #31 fix).
     *
     * <p>Copy-pasted from {@code MSImage} deliberately: the helper is
     * small, and cross-class coupling via a shared utility would
     * require widening the package-private API surface without
     * meaningful benefit.</p>
     */
    private static double parseDoubleAttr(Object value) {
        if (value instanceof Number n) return n.doubleValue();
        return Double.parseDouble((String) value);
    }
}