/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import org.junit.jupiter.api.Test;
import java.util.ArrayList;
import java.util.List;
import static org.junit.jupiter.api.Assertions.*;

public class NameTokenizerV2Test {
    @Test
    public void emptyRoundTrip() {
        assertEquals(0, NameTokenizerV2.decode(NameTokenizerV2.encode(List.of())).size());
    }

    @Test
    public void singleRoundTrip() {
        var names = List.of("EAS220_R1:8:1:0:1234");
        assertEquals(names, NameTokenizerV2.decode(NameTokenizerV2.encode(names)));
    }

    @Test
    public void columnarBatchRoundTrip() {
        var names = new ArrayList<String>();
        for (int i = 0; i < 100; i++) names.add("EAS:1:" + i);
        assertEquals(names, NameTokenizerV2.decode(NameTokenizerV2.encode(names)));
    }

    @Test
    public void twoBlockRoundTrip() {
        var names = new ArrayList<String>();
        for (int i = 0; i < 4097; i++) names.add("R:1:" + i);
        assertEquals(names, NameTokenizerV2.decode(NameTokenizerV2.encode(names)));
    }

    @Test
    public void dupAndMatchRoundTrip() {
        var names = new ArrayList<String>();
        for (int i = 0; i < 50; i++) {
            String n = "INSTR:1:101:" + (i*100) + ":" + (i*200);
            names.add(n); names.add(n);  /* paired */
        }
        assertEquals(names, NameTokenizerV2.decode(NameTokenizerV2.encode(names)));
    }
}
