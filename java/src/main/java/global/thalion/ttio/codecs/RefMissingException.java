/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

/**
 * Raised when a reference required for REF_DIFF decode cannot be resolved.
 *
 * <p>Per the M93 design spec Q5c: hard error rather than partial decode.
 * Genomic data integrity is non-negotiable.
 *
 * <p>Cross-language equivalents:
 * <ul>
 *   <li>Python: {@code ttio.genomic.reference_resolver.RefMissingError}</li>
 *   <li>Objective-C: {@code TTIORefMissingError}</li>
 * </ul>
 */
public class RefMissingException extends RuntimeException {

    private static final long serialVersionUID = 1L;

    public RefMissingException(String message) {
        super(message);
    }

    public RefMissingException(String message, Throwable cause) {
        super(message, cause);
    }
}
