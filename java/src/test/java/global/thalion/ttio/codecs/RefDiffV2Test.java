/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIf;
import static org.junit.jupiter.api.Assertions.*;

import java.security.MessageDigest;
import java.util.Random;

class RefDiffV2Test {

    static boolean nativeAvailable() {
        return RefDiffV2.isAvailable();
    }

    @Test
    @EnabledIf("nativeAvailable")
    void roundTripPerfectMatch() throws Exception {
        int n = 100;
        int readLen = 100;
        byte[] reference = new byte[n * 50 + 200];
        for (int i = 0; i < reference.length; i++) reference[i] = (byte) "ACGT".charAt(i % 4);

        byte[] sequences = new byte[n * readLen];
        long[] offsets = new long[n + 1];
        long[] positions = new long[n];
        String[] cigars = new String[n];
        Random rng = new Random(42);
        for (int r = 0; r < n; r++) {
            int refPos = r * 50;
            for (int i = 0; i < readLen; i++) {
                byte b = reference[refPos + i];
                /* 1% sub rate */
                if (rng.nextInt(100) == 0) {
                    b = (b == 'A') ? (byte)'C' : (byte)'A';
                }
                sequences[r * readLen + i] = b;
            }
            offsets[r + 1] = (r + 1) * readLen;
            positions[r] = refPos + 1;
            cigars[r] = "100M";
        }

        MessageDigest md = MessageDigest.getInstance("MD5");
        byte[] md5 = md.digest(reference);

        byte[] encoded = RefDiffV2.encode(sequences, offsets, positions, cigars,
                                           reference, md5, "test", 10000);
        assertEquals('R', encoded[0]);
        assertEquals('D', encoded[1]);
        assertEquals('F', encoded[2]);
        assertEquals('2', encoded[3]);

        RefDiffV2.Pair decoded = RefDiffV2.decode(encoded, positions, cigars,
                                                   reference, n, n * (long) readLen);
        assertArrayEquals(sequences, decoded.sequences);
        assertArrayEquals(offsets, decoded.offsets);
    }

    @Test
    void invalidMd5Length() {
        byte[] sequences = new byte[100];
        long[] offsets = {0, 100};
        long[] positions = {1};
        String[] cigars = {"100M"};
        byte[] reference = new byte[200];
        byte[] badMd5 = new byte[8];  /* wrong length */
        assertThrows(IllegalArgumentException.class,
            () -> RefDiffV2.encode(sequences, offsets, positions, cigars,
                                    reference, badMd5, "test", 10000));
    }
}
