/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

/**
 * BASE_PACK genomic-sequence codec — 2-bit ACGT + sidecar mask.
 *
 * <p>Clean-room implementation matching the Python reference
 * ({@code python/src/ttio/codecs/base_pack.py}) byte-for-byte.
 * The 2-bit-per-base packing convention is decades-old prior art,
 * fundamental and ungatewayed by IP. <b>No htslib, no jbzip, no CRAM
 * tools-Java source consulted.</b> The sidecar mask layout (sparse
 * position+byte list) is a TTI-O-specific design choice — see
 * HANDOFF.md M84 §3, binding decision §80.
 *
 * <p>Cross-language equivalents:
 * <ul>
 *   <li>Python: {@code ttio.codecs.base_pack}</li>
 *   <li>Objective-C: {@code TTIOBasePack}</li>
 * </ul>
 *
 * <p>Wire format (big-endian throughout, self-contained):
 * <pre>
 *   Offset   Size   Field
 *   ──────   ────   ─────────────────────────────────────────────
 *   0        1      version            (0x00)
 *   1        4      original_length    (uint32 BE)
 *   5        4      packed_length      (uint32 BE — = ceil(orig/4))
 *   9        4      mask_count         (uint32 BE)
 *   13       var    packed_body        (packed_length bytes)
 *   13+pl    var    mask               (mask_count × 5 bytes:
 *                                          uint32 BE position,
 *                                          uint8 original_byte)
 * </pre>
 *
 * <p>Total length = {@code 13 + packed_length + 5 * mask_count} bytes.
 *
 * <p>Pack mapping (case-sensitive; binding decision §81):
 * <pre>
 *   'A' (0x41) → 0b00
 *   'C' (0x43) → 0b01
 *   'G' (0x47) → 0b10
 *   'T' (0x54) → 0b11
 *   anything else → mask entry (placeholder 0b00 in body)
 * </pre>
 *
 * <p>Bit order within byte is <b>big-endian</b> (binding decision §82) —
 * the first base in the input occupies the two highest-order bits.
 * Padding bits in the final body byte (when {@code len(input) % 4 != 0})
 * are zero (binding decision §83); the decoder uses
 * {@code original_length} to know how many slots to consume.
 *
 * <p>Mask entries are sorted ascending by position (binding decision §84);
 * the encoder emits them in input order, the decoder validates strict
 * ascending order. The first byte is {@code version = 0x00} (binding
 * decision §85), distinct from the M79 codec id {@code 0x06}.
 */
public final class BasePack {

    // ── Wire-format constants ───────────────────────────────────────

    /** Version byte — first byte of every BASE_PACK stream. */
    private static final byte VERSION = 0x00;

    /** Header length: 1 (version) + 4 (orig_len) + 4 (packed_len) + 4 (mask_count). */
    private static final int HEADER_LEN = 13;

    /** Mask entry size: uint32 BE position + uint8 original byte. */
    private static final int MASK_ENTRY_LEN = 5;

    // ── Pack lookup table ───────────────────────────────────────────

    /**
     * 256-entry table mapping every input byte to a 2-bit slot value:
     * A→0, C→1, G→2, T→3, every other byte → 0 (placeholder).
     */
    private static final byte[] PACK_TABLE = buildPackTable();

    private static byte[] buildPackTable() {
        byte[] tbl = new byte[256]; // default 0 — placeholder for non-ACGT
        tbl['A'] = 0b00;
        tbl['C'] = 0b01;
        tbl['G'] = 0b10;
        tbl['T'] = 0b11;
        return tbl;
    }

    private BasePack() {
        // Utility class — non-instantiable.
    }

    // ── Public API ──────────────────────────────────────────────────

    /**
     * Encode {@code data} using BASE_PACK + sidecar mask.
     *
     * <p>Returns a self-contained byte array per the wire format
     * described in this class's javadoc. Pure ACGT input compresses
     * to ~25% of original size plus a 13-byte header; non-ACGT bytes
     * round-trip losslessly via the mask.
     *
     * @param data input bytes (may be empty); {@code null} not allowed.
     * @return encoded stream of length
     *         {@code 13 + ceil(len(data)/4) + 5 * mask_count}.
     * @throws IllegalArgumentException if {@code data} is null.
     */
    public static byte[] encode(byte[] data) {
        if (data == null) {
            throw new IllegalArgumentException("BASE_PACK encode: data must not be null");
        }
        int origLen = data.length;
        int packedLen = (origLen + 3) >>> 2;

        // First pass: count mask entries (non-ACGT bytes).
        int maskCount = 0;
        for (int i = 0; i < origLen; i++) {
            int b = Byte.toUnsignedInt(data[i]);
            if (b != 'A' && b != 'C' && b != 'G' && b != 'T') {
                maskCount++;
            }
        }

        int total = HEADER_LEN + packedLen + MASK_ENTRY_LEN * maskCount;
        byte[] out = new byte[total];

        // Header: version + orig_len + packed_len + mask_count.
        out[0] = VERSION;
        writeUInt32BE(out, 1, origLen);
        writeUInt32BE(out, 5, packedLen);
        writeUInt32BE(out, 9, maskCount);

        // Body: pack 4 slot values per byte, big-endian within byte.
        // The pack table maps non-ACGT to placeholder 0b00; the mask
        // section recovers the true bytes during decode.
        int bodyOff = HEADER_LEN;
        int i = 0;
        int fullChunks = origLen >>> 2;
        for (int chunk = 0; chunk < fullChunks; chunk++) {
            int s0 = PACK_TABLE[Byte.toUnsignedInt(data[i    ])] & 0xFF;
            int s1 = PACK_TABLE[Byte.toUnsignedInt(data[i + 1])] & 0xFF;
            int s2 = PACK_TABLE[Byte.toUnsignedInt(data[i + 2])] & 0xFF;
            int s3 = PACK_TABLE[Byte.toUnsignedInt(data[i + 3])] & 0xFF;
            out[bodyOff++] = (byte) ((s0 << 6) | (s1 << 4) | (s2 << 2) | s3);
            i += 4;
        }
        // Tail (1, 2, or 3 leftover bases). Padding slots are zero
        // (binding decision §83).
        int tail = origLen - (fullChunks << 2);
        if (tail > 0) {
            int s0 = PACK_TABLE[Byte.toUnsignedInt(data[i])] & 0xFF;
            int s1 = (tail >= 2) ? (PACK_TABLE[Byte.toUnsignedInt(data[i + 1])] & 0xFF) : 0;
            int s2 = (tail >= 3) ? (PACK_TABLE[Byte.toUnsignedInt(data[i + 2])] & 0xFF) : 0;
            out[bodyOff++] = (byte) ((s0 << 6) | (s1 << 4) | (s2 << 2));
        }

        // Mask: sparse list of (position, original_byte). Natural
        // left-to-right scan emits entries already sorted ascending
        // (binding decision §84).
        int maskOff = HEADER_LEN + packedLen;
        for (int j = 0; j < origLen; j++) {
            int b = Byte.toUnsignedInt(data[j]);
            if (b != 'A' && b != 'C' && b != 'G' && b != 'T') {
                writeUInt32BE(out, maskOff, j);
                out[maskOff + 4] = (byte) b;
                maskOff += MASK_ENTRY_LEN;
            }
        }

        return out;
    }

    /**
     * Decode a stream produced by {@link #encode(byte[])}.
     *
     * <p>Reads the header, unpacks the 2-bit body, applies the sidecar
     * mask. Validates strictly: the version byte, the
     * {@code packed_length} invariant, the total stream length, and
     * that every mask position is in {@code [0, original_length)} and
     * strictly ascending.
     *
     * @param encoded encoded stream.
     * @return decoded bytes, equal to the encoder's input.
     * @throws IllegalArgumentException if the stream is shorter than
     *         the header, has a bad version byte, has a wrong
     *         {@code packed_length} for the declared
     *         {@code original_length}, has a body or mask section of
     *         the wrong length, has a mask position out of range, or
     *         has unsorted/duplicate mask positions.
     */
    public static byte[] decode(byte[] encoded) {
        if (encoded == null) {
            throw new IllegalArgumentException("BASE_PACK decode: input must not be null");
        }
        if (encoded.length < HEADER_LEN) {
            throw new IllegalArgumentException(
                "BASE_PACK stream too short for header: " + encoded.length
                    + " < " + HEADER_LEN);
        }

        int version = Byte.toUnsignedInt(encoded[0]);
        if (version != (VERSION & 0xFF)) {
            throw new IllegalArgumentException(
                "BASE_PACK bad version byte: 0x"
                    + String.format("%02x", version) + " (expected 0x00)");
        }

        long origLenU = readUInt32BE(encoded, 1);
        long packedLenU = readUInt32BE(encoded, 5);
        long maskCountU = readUInt32BE(encoded, 9);
        if (origLenU > Integer.MAX_VALUE) {
            throw new IllegalArgumentException(
                "BASE_PACK declared original_length too large: " + origLenU);
        }
        if (packedLenU > Integer.MAX_VALUE) {
            throw new IllegalArgumentException(
                "BASE_PACK declared packed_length too large: " + packedLenU);
        }
        if (maskCountU > Integer.MAX_VALUE) {
            throw new IllegalArgumentException(
                "BASE_PACK declared mask_count too large: " + maskCountU);
        }
        int origLen = (int) origLenU;
        int packedLen = (int) packedLenU;
        int maskCount = (int) maskCountU;

        int expectedPacked = (origLen + 3) >>> 2;
        if (packedLen != expectedPacked) {
            throw new IllegalArgumentException(
                "BASE_PACK packed_length mismatch: " + packedLen
                    + " != ceil(" + origLen + "/4) = " + expectedPacked);
        }

        long expectedTotal = (long) HEADER_LEN + packedLen
            + (long) MASK_ENTRY_LEN * maskCount;
        if (encoded.length != expectedTotal) {
            throw new IllegalArgumentException(
                "BASE_PACK stream length mismatch: " + encoded.length
                    + " != " + expectedTotal + " (header " + HEADER_LEN
                    + " + body " + packedLen + " + mask "
                    + MASK_ENTRY_LEN + "*" + maskCount + ")");
        }

        // Unpack body. The natural high-to-low extraction reads the
        // first base from the two highest-order bits of each byte.
        byte[] out = new byte[origLen];
        int bodyOff = HEADER_LEN;
        int fullChunks = origLen >>> 2;
        int o = 0;
        for (int chunk = 0; chunk < fullChunks; chunk++) {
            int b = Byte.toUnsignedInt(encoded[bodyOff + chunk]);
            out[o    ] = unpackTable((b >>> 6) & 0b11);
            out[o + 1] = unpackTable((b >>> 4) & 0b11);
            out[o + 2] = unpackTable((b >>> 2) & 0b11);
            out[o + 3] = unpackTable(b & 0b11);
            o += 4;
        }
        int tail = origLen - (fullChunks << 2);
        if (tail > 0) {
            int b = Byte.toUnsignedInt(encoded[bodyOff + fullChunks]);
            out[o] = unpackTable((b >>> 6) & 0b11);
            if (tail >= 2) {
                out[o + 1] = unpackTable((b >>> 4) & 0b11);
            }
            if (tail >= 3) {
                out[o + 2] = unpackTable((b >>> 2) & 0b11);
            }
        }

        // Apply mask. Validate ascending positions and 0 <= pos < orig_len
        // in a single scan (binding decisions §84, §92).
        int maskOff = HEADER_LEN + packedLen;
        long prevPos = -1L;
        for (int k = 0; k < maskCount; k++) {
            int entryOff = maskOff + k * MASK_ENTRY_LEN;
            long pos = readUInt32BE(encoded, entryOff);
            int origByte = Byte.toUnsignedInt(encoded[entryOff + 4]);
            if (pos >= origLen) {
                throw new IllegalArgumentException(
                    "BASE_PACK mask position " + pos + " out of range [0, "
                        + origLen + ")");
            }
            if (pos <= prevPos) {
                throw new IllegalArgumentException(
                    "BASE_PACK mask positions not strictly ascending: "
                        + pos + " after " + prevPos);
            }
            prevPos = pos;
            out[(int) pos] = (byte) origByte;
        }

        return out;
    }

    // ── Internal helpers ────────────────────────────────────────────

    /** Map a 2-bit slot value (0..3) back to the ASCII byte 'A'/'C'/'G'/'T'. */
    private static byte unpackTable(int slot) {
        // 0 → 'A' (0x41), 1 → 'C' (0x43), 2 → 'G' (0x47), 3 → 'T' (0x54).
        switch (slot) {
            case 0:  return (byte) 'A';
            case 1:  return (byte) 'C';
            case 2:  return (byte) 'G';
            default: return (byte) 'T';
        }
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
