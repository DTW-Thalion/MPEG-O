/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio.importers;

import java.io.IOException;

/**
 * Base type for importer failures (mzML, nmrML, Thermo RAW).
 *
 * <p>Extends {@link IOException} so that existing catch blocks for
 * generic I/O errors still work, but adds a narrower base class that
 * lets callers distinguish "the vendor file is malformed" from "the
 * operating system could not open the file." Pre-v0.7 Java threw bare
 * {@link Exception}, which forced callers to use overly broad catch
 * clauses.</p>
 *
 * <p><b>Cross-language equivalents:</b> ObjC {@code NSError} with domain
 * {@code TTIOMzMLReaderErrorDomain} (and siblings); Python
 * {@code MzMLParseError(ValueError)} &amp; sibling classes.</p>
 *
 * @since 0.7
 */
public class TtioReaderException extends IOException {
    private static final long serialVersionUID = 1L;

    public TtioReaderException(String message) {
        super(message);
    }

    public TtioReaderException(String message, Throwable cause) {
        super(message, cause);
    }
}
