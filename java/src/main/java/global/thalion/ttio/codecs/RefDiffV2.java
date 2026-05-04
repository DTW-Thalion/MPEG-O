/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

/**
 * REF_DIFF v2 — CRAM-style bit-packed sequence diff codec (codec id 14).
 *
 * <p>Spec: docs/superpowers/specs/2026-05-03-ref-diff-v2-design.md
 *
 * <p>High-level API; delegates to {@link TtioRansNative#encodeRefDiffV2} /
 * {@link TtioRansNative#decodeRefDiffV2} which call the C library
 * entries {@code ttio_ref_diff_v2_encode/decode}.
 */
public final class RefDiffV2 {

    private RefDiffV2() {}

    /** @return {@code true} iff the native JNI library loaded successfully. */
    public static boolean isAvailable() { return TtioRansNative.isAvailable(); }

    /**
     * Encode a slice of reads to the refdiff_v2 blob.
     *
     * @param sequences        concatenated read bases (ACGTN ASCII)
     * @param offsets          n_reads + 1 entries, per-read start in sequences[]
     * @param positions        per-read 1-based reference position
     * @param cigarStrings     per-read CIGAR
     * @param reference        reference chromosome bytes
     * @param referenceMd5     16-byte MD5 of the reference
     * @param referenceUri     UTF-8 reference URI
     * @param readsPerSlice    typically 10000
     * @throws IllegalArgumentException if input constraints are violated
     * @throws RuntimeException on native error
     */
    public static byte[] encode(
            byte[]   sequences,
            long[]   offsets,
            long[]   positions,
            String[] cigarStrings,
            byte[]   reference,
            byte[]   referenceMd5,
            String   referenceUri,
            int      readsPerSlice) {
        if (referenceMd5 == null || referenceMd5.length != 16)
            throw new IllegalArgumentException("referenceMd5 must be 16 bytes");
        int n = positions.length;
        if (offsets.length != n + 1)
            throw new IllegalArgumentException("offsets length must be n_reads + 1");
        if (cigarStrings.length != n)
            throw new IllegalArgumentException("cigarStrings length must be n_reads");
        return TtioRansNative.encodeRefDiffV2(sequences, offsets, positions,
                                               cigarStrings, reference,
                                               referenceMd5, referenceUri,
                                               readsPerSlice);
    }

    /**
     * Decode a refdiff_v2 blob to (sequences, offsets).
     *
     * @param encoded      blob produced by {@link #encode}
     * @param positions    per-read 1-based reference position (same as encode)
     * @param cigarStrings per-read CIGAR (same as encode)
     * @param reference    reference chromosome bytes
     * @param nReads       number of reads
     * @param totalBases   total number of bases across all reads
     * @return {@link Pair} containing decoded sequences and offsets arrays
     * @throws IllegalArgumentException if input constraints are violated
     * @throws RuntimeException on native error
     */
    public static Pair decode(
            byte[]   encoded,
            long[]   positions,
            String[] cigarStrings,
            byte[]   reference,
            int      nReads,
            long     totalBases) {
        if (positions.length != nReads)
            throw new IllegalArgumentException("positions length must equal nReads");
        if (cigarStrings.length != nReads)
            throw new IllegalArgumentException("cigarStrings length must equal nReads");
        Object[] out = TtioRansNative.decodeRefDiffV2(encoded, positions,
                                                      cigarStrings, reference,
                                                      nReads, totalBases);
        return new Pair((byte[]) out[0], (long[]) out[1]);
    }

    /** Decoded result pair: concatenated sequences and offset table. */
    public static final class Pair {
        public final byte[] sequences;
        public final long[] offsets;

        public Pair(byte[] sequences, long[] offsets) {
            this.sequences = sequences;
            this.offsets = offsets;
        }
    }
}
