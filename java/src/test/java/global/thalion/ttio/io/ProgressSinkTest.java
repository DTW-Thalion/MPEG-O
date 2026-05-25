/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.io;

import org.junit.jupiter.api.Test;

import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.*;

class ProgressSinkTest {

    @Test
    void discardIsNoopAndReusable() {
        ProgressSink s = ProgressSink.discard();
        // calling discard's sink doesn't throw and doesn't keep state
        s.onProgress(0L, 100L);
        s.onProgress(50L, 100L);
        s.onProgress(100L, 100L);
        // (no observable behaviour to assert beyond not throwing)
        assertNotNull(s);
    }

    @Test
    void functionalInterfaceFiresWithDoneAndTotal() {
        AtomicLong lastDone  = new AtomicLong(-1L);
        AtomicLong lastTotal = new AtomicLong(-1L);
        ProgressSink sink = (d, t) -> { lastDone.set(d); lastTotal.set(t); };
        sink.onProgress(42L, 100L);
        assertEquals(42L, lastDone.get());
        assertEquals(100L, lastTotal.get());
        sink.onProgress(75L, -1L);  // total unknown
        assertEquals(75L, lastDone.get());
        assertEquals(-1L, lastTotal.get());
    }
}
