/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.importers;

/**
 * Raised on malformed FASTA / FASTQ input (missing header, embedded
 * null byte, header without sequence, SEQ/QUAL length mismatch).
 *
 * <p>Subclass of {@link RuntimeException} so callers don't need
 * checked-exception ceremony for parser errors. Loose-catch via
 * {@code RuntimeException} works as expected.</p>
 */
public class FastaParseException extends RuntimeException {
    public FastaParseException(String message) {
        super(message);
    }

    public FastaParseException(String message, Throwable cause) {
        super(message, cause);
    }
}
