/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

/**
 * mate_info v2 — CRAM-style inline mate-pair codec (codec id 13).
 *
 * <p>Spec: docs/superpowers/specs/2026-05-03-mate-info-v2-design.md
 *
 * <p>High-level API; delegates to {@link TtioRansNative#encodeMateInfoV2}
 * / {@code decodeMateInfoV2} which call the C library entries
 * {@code ttio_mate_info_v2_encode/decode}.
 *
 * <p>Inputs: parallel int[]/long[]/int[]/short[]/long[] arrays of equal
 * length. ownChromIds is short[] (Java has no unsigned 16-bit primitive;
 * (short)0xFFFF is the "unmapped own" sentinel). mateChromIds == -1
 * means the mate is unmapped (RNEXT='*'); values < -1 are rejected.
 */
public final class MateInfoV2 {

    private MateInfoV2() {}

    /** @return {@code true} iff the native JNI library loaded successfully. */
    public static boolean isAvailable() { return TtioRansNative.isAvailable(); }

    /**
     * Encode a mate triple to the inline_v2 blob.
     *
     * @throws IllegalArgumentException if input array lengths disagree, or
     *         any mateChromIds[i] < -1
     * @throws RuntimeException on native error
     */
    public static byte[] encode(
            int[]   mateChromIds,
            long[]  matePositions,
            int[]   templateLengths,
            short[] ownChromIds,
            long[]  ownPositions) {
        int n = mateChromIds.length;
        if (matePositions.length != n || templateLengths.length != n
                || ownChromIds.length != n || ownPositions.length != n) {
            throw new IllegalArgumentException(
                "all input arrays must have the same length");
        }
        for (int i = 0; i < n; i++) {
            if (mateChromIds[i] < -1) {
                throw new IllegalArgumentException(
                    "invalid mate_chrom_id at index " + i + ": "
                    + mateChromIds[i] + " (must be >= -1)");
            }
        }
        return TtioRansNative.encodeMateInfoV2(
            mateChromIds, matePositions, templateLengths,
            ownChromIds, ownPositions);
    }

    /** Decode an inline_v2 blob to a {@link Triple}. */
    public static Triple decode(
            byte[]  encoded,
            short[] ownChromIds,
            long[]  ownPositions,
            int     nRecords) {
        if (ownChromIds.length != nRecords || ownPositions.length != nRecords) {
            throw new IllegalArgumentException(
                "ownChromIds/ownPositions length must equal nRecords");
        }
        Object[] out = TtioRansNative.decodeMateInfoV2(
            encoded, ownChromIds, ownPositions, nRecords);
        return new Triple(
            (int[])  out[0],
            (long[]) out[1],
            (int[])  out[2]);
    }

    /** Decoded result tuple. */
    public static final class Triple {
        public final int[]  mateChromIds;
        public final long[] matePositions;
        public final int[]  templateLengths;
        public Triple(int[] mc, long[] mp, int[] ts) {
            this.mateChromIds = mc;
            this.matePositions = mp;
            this.templateLengths = ts;
        }
    }
}
