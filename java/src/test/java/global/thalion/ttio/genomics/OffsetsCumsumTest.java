/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.genomics;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertArrayEquals;

import org.junit.jupiter.api.Test;

/**
 * v1.10 #10 — offsets-cumsum unit tests for the
 * {@link GenomicIndex#offsetsFromLengths(int[])} helper.
 *
 * <p>The companion writer/reader dispatch tests live in
 * {@code RefDiffV2DispatchTest} / {@code NameTokenizedV2DispatchTest}
 * (which both write through {@code SpectralDataset.writeMinimal} with
 * {@code optKeepOffsetsColumns} flipped on or off via
 * {@code WrittenGenomicRun.withOptKeepOffsetsColumns}). This file
 * focuses on the pure helper since that's the load-bearing piece —
 * uint32→uint64 accumulator that mustn't overflow on a >4 GB
 * genomic run even when stored {@code lengths} are uint32.</p>
 */
public class OffsetsCumsumTest {

    @Test
    void emptyLengthsProducesEmptyOffsets() {
        long[] out = GenomicIndex.offsetsFromLengths(new int[0]);
        assertEquals(0, out.length);
    }

    @Test
    void singleLengthProducesZero() {
        long[] out = GenomicIndex.offsetsFromLengths(new int[]{100});
        assertArrayEquals(new long[]{0L}, out);
    }

    @Test
    void typicalLengthsCumsum() {
        long[] out = GenomicIndex.offsetsFromLengths(new int[]{100, 50, 75, 100, 25});
        assertArrayEquals(new long[]{0L, 100L, 150L, 225L, 325L}, out);
    }

    @Test
    void uniformLengthsCumsum() {
        int[] lens = new int[20];
        java.util.Arrays.fill(lens, 150);
        long[] out = GenomicIndex.offsetsFromLengths(lens);
        long[] expected = new long[20];
        for (int i = 0; i < 20; i++) expected[i] = (long) i * 150L;
        assertArrayEquals(expected, out);
    }

    /**
     * The whole point of v1.10: a uint32 lengths array that sums to
     * more than 2^32 must accumulate correctly into uint64 offsets.
     * Without the {@code & 0xFFFFFFFFL} mask in
     * {@link GenomicIndex#offsetsFromLengths(int[])} this test would
     * silently produce the wrong result.
     */
    @Test
    void overflowSafeUint32ToUint64() {
        // 3 reads × 2^31 bytes each — sum is 3 × 2^31, last offset is 2^32.
        int[] lens = new int[]{Integer.MIN_VALUE, Integer.MIN_VALUE, Integer.MIN_VALUE};
        // Note: int[] {Integer.MIN_VALUE, ...} is the bit pattern for
        // uint32 0x80000000 = 2^31 in unsigned interpretation.
        long[] out = GenomicIndex.offsetsFromLengths(lens);
        assertEquals(0L, out[0]);
        assertEquals((long) Math.pow(2, 31), out[1], "offset[1] should be 2^31");
        assertEquals((long) Math.pow(2, 32), out[2], "offset[2] should be 2^32");
    }

    @Test
    void resultDtypeIsLongRegardlessOfInputSign() {
        // Negative int values (sign-extended uint32) must still produce
        // monotonic non-negative long offsets.
        int[] lens = new int[]{-1, -2}; // uint32 = 0xFFFFFFFF, 0xFFFFFFFE
        long[] out = GenomicIndex.offsetsFromLengths(lens);
        assertEquals(0L, out[0]);
        assertEquals(0xFFFFFFFFL, out[1]);
        // out[2] would be 0xFFFFFFFFL + 0xFFFFFFFEL = 0x1FFFFFFFD — well
        // beyond INT_MAX; verifying we stayed in long-arithmetic.
    }
}
