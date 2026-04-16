/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import java.util.*;

public class Spectrum {
    private final Map<String, SignalArray> signalArrays;
    private final int indexPosition;
    private final double scanTimeSeconds;

    public Spectrum(Map<String, SignalArray> signalArrays, int indexPosition, double scanTimeSeconds) {
        this.signalArrays = signalArrays != null ? Map.copyOf(signalArrays) : Map.of();
        this.indexPosition = indexPosition;
        this.scanTimeSeconds = scanTimeSeconds;
    }

    public Map<String, SignalArray> signalArrays() { return signalArrays; }
    public SignalArray signalArray(String name) { return signalArrays.get(name); }
    public int indexPosition() { return indexPosition; }
    public double scanTimeSeconds() { return scanTimeSeconds; }
}
