/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.codecs;

import io.airlift.compress.zstd.ZstdCompressor;
import io.airlift.compress.zstd.ZstdDecompressor;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/**
 * FLOAT_DELTA_ZSTD — lossless float64 channel codec (codec id 17).
 *
 * <p>Spec: {@code docs/superpowers/specs/2026-08-16-float-delta-codec-design.md}.
 * Per block: none/delta on the uint64 bit view (chosen by exact size
 * comparison), byte-plane transpose, one zstd frame. Values round-trip
 * bit-exactly. Per the spec's Option B decision, encoders MAY differ
 * byte-wise across languages; decoders MUST accept any conforming
 * stream — the shared golden fixture pins the decode side.</p>
 *
 * <p>Cross-language equivalents: Python
 * {@code ttio.codecs.float_delta_zstd}, ObjC {@code TTIOFloatDeltaZstd}.</p>
 */
public final class FloatDeltaZstd {

    public static final byte[] MAGIC = { 'F', 'D', 'Z', '1' };
    public static final int VERSION = 0x01;
    public static final int HEADER_LEN = 22;
    public static final int BLOCK_SIZE = 1 << 20;
    public static final int TRANSFORM_NONE = 0x00;
    public static final int TRANSFORM_DELTA = 0x01;

    private FloatDeltaZstd() {}

    private static byte[] transpose(long[] u, int off, int len) {
        byte[] out = new byte[len * 8];
        for (int plane = 0; plane < 8; plane++) {
            int base = plane * len;
            int shift = plane * 8;
            for (int i = 0; i < len; i++) {
                out[base + i] = (byte) (u[off + i] >>> shift);
            }
        }
        return out;
    }

    private static void untranspose(byte[] planes, long[] out, int off, int len) {
        for (int i = 0; i < len; i++) out[off + i] = 0;
        for (int plane = 0; plane < 8; plane++) {
            int base = plane * len;
            int shift = plane * 8;
            for (int i = 0; i < len; i++) {
                out[off + i] |= (planes[base + i] & 0xFFL) << shift;
            }
        }
    }

    private static byte[] zstd(byte[] input) {
        ZstdCompressor c = new ZstdCompressor();
        byte[] buf = new byte[c.maxCompressedLength(input.length)];
        int n = c.compress(input, 0, input.length, buf, 0, buf.length);
        return java.util.Arrays.copyOf(buf, n);
    }

    /** Encode a float64 array (as raw longs of its bit pattern). */
    public static byte[] encode(double[] values) {
        long[] u = new long[values.length];
        for (int i = 0; i < values.length; i++) {
            u[i] = Double.doubleToRawLongBits(values[i]);
        }
        int n = u.length;
        int nBlocks = (n + BLOCK_SIZE - 1) / BLOCK_SIZE;
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        ByteBuffer hdr = ByteBuffer.allocate(HEADER_LEN).order(ByteOrder.LITTLE_ENDIAN);
        hdr.put(MAGIC).put((byte) VERSION).put((byte) 0)
           .putLong(n).putInt(BLOCK_SIZE).putInt(nBlocks);
        out.writeBytes(hdr.array());
        long[] d = new long[Math.min(BLOCK_SIZE, Math.max(n, 1))];
        for (int bi = 0; bi < nBlocks; bi++) {
            int off = bi * BLOCK_SIZE;
            int len = Math.min(BLOCK_SIZE, n - off);
            d[0] = u[off];
            for (int i = 1; i < len; i++) d[i] = u[off + i] - u[off + i - 1];
            byte[] bodyNone = zstd(transpose(u, off, len));
            byte[] bodyDelta = zstd(transpose(d, 0, len));
            int transform = bodyDelta.length < bodyNone.length
                    ? TRANSFORM_DELTA : TRANSFORM_NONE;
            byte[] body = transform == TRANSFORM_DELTA ? bodyDelta : bodyNone;
            ByteBuffer bh = ByteBuffer.allocate(5).order(ByteOrder.LITTLE_ENDIAN);
            bh.put((byte) transform).putInt(body.length);
            out.writeBytes(bh.array());
            out.writeBytes(body);
        }
        return out.toByteArray();
    }

    /** Decode an FDZ1 stream back to the exact float64 array. */
    public static double[] decode(byte[] stream) {
        if (stream.length < HEADER_LEN
                || stream[0] != 'F' || stream[1] != 'D'
                || stream[2] != 'Z' || stream[3] != '1') {
            throw new IllegalArgumentException("not an FDZ1 stream");
        }
        ByteBuffer in = ByteBuffer.wrap(stream).order(ByteOrder.LITTLE_ENDIAN);
        in.position(4);
        int version = in.get() & 0xFF;
        in.get(); // flags
        long nLong = in.getLong();
        int blockSize = in.getInt();
        int nBlocks = in.getInt();
        if (version != VERSION) {
            throw new IllegalArgumentException("unknown FDZ1 version " + version);
        }
        if (nLong < 0 || nLong > Integer.MAX_VALUE || blockSize <= 0
                || nBlocks != (nLong + blockSize - 1) / blockSize) {
            throw new IllegalArgumentException("malformed FDZ1 header");
        }
        int n = (int) nLong;
        long[] u = new long[n];
        ZstdDecompressor dec = new ZstdDecompressor();
        for (int bi = 0; bi < nBlocks; bi++) {
            if (in.remaining() < 5) {
                throw new IllegalArgumentException("FDZ1 stream truncated at block header");
            }
            int transform = in.get() & 0xFF;
            int bodyLen = in.getInt();
            if (bodyLen < 0 || in.remaining() < bodyLen) {
                throw new IllegalArgumentException("FDZ1 stream truncated in block body");
            }
            int off = bi * blockSize;
            int len = Math.min(blockSize, n - off);
            byte[] planes = new byte[len * 8];
            int inflated = dec.decompress(stream, in.position(), bodyLen,
                    planes, 0, planes.length);
            if (inflated != planes.length) {
                throw new IllegalArgumentException("FDZ1 block inflated to the wrong size");
            }
            in.position(in.position() + bodyLen);
            untranspose(planes, u, off, len);
            if (transform == TRANSFORM_DELTA) {
                for (int i = 1; i < len; i++) u[off + i] += u[off + i - 1];
            } else if (transform != TRANSFORM_NONE) {
                throw new IllegalArgumentException("unknown FDZ1 transform " + transform);
            }
        }
        if (in.remaining() != 0) {
            throw new IllegalArgumentException("trailing bytes after the last FDZ1 block");
        }
        double[] out = new double[n];
        for (int i = 0; i < n; i++) out[i] = Double.longBitsToDouble(u[i]);
        return out;
    }
}
