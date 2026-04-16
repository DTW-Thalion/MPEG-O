/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

public class FreeInductionDecay {
    private final double[] complexData; // interleaved re,im pairs (length = 2 * scanCount)
    private final int scanCount;
    private final double dwellTimeSeconds;
    private final double receiverGain;

    public FreeInductionDecay(double[] complexData, int scanCount,
                              double dwellTimeSeconds, double receiverGain) {
        this.complexData = complexData;
        this.scanCount = scanCount;
        this.dwellTimeSeconds = dwellTimeSeconds;
        this.receiverGain = receiverGain;
    }

    public double[] complexData() { return complexData; }
    public int scanCount() { return scanCount; }
    public double dwellTimeSeconds() { return dwellTimeSeconds; }
    public double receiverGain() { return receiverGain; }

    public double realAt(int i) { return complexData[i * 2]; }
    public double imagAt(int i) { return complexData[i * 2 + 1]; }
}
