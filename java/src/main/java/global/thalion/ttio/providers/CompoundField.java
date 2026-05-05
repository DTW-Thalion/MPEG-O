/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.providers;

/**
 * One field inside a compound-dataset record.
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOCompoundField}, Python
 * {@code ttio.providers.base.CompoundField}.</p>
 *
 *
 */
public record CompoundField(String name, Kind kind) {

    /** Field kinds supported by the capability floor. Adding a new
     *  kind is a spec change — all providers must cover these. */
    public enum Kind {
        /** Unsigned 32-bit integer field. */
        UINT32,
        /** Signed 64-bit integer field. */
        INT64,
        /** 64-bit IEEE 754 floating-point field. */
        FLOAT64,
        /** Variable-length UTF-8 string field. */
        VL_STRING,
        /** Variable-length raw byte blob. v1.0: carries IV / tag /
         *  ciphertext for opt_per_au_encryption. */
        VL_BYTES
    }
}
