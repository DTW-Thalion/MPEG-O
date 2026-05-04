/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import java.util.Arrays;
import java.util.List;

/**
 * NAME_TOKENIZED v2 (codec id 15) — column-aware tokenised read-name codec.
 *
 * <p>Spec: docs/superpowers/specs/2026-05-04-name-tokenized-v2-design.md
 *
 * <p>Thin wrapper over the JNI bridge in {@link TtioRansNative}. List inputs
 * are converted to {@code String[]} once at the API boundary; everything
 * else happens in C (libttio_rans).
 */
public final class NameTokenizerV2 {
    private NameTokenizerV2() {}

    /**
     * Encode a list of read names to a NAME_TOKENIZED v2 wire-format blob.
     *
     * @param names ASCII read names (one entry per read)
     * @return encoded blob; first 4 bytes are magic {@code "NTK2"}
     * @throws IllegalArgumentException if {@code names} is null
     */
    public static byte[] encode(List<String> names) {
        if (names == null) throw new IllegalArgumentException("names null");
        return TtioRansNative.encodeNameTokV2Native(names.toArray(new String[0]));
    }

    /**
     * Decode a NAME_TOKENIZED v2 blob to a list of read names.
     *
     * @param blob encoded blob produced by {@link #encode}
     * @return recovered read names in original order
     * @throws IllegalArgumentException if {@code blob} is null or shorter than
     *                                  the 12-byte minimum header
     */
    public static List<String> decode(byte[] blob) {
        if (blob == null || blob.length < 12) {
            throw new IllegalArgumentException("blob too short");
        }
        return Arrays.asList(TtioRansNative.decodeNameTokV2Native(blob));
    }

    /** @return identifier for the active backend (always native via JNI). */
    public static String getBackendName() {
        return "native-jni";
    }

    /** @return {@code true} iff the libttio_rans JNI library is loadable. */
    public static boolean isAvailable() { return TtioRansNative.isAvailable(); }
}
