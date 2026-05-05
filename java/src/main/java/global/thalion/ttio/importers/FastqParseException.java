/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.importers;

/**
 * Raised on malformed FASTQ input (not a multiple of 4 lines,
 * SEQ/QUAL length mismatch, missing {@code +} separator).
 *
 * <p>Subclass of {@link FastaParseException} so callers can catch
 * either parser's errors with a single {@code catch} clause.</p>
 */
public class FastqParseException extends FastaParseException {
    public FastqParseException(String message) {
        super(message);
    }

    public FastqParseException(String message, Throwable cause) {
        super(message, cause);
    }
}
