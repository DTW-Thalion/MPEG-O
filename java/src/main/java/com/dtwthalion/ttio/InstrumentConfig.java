/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio;

/**
 * Immutable instrument configuration value class.
 *
 * <p>All fields may be empty strings per format-spec §3 (every
 * sub-field is optional).</p>
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOInstrumentConfig}, Python
 * {@code ttio.instrument_config.InstrumentConfig}.</p>
 *
 * @param manufacturer Instrument manufacturer.
 * @param model        Instrument model.
 * @param serialNumber Serial number.
 * @param sourceType   Ionization source type.
 * @param analyzerType Mass analyzer type.
 * @param detectorType Detector type.
 * @since 0.6
 */
public record InstrumentConfig(
    String manufacturer, String model, String serialNumber,
    String sourceType, String analyzerType, String detectorType) {}
