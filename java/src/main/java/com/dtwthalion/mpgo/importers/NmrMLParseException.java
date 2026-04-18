/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo.importers;

/**
 * Thrown when an nmrML document cannot be parsed.
 *
 * <p>Corresponds to ObjC error code
 * {@code MPGONmrMLReaderErrorParseFailed} and Python
 * {@code NmrMLParseError}.</p>
 *
 * @since 0.7
 */
public final class NmrMLParseException extends MpgoReaderException {
    private static final long serialVersionUID = 1L;

    public NmrMLParseException(String message) {
        super(message);
    }

    public NmrMLParseException(String message, Throwable cause) {
        super(message, cause);
    }
}
