/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import com.dtwthalion.mpgo.Enums.SamplingMode;

/**
 * Describes a single axis of a {@link SignalArray}: its semantic name,
 * unit, numeric range, and sampling mode. Immutable value class.
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code MPGOAxisDescriptor}, Python
 * {@code mpeg_o.axis_descriptor.AxisDescriptor}.</p>
 *
 * @param name          Semantic name (e.g. {@code "mz"}).
 * @param unit          Unit label (e.g. {@code "m/z"}).
 * @param valueRange    Numeric bounds, or {@code null} when unknown.
 * @param samplingMode  Whether samples are regularly spaced.
 * @since 0.6
 */
public record AxisDescriptor(
    String name,
    String unit,
    ValueRange valueRange,
    SamplingMode samplingMode
) {}
