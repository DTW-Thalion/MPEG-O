/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import com.dtwthalion.mpgo.Enums.*;

/**
 * NMR free-induction decay. Subclass of {@link SignalArray} using
 * Complex128 precision (interleaved real/imag doubles) plus
 * FID-specific acquisition metadata: dwell time, scan count,
 * receiver gain.
 *
 * <p>Length is the number of complex points (half the number of
 * doubles in the buffer).</p>
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code MPGOFreeInductionDecay}, Python
 * {@code mpeg_o.fid.FreeInductionDecay}.</p>
 *
 * @since 0.6
 */
public class FreeInductionDecay extends SignalArray {
    private final int scanCount;
    private final double dwellTimeSeconds;
    private final double receiverGain;

    public FreeInductionDecay(double[] complexData, int scanCount,
                              double dwellTimeSeconds, double receiverGain) {
        super(complexData, scanCount,
            new EncodingSpec(Precision.COMPLEX128, Compression.ZLIB, ByteOrder.LITTLE_ENDIAN),
            null, null);
        this.scanCount = scanCount;
        this.dwellTimeSeconds = dwellTimeSeconds;
        this.receiverGain = receiverGain;
    }

    public double[] complexData() { return asDoubles(); }
    public int scanCount() { return scanCount; }
    public double dwellTimeSeconds() { return dwellTimeSeconds; }
    public double receiverGain() { return receiverGain; }

    public double realAt(int i) { return ((double[]) buffer())[i * 2]; }
    public double imagAt(int i) { return ((double[]) buffer())[i * 2 + 1]; }
}
