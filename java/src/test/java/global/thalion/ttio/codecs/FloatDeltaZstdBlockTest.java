/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import org.junit.jupiter.api.Test;

import java.io.ByteArrayOutputStream;
import java.util.Arrays;
import java.util.Random;

import static org.junit.jupiter.api.Assertions.*;

/** The block-wise FDZ1 API produces and reads the same stream as the
 *  whole-array {@code encode}/{@code decode}. */
class FloatDeltaZstdBlockTest {

    static double[] values(int n) {
        Random rnd = new Random(7);
        double[] v = new double[n];
        double x = 100.0;
        for (int i = 0; i < n; i++) { x += rnd.nextDouble(); v[i] = x; }
        return v;
    }

    @Test
    void blockwiseEncodeEqualsWholeEncode() {
        int n = 3 * FloatDeltaZstd.BLOCK_SIZE + 17;
        double[] v = values(n);
        byte[] whole = FloatDeltaZstd.encode(v);
        int nBlocks = (n + FloatDeltaZstd.BLOCK_SIZE - 1) / FloatDeltaZstd.BLOCK_SIZE;
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.writeBytes(FloatDeltaZstd.headerBytes(n, nBlocks));
        for (int k = 0; k < nBlocks; k++) {
            int off = k * FloatDeltaZstd.BLOCK_SIZE;
            int len = Math.min(FloatDeltaZstd.BLOCK_SIZE, n - off);
            out.writeBytes(FloatDeltaZstd.blockBytes(
                FloatDeltaZstd.encodeBlock(Arrays.copyOfRange(v, off, off + len))));
        }
        assertArrayEquals(whole, out.toByteArray());
    }

    @Test
    void blockTableAndDecodeBlockAgreeWithDecode() {
        int n = 2 * FloatDeltaZstd.BLOCK_SIZE + 5;
        double[] v = values(n);
        byte[] stream = FloatDeltaZstd.encode(v);
        FloatDeltaZstd.ByteRangeReader r = (off, cnt) -> Arrays.copyOfRange(stream, (int) off, (int) off + cnt);
        FloatDeltaZstd.BlockTable t = FloatDeltaZstd.readBlockTable(r);
        assertEquals(n, t.nValues());
        assertEquals(3, t.nBlocks());
        assertEquals(FloatDeltaZstd.HEADER_LEN + 5, t.offsets()[0]);
        long end = t.offsets()[2] + t.lengths()[2];
        assertEquals(stream.length, end);
        double[] all = FloatDeltaZstd.decode(stream);
        for (int k = 0; k < 3; k++) {
            double[] blk = FloatDeltaZstd.decodeBlock(r, t, k);
            int off = k * t.blockSize();
            assertArrayEquals(Arrays.copyOfRange(all, off, off + t.blockValues(k)), blk);
        }
        assertEquals(5, t.blockValues(2));
    }

    @Test
    void emptyStreamHasNoBlocks() {
        byte[] stream = FloatDeltaZstd.encode(new double[0]);
        assertArrayEquals(FloatDeltaZstd.headerBytes(0, 0), stream);
        FloatDeltaZstd.BlockTable t = FloatDeltaZstd.readBlockTable(
            (off, cnt) -> Arrays.copyOfRange(stream, (int) off, (int) off + cnt));
        assertEquals(0, t.nBlocks());
    }
}
