/* MPEG-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: Apache-2.0 */
package com.dtwthalion.mpgo.exporters;

/**
 * JCAMP-DX 5.01 {@code ##XYDATA=(X++(Y..Y))} encoding modes supported
 * by {@link JcampDxWriter}.
 *
 * <p>{@link #AFFN} emits one free-format {@code (X, Y)} pair per line —
 * the default and the only mode available prior to M76. {@link #PAC},
 * {@link #SQZ}, {@link #DIF} emit the JCAMP-DX 5.01 §5.9 compressed
 * forms; equispaced X is required and a shared YFACTOR is chosen to
 * carry ~7 significant digits of integer-scaled Y precision.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code MPGOJcampDxEncoding} &middot; Python {@code encoding="..."}
 * keyword on {@code mpeg_o.exporters.jcamp_dx.write_*_spectrum}.</p>
 *
 * @since 0.12
 */
public enum JcampDxEncoding {
    AFFN, PAC, SQZ, DIF;

    /** Map a case-insensitive name (e.g. {@code "pac"}) to its enum value. */
    public static JcampDxEncoding fromString(String name) {
        if (name == null) {
            throw new IllegalArgumentException("encoding name is null");
        }
        switch (name.toLowerCase(java.util.Locale.ROOT)) {
            case "affn": return AFFN;
            case "pac":  return PAC;
            case "sqz":  return SQZ;
            case "dif":  return DIF;
            default:
                throw new IllegalArgumentException(
                        "unknown JCAMP-DX encoding: " + name);
        }
    }
}
