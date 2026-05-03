/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIf;
import static org.junit.jupiter.api.Assertions.*;

import java.util.Random;

class MateInfoV2Test {

    static boolean nativeAvailable() {
        return MateInfoV2.isAvailable();
    }

    @Test
    @EnabledIf("nativeAvailable")
    void roundTripMixedPattern() {
        int n = 1000;
        Random rng = new Random(42);
        int[]   mc = new int[n];
        long[]  mp = new long[n];
        int[]   ts = new int[n];
        short[] oc = new short[n];
        long[]  op = new long[n];

        for (int i = 0; i < n; i++) {
            oc[i] = (short) (rng.nextInt(24));
            op[i] = rng.nextInt(100_000_000);
            ts[i] = rng.nextInt(1000) - 500;
            int dice = rng.nextInt(10);
            if (dice < 8) {
                mc[i] = oc[i] & 0xFFFF;
                mp[i] = op[i] + (rng.nextInt(1000) - 500);
            } else if (dice < 9) {
                mc[i] = ((oc[i] & 0xFFFF) + 1) % 24;
                mp[i] = rng.nextInt(100_000_000);
            } else {
                mc[i] = -1;
                mp[i] = 0;
            }
        }

        byte[] encoded = MateInfoV2.encode(mc, mp, ts, oc, op);
        assertEquals('M', encoded[0]);
        assertEquals('I', encoded[1]);
        assertEquals('v', encoded[2]);
        assertEquals('2', encoded[3]);

        MateInfoV2.Triple decoded = MateInfoV2.decode(encoded, oc, op, n);
        assertArrayEquals(mc, decoded.mateChromIds);
        assertArrayEquals(mp, decoded.matePositions);
        assertArrayEquals(ts, decoded.templateLengths);
    }

    @Test
    void invalidMateChromRejected() {
        int[]   mc = {-2};
        long[]  mp = {0L};
        int[]   ts = {0};
        short[] oc = {0};
        long[]  op = {0L};
        assertThrows(IllegalArgumentException.class,
            () -> MateInfoV2.encode(mc, mp, ts, oc, op));
    }
}
