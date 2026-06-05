/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.*;
import global.thalion.ttio.protocols.CVAnnotatable;
import java.util.*;

/**
 * The atomic unit of measured signal in TTI-O. A {@code SignalArray} is a
 * typed numeric buffer with an encoding spec, an optional axis descriptor,
 * and an arbitrary number of CV annotations.
 *
 * <p>CV annotations are mutable: use {@link #addCvParam}, {@link #removeCvParam},
 * and the query methods from {@link CVAnnotatable}. The {@link #cvParams()}
 * accessor returns an unmodifiable view; mutate only through the
 * {@code CVAnnotatable} methods.</p>
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b><br>
 * Python: {@code ttio.signal_array.SignalArray}<br>
 * Objective-C: {@code TTIOSignalArray}</p>
 *
 *
 */
public class SignalArray implements CVAnnotatable {
    private final Object buffer;  // float[], double[], int[], long[], or byte[]
    private final int length;
    private final EncodingSpec encoding;
    private final AxisDescriptor axis;      // nullable
    private final ArrayList<CVParam> cvParams;

    /**
     * Primary constructor.
     *
     * @param buffer   backing array ({@code float[]}, {@code double[]},
     *                 {@code int[]}, {@code long[]}, or {@code byte[]})
     * @param length   logical element count (may be shorter than the
     *                 raw backing array when the buffer is shared)
     * @param encoding precision/compression/byte-order descriptor
     * @param axis     optional axis descriptor for this array; may be
     *                 {@code null} for unlabelled buffers
     * @param cvParams optional CV annotations; null is treated as an
     *                 empty list. Defensively copied.
     */
    public SignalArray(Object buffer, int length, EncodingSpec encoding,
                       AxisDescriptor axis, List<CVParam> cvParams) {
        this.buffer = buffer;
        this.length = length;
        this.encoding = encoding;
        this.axis = axis;
        this.cvParams = cvParams != null
            ? new ArrayList<>(cvParams)
            : new ArrayList<>();
    }

    // ------------------------------------------------------------------
    // Convenience constructors
    // ------------------------------------------------------------------

    /** Create from {@code double[]} with default FLOAT64/ZLIB/LE encoding. */
    public static SignalArray ofDoubles(double[] data) {
        return new SignalArray(data, data.length,
            new EncodingSpec(Precision.FLOAT64, Compression.ZLIB, ByteOrder.LITTLE_ENDIAN),
            null, null);
    }

    /** Create from {@code float[]} with default FLOAT32/ZLIB/LE encoding. */
    public static SignalArray ofFloats(float[] data) {
        return new SignalArray(data, data.length,
            new EncodingSpec(Precision.FLOAT32, Compression.ZLIB, ByteOrder.LITTLE_ENDIAN),
            null, null);
    }

    // ------------------------------------------------------------------
    // Accessors
    // ------------------------------------------------------------------

    /** @return The raw backing array; caller must cast to the type matching {@link #encoding()}. */
    public Object buffer() { return buffer; }

    /** @return Logical element count of the array. */
    public int length() { return length; }

    /** @return The encoding descriptor (precision, compression, byte order). */
    public EncodingSpec encoding() { return encoding; }

    /** @return Optional axis descriptor (label, unit, spacing); {@code null} when unlabelled. */
    public AxisDescriptor axis() { return axis; }

    /** @return an unmodifiable view of the CV annotations list. */
    public List<CVParam> cvParams() { return Collections.unmodifiableList(cvParams); }

    /**
     * @return a defensive copy of the backing array as {@code double[]}.
     * @throws ClassCastException when the buffer is not a {@code double[]}
     */
    public double[] asDoubles() {
        if (buffer instanceof double[] d) return d.clone();
        throw new ClassCastException("buffer is not double[]");
    }

    /**
     * @return a defensive copy of the backing array as {@code float[]}.
     * @throws ClassCastException when the buffer is not a {@code float[]}
     */
    public float[] asFloats() {
        if (buffer instanceof float[] f) return f.clone();
        throw new ClassCastException("buffer is not float[]");
    }

    /**
     * @return a defensive copy of the backing array as {@code int[]}.
     * @throws ClassCastException when the buffer is not an {@code int[]}
     */
    public int[] asInts() {
        if (buffer instanceof int[] i) return i.clone();
        throw new ClassCastException("buffer is not int[]");
    }

    /**
     * @return a defensive copy of the backing array as {@code long[]}.
     * @throws ClassCastException when the buffer is not a {@code long[]}
     */
    public long[] asLongs() {
        if (buffer instanceof long[] l) return l.clone();
        throw new ClassCastException("buffer is not long[]");
    }

    // ------------------------------------------------------------------
    // CVAnnotatable
    // ------------------------------------------------------------------

    /** {@inheritDoc} */
    @Override
    public void addCvParam(CVParam param) {
        cvParams.add(param);
    }

    /** {@inheritDoc} */
    @Override
    public void removeCvParam(CVParam param) {
        cvParams.remove(param);
    }

    /** {@inheritDoc} */
    @Override
    public List<CVParam> allCvParams() {
        return Collections.unmodifiableList(cvParams);
    }

    /** {@inheritDoc} */
    @Override
    public List<CVParam> cvParamsForAccession(String accession) {
        List<CVParam> result = new ArrayList<>();
        for (CVParam p : cvParams) {
            if (accession.equals(p.accession())) result.add(p);
        }
        return Collections.unmodifiableList(result);
    }

    /** {@inheritDoc} */
    @Override
    public List<CVParam> cvParamsForOntologyRef(String ontologyRef) {
        List<CVParam> result = new ArrayList<>();
        for (CVParam p : cvParams) {
            if (ontologyRef.equals(p.ontologyRef())) result.add(p);
        }
        return Collections.unmodifiableList(result);
    }

    /** {@inheritDoc} */
    @Override
    public boolean hasCvParamWithAccession(String accession) {
        for (CVParam p : cvParams) {
            if (accession.equals(p.accession())) return true;
        }
        return false;
    }
}
