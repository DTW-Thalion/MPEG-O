/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/**
 * DELTA_RANS_ORDER0 codec (M95, codec id 11).
 *
 * <p>Delta + zigzag + unsigned LEB128 varint + rANS order-0.
 * Designed for sorted-ascending integer channels (e.g. genomic positions)
 * where deltas are small and concentrated.
 *
 * <p>Cross-language equivalents:
 * <ul>
 *   <li>Python: {@code ttio.codecs.delta_rans}</li>
 *   <li>Objective-C: {@code TTIODeltaRans}</li>
 * </ul>
 *
 * <p>Wire format:
 * <pre>
 *   Offset  Size   Field
 *   0       4      magic: "DRA0"
 *   4       1      version: uint8 = 1
 *   5       1      element_size: uint8 (1, 4, or 8)
 *   6       2      reserved: uint8[2] = 0x00
 *   8       var    body: rANS order-0 encoded varint stream
 * </pre>
 */
public final class DeltaRans {

    private static final byte[] MAGIC = {0x44, 0x52, 0x41, 0x30}; // "DRA0"
    private static final int VERSION = 1;
    private static final int HEADER_LEN = 8;

    private DeltaRans() {}

    /**
     * Encode raw LE integer bytes through delta + zigzag + varint + rANS order-0.
     *
     * @param data        raw little-endian integer bytes
     * @param elementSize 1 (int8), 4 (int32), or 8 (int64)
     * @return encoded bytes (header + rANS order-0 body)
     */
    public static byte[] encode(byte[] data, int elementSize) {
        if (elementSize != 1 && elementSize != 4 && elementSize != 8) {
            throw new IllegalArgumentException(
                "DELTA_RANS: element_size must be 1, 4, or 8, got " + elementSize);
        }
        if (data.length % elementSize != 0) {
            throw new IllegalArgumentException(
                "DELTA_RANS: data length " + data.length +
                " not a multiple of element_size " + elementSize);
        }

        int nElements = data.length / elementSize;

        // Build header
        byte[] header = new byte[HEADER_LEN];
        System.arraycopy(MAGIC, 0, header, 0, 4);
        header[4] = (byte) VERSION;
        header[5] = (byte) elementSize;
        // header[6], header[7] already 0 (reserved)

        if (nElements == 0) {
            byte[] ransBody = Rans.encode(new byte[0], 0);
            byte[] out = new byte[HEADER_LEN + ransBody.length];
            System.arraycopy(header, 0, out, 0, HEADER_LEN);
            System.arraycopy(ransBody, 0, out, HEADER_LEN, ransBody.length);
            return out;
        }

        // Parse LE integers
        ByteBuffer bb = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN);
        long[] values = new long[nElements];
        for (int i = 0; i < nElements; i++) {
            switch (elementSize) {
                case 1: values[i] = bb.get(); break;     // signed byte
                case 4: values[i] = bb.getInt(); break;   // signed int32
                case 8: values[i] = bb.getLong(); break;   // signed int64
            }
        }

        // Delta + zigzag + varint
        ByteArrayOutputStream varintBuf = new ByteArrayOutputStream();
        long prev = 0;
        for (int i = 0; i < nElements; i++) {
            long delta = values[i] - prev;
            // Zigzag encode (works for all widths when values are already sign-extended)
            long zz = (delta << 1) ^ (delta >> 63);
            // Varint encode (unsigned LEB128)
            writeVarint(varintBuf, zz);
            prev = values[i];
        }

        byte[] varintBytes = varintBuf.toByteArray();
        byte[] ransBody = Rans.encode(varintBytes, 0);

        byte[] out = new byte[HEADER_LEN + ransBody.length];
        System.arraycopy(header, 0, out, 0, HEADER_LEN);
        System.arraycopy(ransBody, 0, out, HEADER_LEN, ransBody.length);
        return out;
    }

    /**
     * Decode a DELTA_RANS_ORDER0 encoded stream.
     *
     * @param encoded the encoded byte stream
     * @return the original raw LE integer bytes
     */
    public static byte[] decode(byte[] encoded) {
        if (encoded.length < HEADER_LEN) {
            throw new IllegalArgumentException(
                "DELTA_RANS: encoded data too short for header");
        }
        // Validate magic
        for (int i = 0; i < 4; i++) {
            if (encoded[i] != MAGIC[i]) {
                throw new IllegalArgumentException(
                    "DELTA_RANS: bad magic (expected DRA0)");
            }
        }
        int version = encoded[4] & 0xFF;
        if (version != VERSION) {
            throw new IllegalArgumentException(
                "DELTA_RANS: unsupported version " + version);
        }
        int elementSize = encoded[5] & 0xFF;
        if (elementSize != 1 && elementSize != 4 && elementSize != 8) {
            throw new IllegalArgumentException(
                "DELTA_RANS: invalid element_size " + elementSize);
        }

        // rANS decode body
        byte[] body = new byte[encoded.length - HEADER_LEN];
        System.arraycopy(encoded, HEADER_LEN, body, 0, body.length);
        byte[] varintBytes = Rans.decode(body);

        if (varintBytes.length == 0) {
            return new byte[0];
        }

        // Parse varints
        long[] zigzagValues = readAllVarints(varintBytes);

        // Zigzag decode + prefix-sum
        long[] values = new long[zigzagValues.length];
        long prev = 0;
        for (int i = 0; i < zigzagValues.length; i++) {
            long zz = zigzagValues[i];
            long delta = (zz >>> 1) ^ -(zz & 1);
            long v = prev + delta;
            // Truncate to element width for proper signed behavior
            switch (elementSize) {
                case 1: v = (byte) v; break;
                case 4: v = (int) v; break;
                // case 8: no truncation needed
            }
            values[i] = v;
            prev = v;
        }

        // Serialize as LE bytes
        ByteBuffer out = ByteBuffer.allocate(values.length * elementSize)
            .order(ByteOrder.LITTLE_ENDIAN);
        for (long v : values) {
            switch (elementSize) {
                case 1: out.put((byte) v); break;
                case 4: out.putInt((int) v); break;
                case 8: out.putLong(v); break;
            }
        }
        return out.array();
    }

    private static void writeVarint(ByteArrayOutputStream out, long value) {
        // Treat as unsigned — use >>> for shifting
        long v = value;
        while ((v & ~0x7FL) != 0) {
            out.write((int) ((v & 0x7F) | 0x80));
            v >>>= 7;
        }
        out.write((int) (v & 0x7F));
    }

    private static long[] readAllVarints(byte[] data) {
        // First pass: count varints
        int count = 0;
        int i = 0;
        while (i < data.length) {
            while (i < data.length && (data[i] & 0x80) != 0) i++;
            i++; // final byte
            count++;
        }
        // Second pass: decode
        long[] result = new long[count];
        i = 0;
        for (int idx = 0; idx < count; idx++) {
            long value = 0;
            int shift = 0;
            while (true) {
                if (i >= data.length) {
                    throw new IllegalArgumentException("DELTA_RANS: truncated varint");
                }
                int b = data[i++] & 0xFF;
                value |= ((long) (b & 0x7F)) << shift;
                if ((b & 0x80) == 0) break;
                shift += 7;
            }
            result[idx] = value;
        }
        return result;
    }
}
