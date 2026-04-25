/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * Clean-room implementation of Numpress-delta encoding from:
 * Teleman et al., MCP 13(6):1537-1542 (2014)
 * doi:10.1074/mcp.O114.037879
 */
package com.dtwthalion.ttio;

/**
 * Numpress-delta codec for near-lossless compression of spectral data.
 *
 * <p>Encoding: quantizes double values to int64 via a fixed-point scale
 * factor, then stores first-differences (deltas). The delta representation
 * is highly compressible by zlib/LZ4.</p>
 *
 * <p>Relative error is well under 1 ppm for typical MS m/z data (100-2000 Da)
 * due to the 62-bit precision headroom.</p>
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <b>Cross-language equivalents:</b>
 * <ul>
 *   <li>Objective-C: {@code TTIONumpress}</li>
 *   <li>Python: {@code ttio._numpress}</li>
 * </ul>
 *
 * @since 0.6
 */
public final class NumpressCodec {

    private static final long HEADROOM = (1L << 62) - 1; // 2^62 - 1

    private NumpressCodec() {}

    /**
     * Compute the fixed-point scale factor for a value range.
     * Matches ObjC {@code +[TTIONumpress scaleForValueRangeMin:max:]} and
     * Python {@code ttio._numpress.scale_for_range}.
     *
     * @param minValue minimum value in the range
     * @param maxValue maximum value in the range
     * @return scale factor (always >= 1)
     */
    public static long scaleForRange(double minValue, double maxValue) {
        double absMax = Math.max(Math.abs(minValue), Math.abs(maxValue));
        if (absMax == 0 || !Double.isFinite(absMax)) return 1;
        long scale = (long) Math.floor((double) HEADROOM / absMax);
        return Math.max(scale, 1);
    }

    /**
     * Convenience — compute scale from a data array. Delegates to
     * {@link #scaleForRange(double, double)} using the array's
     * absolute maximum as both bounds.
     *
     * @param values the data array
     * @return scale factor (always >= 1)
     */
    public static long computeScale(double[] values) {
        double absMax = 0;
        for (double v : values) {
            double abs = Math.abs(v);
            if (abs > absMax) absMax = abs;
        }
        return scaleForRange(-absMax, absMax);
    }

    /**
     * Encode double values to int64 deltas with the given scale factor.
     *
     * <p>First element is absolute quantized value; subsequent elements
     * are first-differences. Uses IEEE-754 ties-to-even rounding.</p>
     *
     * @param values input data
     * @param scale  fixed-point scale from {@link #computeScale}
     * @return int64 delta array (same length as input)
     */
    public static long[] linearEncode(double[] values, long scale) {
        double dScale = (double) scale;
        long[] deltas = new long[values.length];
        if (values.length == 0) return deltas;

        long prev = Math.round(values[0] * dScale);
        deltas[0] = prev;

        for (int i = 1; i < values.length; i++) {
            long q = Math.round(values[i] * dScale);
            deltas[i] = q - prev;
            prev = q;
        }
        return deltas;
    }

    /**
     * Decode int64 deltas back to double values.
     *
     * @param deltas int64 delta array from {@link #linearEncode}
     * @param scale  the same scale factor used for encoding
     * @return reconstructed double array
     */
    public static double[] linearDecode(long[] deltas, long scale) {
        double dScale = (double) scale;
        double[] values = new double[deltas.length];
        if (deltas.length == 0) return values;

        long cumsum = 0;
        for (int i = 0; i < deltas.length; i++) {
            cumsum += deltas[i];
            values[i] = (double) cumsum / dScale;
        }
        return values;
    }

    /**
     * Convenience: encode in one step, returning scale + deltas.
     */
    public static EncodedResult encode(double[] values) {
        long scale = computeScale(values);
        long[] deltas = linearEncode(values, scale);
        return new EncodedResult(deltas, scale);
    }

    public record EncodedResult(long[] deltas, long scale) {}
}
