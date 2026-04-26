/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

/**
 * QUALITY_BINNED genomic quality-score codec — Illumina-8 bin table.
 *
 * <p>Clean-room implementation matching the Python reference
 * ({@code python/src/ttio/codecs/quality.py}) byte-for-byte.
 * The 8-bin Phred quantisation table used here ("Illumina-8 /
 * CRUMBLE-style") is documented in many published sources —
 * Illumina's reduced-representation guidance, James Bonfield's
 * CRUMBLE paper (Bioinformatics 2019), HTSlib's {@code qual_quants}
 * field, NCBI SRA's {@code lossy.sra} quality binning. <b>No htslib,
 * no CRUMBLE, no SRA toolkit source consulted at any point.</b> The
 * 4-bit packing geometry is the natural choice for an 8-bin index
 * alphabet and is not derived from any reference.
 *
 * <p>Cross-language equivalents:
 * <ul>
 *   <li>Python: {@code ttio.codecs.quality}</li>
 *   <li>Objective-C: {@code TTIOQuality}</li>
 * </ul>
 *
 * <p>Wire format (big-endian throughout, self-contained):
 * <pre>
 *   Offset   Size   Field
 *   ──────   ────   ─────────────────────────────────────────────
 *   0        1      version            (0x00)
 *   1        1      scheme_id          (0x00 = "illumina-8")
 *   2        4      original_length    (uint32 BE)
 *   6        var    packed_indices     (ceil(original_length / 2) bytes)
 * </pre>
 *
 * <p>Total length = {@code 6 + ((original_length + 1) >>> 1)} bytes.
 *
 * <p>Bin table (Illumina-8; binding decisions §91, §92):
 * <pre>
 *   Bin  Phred range   Centre
 *   ───  ───────────   ──────
 *    0       0..1         0
 *    1       2..9         5
 *    2      10..19       15
 *    3      20..24       22
 *    4      25..29       27
 *    5      30..34       32
 *    6      35..39       37
 *    7     40..255       40    (saturates; binding decision §93)
 * </pre>
 *
 * <p>Bit order within byte is <b>big-endian</b> (binding decision §95) —
 * the first input quality occupies the high nibble of its body byte.
 * Padding bits in the final body byte (when {@code len(input) % 2 != 0})
 * are zero (binding decision §96); the decoder uses
 * {@code original_length} to know how many indices to consume.
 *
 * <p>Lossy round-trip (binding decision §97):
 * {@code decode(encode(x)) == bin_centre[bin_of[x]]}, NOT {@code x}.
 * For an input byte that is already a bin centre
 * (0/5/15/22/27/32/37/40), round-trip is byte-exact. For other Phred
 * values, round-trip produces the bin centre for that value's bin.
 */
public final class Quality {

    // ── Wire-format constants ───────────────────────────────────────

    /** Version byte — first byte of every QUALITY_BINNED stream. */
    private static final byte VERSION = 0x00;

    /** Scheme id for Illumina-8 — second byte of every stream. */
    private static final byte SCHEME_ILLUMINA_8 = 0x00;

    /** Header length: 1 (version) + 1 (scheme_id) + 4 (orig_len) = 6. */
    private static final int HEADER_LEN = 6;

    // ── Lookup tables (Illumina-8 scheme) ───────────────────────────

    /**
     * 256-entry table mapping each input byte to its bin index 0..7.
     * Illumina-8 boundaries per binding decision §91, §92.
     */
    private static final byte[] BIN_INDEX_TABLE = buildBinIndexTable();

    /**
     * 8-entry centre table: bin index 0..7 → output Phred byte
     * (binding decision §91). Indices outside 0..7 must not be
     * looked up against this table.
     */
    private static final byte[] CENTRE_TABLE = {0, 5, 15, 22, 27, 32, 37, 40};

    private static byte[] buildBinIndexTable() {
        byte[] tbl = new byte[256];
        for (int p = 0; p < 256; p++) {
            byte bin;
            if (p <= 1)        bin = 0;
            else if (p <= 9)   bin = 1;
            else if (p <= 19)  bin = 2;
            else if (p <= 24)  bin = 3;
            else if (p <= 29)  bin = 4;
            else if (p <= 34)  bin = 5;
            else if (p <= 39)  bin = 6;
            else               bin = 7;
            tbl[p] = bin;
        }
        return tbl;
    }

    private Quality() {
        // Utility class — non-instantiable.
    }

    // ── Public API ──────────────────────────────────────────────────

    /**
     * Encode {@code data} (Phred score bytes) using QUALITY_BINNED.
     *
     * <p>Maps each input byte through the Illumina-8 bin table, packs
     * bin indices 4-bits-per-index (big-endian within byte: first
     * input quality in the high nibble). Returns a self-contained byte
     * array per the wire format in this class's javadoc.
     *
     * <p>Lossy: round-trip via bin centres.
     * {@code decode(encode(x)) == bin_centre[bin_of[x]]} for each byte.
     *
     * @param data input bytes — Phred quality scores. Any byte value
     *             0..255 is accepted; values &gt; 40 saturate to bin 7
     *             (centre 40). Must not be {@code null}.
     * @return encoded stream of length
     *         {@code 6 + ((data.length + 1) >>> 1)}.
     * @throws IllegalArgumentException if {@code data} is null.
     */
    public static byte[] encode(byte[] data) {
        if (data == null) {
            throw new IllegalArgumentException(
                "QUALITY_BINNED encode: data must not be null");
        }
        int origLen = data.length;
        int bodyLen = (origLen + 1) >>> 1;
        byte[] out = new byte[HEADER_LEN + bodyLen];

        // Header: version + scheme_id + orig_len (uint32 BE).
        out[0] = VERSION;
        out[1] = SCHEME_ILLUMINA_8;
        writeUInt32BE(out, 2, origLen);

        // Body: pack two bin indices per byte, big-endian within byte
        // (first index → high nibble; binding decision §95). For
        // odd-length input the final low nibble is the zero padding
        // (binding decision §96).
        int bodyOff = HEADER_LEN;
        int i = 0;
        int fullPairs = origLen >>> 1;
        for (int pair = 0; pair < fullPairs; pair++) {
            // Byte.toUnsignedInt is required (gotcha §107): Phred 200+
            // would otherwise sign-extend negative and crash the table
            // lookup index.
            int hi = BIN_INDEX_TABLE[Byte.toUnsignedInt(data[i    ])] & 0x0F;
            int lo = BIN_INDEX_TABLE[Byte.toUnsignedInt(data[i + 1])] & 0x0F;
            out[bodyOff++] = (byte) ((hi << 4) | lo);
            i += 2;
        }
        // Tail: 1 leftover byte → high nibble = bin index, low nibble = 0.
        if ((origLen & 1) != 0) {
            int hi = BIN_INDEX_TABLE[Byte.toUnsignedInt(data[i])] & 0x0F;
            out[bodyOff] = (byte) (hi << 4);
        }

        return out;
    }

    /**
     * Decode a stream produced by {@link #encode(byte[])}.
     *
     * <p>Reads the header, unpacks the 4-bit bin indices from the
     * body, maps each through the bin-centre table to produce output
     * Phred bytes. Validates strictly: the version byte, the
     * scheme_id, and the total stream length against
     * {@code original_length}.
     *
     * <p>Header validation order: length check first (&lt; 6 → too
     * short), then version byte, then scheme_id, then total length
     * match. This mirrors the Python reference.
     *
     * <p>Body nibbles 8..15 are silently treated as centre 0 (no
     * per-nibble validation). The encoder never produces nibbles &gt;= 8;
     * this matches Python's "trust the producer" policy.
     *
     * @param encoded encoded stream.
     * @return decoded Phred bytes of length {@code original_length}.
     *         Each byte is the bin centre for the corresponding input
     *         byte's bin (lossy by construction; binding decision §97).
     * @throws IllegalArgumentException if the stream is shorter than
     *         the 6-byte header, has a bad version byte, has a bad
     *         scheme_id, or has a body length that does not match
     *         {@code ceil(original_length / 2)}.
     */
    public static byte[] decode(byte[] encoded) {
        if (encoded == null) {
            throw new IllegalArgumentException(
                "QUALITY_BINNED decode: input must not be null");
        }
        if (encoded.length < HEADER_LEN) {
            throw new IllegalArgumentException(
                "QUALITY_BINNED stream too short for header: "
                    + encoded.length + " < " + HEADER_LEN);
        }

        int version = Byte.toUnsignedInt(encoded[0]);
        if (version != (VERSION & 0xFF)) {
            throw new IllegalArgumentException(
                "QUALITY_BINNED bad version byte: 0x"
                    + String.format("%02x", version) + " (expected 0x00)");
        }

        int schemeId = Byte.toUnsignedInt(encoded[1]);
        if (schemeId != (SCHEME_ILLUMINA_8 & 0xFF)) {
            throw new IllegalArgumentException(
                "QUALITY_BINNED unknown scheme_id: 0x"
                    + String.format("%02x", schemeId)
                    + " (only 0x00 = 'illumina-8' is defined)");
        }

        long origLenU = readUInt32BE(encoded, 2);
        if (origLenU > Integer.MAX_VALUE) {
            throw new IllegalArgumentException(
                "QUALITY_BINNED declared original_length too large: "
                    + origLenU);
        }
        int origLen = (int) origLenU;

        int expectedBodyLen = (origLen + 1) >>> 1;
        long expectedTotal = (long) HEADER_LEN + expectedBodyLen;
        if (encoded.length != expectedTotal) {
            throw new IllegalArgumentException(
                "QUALITY_BINNED stream length mismatch: " + encoded.length
                    + " != " + expectedTotal + " (header " + HEADER_LEN
                    + " + body ceil(" + origLen + "/2) = "
                    + expectedBodyLen + ")");
        }

        if (origLen == 0) {
            return new byte[0];
        }

        // Unpack body. High nibble of each byte → output position 2k;
        // low nibble → output position 2k+1 (binding decision §95).
        // For odd-length input the final low nibble is zero padding
        // (binding decision §96) which we drop by capping the loop.
        byte[] out = new byte[origLen];
        int bodyOff = HEADER_LEN;
        int fullPairs = origLen >>> 1;
        int o = 0;
        for (int pair = 0; pair < fullPairs; pair++) {
            int b = Byte.toUnsignedInt(encoded[bodyOff + pair]);
            out[o    ] = nibbleToCentre((b >>> 4) & 0x0F);
            out[o + 1] = nibbleToCentre(b & 0x0F);
            o += 2;
        }
        if ((origLen & 1) != 0) {
            int b = Byte.toUnsignedInt(encoded[bodyOff + fullPairs]);
            out[o] = nibbleToCentre((b >>> 4) & 0x0F);
            // The low nibble is the zero-padding centre and is dropped.
        }

        return out;
    }

    // ── Internal helpers ────────────────────────────────────────────

    /**
     * Map a 4-bit nibble (0..15) to its bin centre. Nibbles 0..7 hit
     * the Illumina-8 centres; nibbles 8..15 are unreachable from a
     * well-formed stream and silently map to centre 0 (mirrors the
     * Python decoder's nibble-table behaviour).
     */
    private static byte nibbleToCentre(int nibble) {
        if (nibble < 8) {
            return CENTRE_TABLE[nibble];
        }
        return 0;
    }

    private static void writeUInt32BE(byte[] buf, int off, int val) {
        buf[off]     = (byte) ((val >>> 24) & 0xFF);
        buf[off + 1] = (byte) ((val >>> 16) & 0xFF);
        buf[off + 2] = (byte) ((val >>> 8) & 0xFF);
        buf[off + 3] = (byte) (val & 0xFF);
    }

    private static long readUInt32BE(byte[] buf, int off) {
        return ((long) Byte.toUnsignedInt(buf[off])     << 24)
             | ((long) Byte.toUnsignedInt(buf[off + 1]) << 16)
             | ((long) Byte.toUnsignedInt(buf[off + 2]) << 8)
             | ((long) Byte.toUnsignedInt(buf[off + 3]));
    }
}
