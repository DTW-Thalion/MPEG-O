/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo.providers;

/** One field inside a compound-dataset record. */
public record CompoundField(String name, Kind kind) {

    /** Field kinds supported by the capability floor. Adding a new
     *  kind is a spec change — all providers must cover these. */
    public enum Kind { UINT32, INT64, FLOAT64, VL_STRING }
}
