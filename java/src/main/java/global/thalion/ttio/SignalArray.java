/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
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

    public Object buffer() { return buffer; }
    public int length() { return length; }
    public EncodingSpec encoding() { return encoding; }
    public AxisDescriptor axis() { return axis; }

    /** @return an unmodifiable view of the CV annotations list. */
    public List<CVParam> cvParams() { return Collections.unmodifiableList(cvParams); }

    public double[] asDoubles() {
        if (buffer instanceof double[] d) return d;
        throw new ClassCastException("buffer is not double[]");
    }

    public float[] asFloats() {
        if (buffer instanceof float[] f) return f;
        throw new ClassCastException("buffer is not float[]");
    }

    public int[] asInts() {
        if (buffer instanceof int[] i) return i;
        throw new ClassCastException("buffer is not int[]");
    }

    public long[] asLongs() {
        if (buffer instanceof long[] l) return l;
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
