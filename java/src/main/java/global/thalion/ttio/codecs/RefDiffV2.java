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

    /** RDF2 outer-blob magic (4 bytes). */
    private static final byte[] RDF2_MAGIC = {'R', 'D', 'F', '2'};

    /** Byte offset of the 16-byte reference MD5 in the outer blob. */
    private static final int MD5_OFFSET = 20;
    /** Byte offset of the 2-byte URI-length field in the outer blob. */
    private static final int URI_LEN_OFFSET = 36;
    /** Byte offset of the URI bytes in the outer blob (after uri_len). */
    private static final int URI_OFFSET = 38;

    /**
     * Minimal header extracted from a {@code refdiff_v2} blob.
     *
     * @param referenceMd5 16-byte MD5 of the reference chromosome.
     * @param referenceUri UTF-8 reference URI (the BAM @SQ M5 key).
     */
    public record BlobHeader(byte[] referenceMd5, String referenceUri) { }

    /**
     * Parse {@code referenceMd5} and {@code referenceUri} from the
     * outer header of a {@code refdiff_v2} blob.
     *
     * <p>The outer header layout mirrors REF_DIFF v1 but uses magic
     * {@code "RDF2"}:
     * <pre>
     *   [0:4]        magic "RDF2"
     *   [4]          version (uint8)
     *   [5:8]        reserved
     *   [8:12]       num_slices (uint32 LE)
     *   [12:20]      total_reads (uint64 LE)
     *   [20:36]      reference_md5 (16 raw bytes)
     *   [36:38]      uri_len (uint16 LE)
     *   [38:38+len]  reference_uri (UTF-8)
     * </pre>
     *
     * @param blob encoded blob produced by {@link #encode}
     * @return parsed {@link BlobHeader}
     * @throws IllegalArgumentException on bad magic or truncated header
     */
    public static BlobHeader parseBlobHeader(byte[] blob) {
        if (blob == null || blob.length < URI_OFFSET) {
            throw new IllegalArgumentException(
                "refdiff_v2 blob too short to contain a valid header");
        }
        for (int i = 0; i < 4; i++) {
            if (blob[i] != RDF2_MAGIC[i]) {
                throw new IllegalArgumentException(
                    "refdiff_v2 magic mismatch: expected 'RDF2', got "
                    + (char) blob[0] + (char) blob[1]
                    + (char) blob[2] + (char) blob[3]);
            }
        }
        byte[] md5 = new byte[16];
        System.arraycopy(blob, MD5_OFFSET, md5, 0, 16);
        int uriLen = java.nio.ByteBuffer.wrap(blob, URI_LEN_OFFSET, 2)
            .order(java.nio.ByteOrder.LITTLE_ENDIAN)
            .getShort() & 0xFFFF;
        if (blob.length < URI_OFFSET + uriLen) {
            throw new IllegalArgumentException(
                "refdiff_v2 blob truncated in reference_uri");
        }
        String uri = new String(blob, URI_OFFSET, uriLen,
            java.nio.charset.StandardCharsets.UTF_8);
        return new BlobHeader(md5, uri);
    }

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
