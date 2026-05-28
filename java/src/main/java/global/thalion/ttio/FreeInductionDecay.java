/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.*;

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
 * {@code TTIOFreeInductionDecay}, Python
 * {@code ttio.fid.FreeInductionDecay}.</p>
 *
 *
 */
public class FreeInductionDecay extends SignalArray {
    private final int scanCount;
    private final double dwellTimeSeconds;
    private final double receiverGain;

    /**
     * Construct an FID from interleaved real/imaginary samples.
     *
     * @param complexData      interleaved {@code [re0, im0, re1, im1, ...]} samples
     * @param scanCount        number of complex samples; {@code complexData.length == 2 * scanCount}
     * @param dwellTimeSeconds time between consecutive samples in seconds
     * @param receiverGain     receiver gain factor recorded by the spectrometer
     */
    public FreeInductionDecay(double[] complexData, int scanCount,
                              double dwellTimeSeconds, double receiverGain) {
        super(complexData, scanCount,
            new EncodingSpec(Precision.COMPLEX128, Compression.ZLIB, ByteOrder.LITTLE_ENDIAN),
            null, null);
        this.scanCount = scanCount;
        this.dwellTimeSeconds = dwellTimeSeconds;
        this.receiverGain = receiverGain;
    }

    /** @return Interleaved real/imaginary FID samples as {@code [re, im, re, im, ...]}. */
    public double[] complexData() { return asDoubles(); }

    /** @return Number of complex samples in the FID. */
    public int scanCount() { return scanCount; }

    /** @return Dwell time (sample spacing) in seconds. */
    public double dwellTimeSeconds() { return dwellTimeSeconds; }

    /** @return Receiver gain factor recorded at acquisition time. */
    public double receiverGain() { return receiverGain; }

    /**
     * @param i sample index in {@code [0, scanCount)}
     * @return  real component of complex sample {@code i}
     */
    public double realAt(int i) { return ((double[]) buffer())[i * 2]; }

    /**
     * @param i sample index in {@code [0, scanCount)}
     * @return  imaginary component of complex sample {@code i}
     */
    public double imagAt(int i) { return ((double[]) buffer())[i * 2 + 1]; }
}
