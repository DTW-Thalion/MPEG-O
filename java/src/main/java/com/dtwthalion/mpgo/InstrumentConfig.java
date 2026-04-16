/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

public record InstrumentConfig(
    String manufacturer, String model, String serialNumber,
    String sourceType, String analyzerType, String detectorType) {}
