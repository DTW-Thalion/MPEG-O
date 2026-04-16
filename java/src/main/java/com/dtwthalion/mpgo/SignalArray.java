/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import com.dtwthalion.mpgo.Enums.*;
import java.util.*;

public class SignalArray {
    private final Object buffer;  // float[], double[], int[], long[], or byte[]
    private final int length;
    private final EncodingSpec encoding;
    private final AxisDescriptor axis;      // nullable
    private final List<CVParam> cvParams;   // empty if none

    public SignalArray(Object buffer, int length, EncodingSpec encoding,
                       AxisDescriptor axis, List<CVParam> cvParams) {
        this.buffer = buffer;
        this.length = length;
        this.encoding = encoding;
        this.axis = axis;
        this.cvParams = cvParams != null ? List.copyOf(cvParams) : List.of();
    }

    // Convenience: create from double[]
    public static SignalArray ofDoubles(double[] data) {
        return new SignalArray(data, data.length,
            new EncodingSpec(Precision.FLOAT64, Compression.ZLIB, ByteOrder.LITTLE_ENDIAN),
            null, null);
    }

    public static SignalArray ofFloats(float[] data) {
        return new SignalArray(data, data.length,
            new EncodingSpec(Precision.FLOAT32, Compression.ZLIB, ByteOrder.LITTLE_ENDIAN),
            null, null);
    }

    public Object buffer() { return buffer; }
    public int length() { return length; }
    public EncodingSpec encoding() { return encoding; }
    public AxisDescriptor axis() { return axis; }
    public List<CVParam> cvParams() { return cvParams; }

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
}
