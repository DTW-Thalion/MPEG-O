/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio.importers;

/**
 * Thrown when the ThermoRawFileParser delegation fails: binary not
 * found, unsupported {@code .raw} file, or conversion produces
 * unparseable mzML.
 *
 * <p>Corresponds to ObjC error code {@code TTIOThermoRawErrorConvert}
 * and Python {@code ThermoRawError}.</p>
 *
 * @since 0.7
 */
public final class ThermoRawException extends TtioReaderException {
    private static final long serialVersionUID = 1L;

    public ThermoRawException(String message) {
        super(message);
    }

    public ThermoRawException(String message, Throwable cause) {
        super(message, cause);
    }
}
