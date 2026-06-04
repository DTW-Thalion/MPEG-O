/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.ImageKind;
import global.thalion.ttio.Enums.SpectralAxisKind;

import java.util.List;

/**
 * Shared base for the three spatial image-cube modalities
 * ({@link MSImage}, {@link RamanImage}, {@link IRImage}).
 *
 * <p>Holds the fields common to all three — the spatial grid
 * ({@code width}, {@code height}), the spectral depth
 * ({@code spectralPoints}), chunking ({@code tileSize}), pixel pitch
 * ({@code pixelSizeX}, {@code pixelSizeY}), the {@code scanPattern}
 * label, the flat row-major {@code intensityCube}, and the
 * dataset-level annotation block ({@code title},
 * {@code isaInvestigationId}, identifications, quantifications and
 * provenance records).</p>
 *
 * <p>The distinct spectral axis (m/z for MS, wavenumbers for Raman/IR)
 * and any modality-specific metadata remain on the subclasses, which
 * also own their on-disk group name and {@code writeTo}/{@code readFrom}
 * I/O. Subclasses expose the axis through {@link #spectralAxis()} and
 * declare their modality via {@link #kind()} /
 * {@link #spectralAxisKind()}.</p>
 *
 * <p><b>API status:</b> Stable.</p>
 */
public abstract class Image {

    /** Image width in pixels. */
    protected final int width;
    /** Image height in pixels. */
    protected final int height;
    /** Number of points along the spectral axis. */
    protected final int spectralPoints;
    /** HDF5 chunk side; 0 means full-image chunking. */
    protected final int tileSize;
    /** Pixel pitch in micrometres along X. */
    protected final double pixelSizeX;
    /** Pixel pitch in micrometres along Y. */
    protected final double pixelSizeY;
    /** Free-form scan-pattern label. */
    protected final String scanPattern;
    /** Row-major intensity cube of shape {@code [height, width, spectralPoints]}. */
    protected final double[] intensityCube;
    /** Study title (never null; empty when unset). */
    protected final String title;
    /** ISA investigation identifier (never null; empty when unset). */
    protected final String isaInvestigationId;
    /** Unmodifiable list of dataset-level identifications. */
    protected final List<Identification> identifications;
    /** Unmodifiable list of dataset-level quantifications. */
    protected final List<Quantification> quantifications;
    /** Unmodifiable list of dataset-level provenance records. */
    protected final List<ProvenanceRecord> provenanceRecords;

    /**
     * Common constructor invoked by every subclass via {@code super(...)}.
     * Applies the same null-normalisation and defensive copies the
     * subclasses previously performed inline.
     */
    protected Image(int width, int height, int spectralPoints, int tileSize,
                    double pixelSizeX, double pixelSizeY, String scanPattern,
                    double[] intensityCube, String title, String isaInvestigationId,
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

    /** @return Image width in pixels. */
    public int width() { return width; }

    /** @return Image height in pixels. */
    public int height() { return height; }

    /** @return Number of points along the spectral axis. */
    public int spectralPoints() { return spectralPoints; }

    /** @return HDF5 chunk side for storage; 0 means full-image chunking. */
    public int tileSize() { return tileSize; }

    /** @return Pixel pitch in micrometres along X. */
    public double pixelSizeX() { return pixelSizeX; }

    /** @return Pixel pitch in micrometres along Y. */
    public double pixelSizeY() { return pixelSizeY; }

    /** @return Free-form scan-pattern label (e.g. {@code "raster"}, {@code "random"}). */
    public String scanPattern() { return scanPattern; }

    /** @return Row-major intensity cube of shape {@code [height, width, spectralPoints]}. */
    public double[] intensityCube() { return intensityCube; }

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

    /** Intensity at pixel ({@code row}, {@code col}), spectral index {@code s}. */
    public double valueAt(int row, int col, int s) {
        return intensityCube[(row * width + col) * spectralPoints + s];
    }

    /** Full spectrum at pixel ({@code row}, {@code col}) as a fresh array. */
    public double[] spectrumAt(int row, int col) {
        int base = (row * width + col) * spectralPoints;
        double[] result = new double[spectralPoints];
        System.arraycopy(intensityCube, base, result, 0, spectralPoints);
        return result;
    }

    /** @return the modality of this image cube. */
    public abstract ImageKind kind();

    /** @return the per-band spectral axis (m/z for MS, wavenumbers for Raman/IR). */
    public abstract double[] spectralAxis();

    /** @return the physical interpretation of {@link #spectralAxis()}. */
    public abstract SpectralAxisKind spectralAxisKind();
}
