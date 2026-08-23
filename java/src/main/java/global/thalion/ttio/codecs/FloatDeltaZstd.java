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
 * Per block: none or delta on the uint64 bit view, byte planes or plain
 * little-endian values, all four compared by exact size, then one zstd
 * frame. Values round-trip
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
    /** Bit 0: prefix delta on the uint64 bit view. Bit 1: the values go
     *  into the zstd frame as plain little-endian uint64 rather than 8
     *  byte planes. The transpose pays on intensity arrays and costs on
     *  m/z, so both are chosen per block by exact size. */
    public static final int TRANSFORM_DELTA = 0x01;
    public static final int TRANSFORM_PLAIN = 0x02;
    public static final int TRANSFORM_MASK = 0x03;

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

    private static byte[] plain(long[] u, int off, int len) {
        ByteBuffer b = ByteBuffer.allocate(len * 8).order(ByteOrder.LITTLE_ENDIAN);
        for (int i = 0; i < len; i++) b.putLong(u[off + i]);
        return b.array();
    }

    private static void unplain(byte[] raw, long[] out, int off, int len) {
        ByteBuffer b = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN);
        for (int i = 0; i < len; i++) out[off + i] = b.getLong();
    }

    /** Undo one block's transform in place: raw body bytes to values. */
    private static void detransform(byte[] raw, long[] out, int off, int len, int transform) {
        if ((transform & ~TRANSFORM_MASK) != 0) {
            throw new IllegalArgumentException("unknown FDZ1 transform " + transform);
        }
        if ((transform & TRANSFORM_PLAIN) != 0) {
            unplain(raw, out, off, len);
        } else {
            untranspose(raw, out, off, len);
        }
        if ((transform & TRANSFORM_DELTA) != 0) {
            for (int i = 1; i < len; i++) out[off + i] += out[off + i - 1];
        }
    }

    private static byte[] zstd(byte[] input) {
        ZstdCompressor c = new ZstdCompressor();
        byte[] buf = new byte[c.maxCompressedLength(input.length)];
        int n = c.compress(input, 0, input.length, buf, 0, buf.length);
        return java.util.Arrays.copyOf(buf, n);
    }

    /** The 22-byte FDZ1 stream header for {@code nValues} values in
     *  {@code nBlocks} blocks of {@link #BLOCK_SIZE}. */
    public static byte[] headerBytes(long nValues, int nBlocks) {
        ByteBuffer hdr = ByteBuffer.allocate(HEADER_LEN).order(ByteOrder.LITTLE_ENDIAN);
        hdr.put(MAGIC).put((byte) VERSION).put((byte) 0)
           .putLong(nValues).putInt(BLOCK_SIZE).putInt(nBlocks);
        return hdr.array();
    }

    /** One encoded block: the transform byte and the zstd body. */
    public record EncodedBlock(int transform, byte[] body) {}

    /** Encode one block of at most {@link #BLOCK_SIZE} values. */
    public static EncodedBlock encodeBlock(double[] values) {
        int len = values.length;
        long[] u = new long[len];
        for (int i = 0; i < len; i++) u[i] = Double.doubleToRawLongBits(values[i]);
        long[] d = new long[Math.max(len, 1)];
        if (len > 0) d[0] = u[0];
        for (int i = 1; i < len; i++) d[i] = u[i] - u[i - 1];
        byte[][] bodies = new byte[TRANSFORM_MASK + 1][];
        bodies[TRANSFORM_NONE] = zstd(transpose(u, 0, len));
        bodies[TRANSFORM_DELTA] = zstd(transpose(d, 0, len));
        bodies[TRANSFORM_PLAIN] = zstd(plain(u, 0, len));
        bodies[TRANSFORM_PLAIN | TRANSFORM_DELTA] = zstd(plain(d, 0, len));
        int best = TRANSFORM_NONE;
        for (int t = 1; t <= TRANSFORM_MASK; t++) {
            if (bodies[t].length < bodies[best].length) best = t;
        }
        return new EncodedBlock(best, bodies[best]);
    }

    /** The on-stream bytes of a block: 5-byte block header plus body. */
    public static byte[] blockBytes(EncodedBlock b) {
        ByteBuffer bh = ByteBuffer.allocate(5 + b.body().length).order(ByteOrder.LITTLE_ENDIAN);
        bh.put((byte) b.transform()).putInt(b.body().length).put(b.body());
        return bh.array();
    }

    /** Encode a float64 array (as raw longs of its bit pattern). */
    public static byte[] encode(double[] values) {
        int n = values.length;
        int nBlocks = (n + BLOCK_SIZE - 1) / BLOCK_SIZE;
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.writeBytes(headerBytes(n, nBlocks));
        for (int bi = 0; bi < nBlocks; bi++) {
            int off = bi * BLOCK_SIZE;
            int len = Math.min(BLOCK_SIZE, n - off);
            out.writeBytes(blockBytes(encodeBlock(java.util.Arrays.copyOfRange(values, off, off + len))));
        }
        return out.toByteArray();
    }

    /** Reads {@code count} bytes at {@code offset} of a stored stream. */
    @FunctionalInterface
    public interface ByteRangeReader {
        byte[] read(long offset, int count);
    }

    /** Header fields and the byte range of every block of a stream. */
    public record BlockTable(long nValues, int blockSize, int nBlocks,
                             long[] offsets, int[] transforms, int[] lengths) {
        /** Values in block {@code k}. */
        public int blockValues(int k) {
            long start = (long) k * blockSize;
            return (int) Math.min(blockSize, nValues - start);
        }
    }

    /** Walk the block headers of a stream without reading the bodies. */
    public static BlockTable readBlockTable(ByteRangeReader r) {
        byte[] hdr = r.read(0, HEADER_LEN);
        if (hdr.length < HEADER_LEN || hdr[0] != 'F' || hdr[1] != 'D' || hdr[2] != 'Z' || hdr[3] != '1') {
            throw new IllegalArgumentException("not an FDZ1 stream");
        }
        ByteBuffer in = ByteBuffer.wrap(hdr).order(ByteOrder.LITTLE_ENDIAN);
        in.position(4);
        int version = in.get() & 0xFF;
        in.get();
        long nValues = in.getLong();
        int blockSize = in.getInt();
        int nBlocks = in.getInt();
        if (version != VERSION) throw new IllegalArgumentException("unknown FDZ1 version " + version);
        if (nValues < 0 || blockSize <= 0 || nBlocks != (nValues + blockSize - 1) / blockSize) {
            throw new IllegalArgumentException("malformed FDZ1 header");
        }
        long[] offsets = new long[nBlocks];
        int[] transforms = new int[nBlocks];
        int[] lengths = new int[nBlocks];
        long pos = HEADER_LEN;
        for (int k = 0; k < nBlocks; k++) {
            byte[] bh = r.read(pos, 5);
            if (bh.length < 5) throw new IllegalArgumentException("FDZ1 stream truncated at block header");
            ByteBuffer b = ByteBuffer.wrap(bh).order(ByteOrder.LITTLE_ENDIAN);
            transforms[k] = b.get() & 0xFF;
            lengths[k] = b.getInt();
            if (lengths[k] < 0) throw new IllegalArgumentException("malformed FDZ1 block header");
            offsets[k] = pos + 5;
            pos += 5 + lengths[k];
        }
        return new BlockTable(nValues, blockSize, nBlocks, offsets, transforms, lengths);
    }

    /** Decode block {@code k} of a stream described by {@code t}. */
    public static double[] decodeBlock(ByteRangeReader r, BlockTable t, int k) {
        int len = t.blockValues(k);
        byte[] body = r.read(t.offsets()[k], t.lengths()[k]);
        byte[] raw = new byte[len * 8];
        ZstdDecompressor dec = new ZstdDecompressor();
        int inflated = dec.decompress(body, 0, body.length, raw, 0, raw.length);
        if (inflated != raw.length) {
            throw new IllegalArgumentException("FDZ1 block inflated to the wrong size");
        }
        long[] u = new long[len];
        detransform(raw, u, 0, len, t.transforms()[k]);
        double[] out = new double[len];
        for (int i = 0; i < len; i++) out[i] = Double.longBitsToDouble(u[i]);
        return out;
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
            byte[] raw = new byte[len * 8];
            int inflated = dec.decompress(stream, in.position(), bodyLen,
                    raw, 0, raw.length);
            if (inflated != raw.length) {
                throw new IllegalArgumentException("FDZ1 block inflated to the wrong size");
            }
            in.position(in.position() + bodyLen);
            detransform(raw, u, off, len, transform);
        }
        if (in.remaining() != 0) {
            throw new IllegalArgumentException("trailing bytes after the last FDZ1 block");
        }
        double[] out = new double[n];
        for (int i = 0; i < n; i++) out[i] = Double.longBitsToDouble(u[i]);
        return out;
    }
}
