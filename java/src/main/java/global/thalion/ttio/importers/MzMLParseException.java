/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.importers;

/**
 * Thrown when an mzML document cannot be parsed: malformed XML,
 * missing required elements, or unsupported schema features.
 *
 * <p>Corresponds to ObjC error code
 * {@code TTIOMzMLReaderErrorParseFailed} and Python
 * {@code MzMLParseError}.</p>
 *
 *
 */
public final class MzMLParseException extends TtioReaderException {
    private static final long serialVersionUID = 1L;

    public MzMLParseException(String message) {
        super(message);
    }

    public MzMLParseException(String message, Throwable cause) {
        super(message, cause);
    }
}
