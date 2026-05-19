/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench;

import global.thalion.ttio.workbench.transport.ResumeState;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class ResumeStateTest {

    @Test
    void freshFactorySetsSentinel() {
        ResumeState s = ResumeState.fresh("stg-abc");
        assertEquals("stg-abc", s.resumeHandle());
        assertEquals(-1L, s.lastAckedAuSequence());
    }

    @Test
    void explicitSequenceRetained() {
        ResumeState s = new ResumeState("stg-abc", 12L);
        assertEquals(12L, s.lastAckedAuSequence());
    }

    @Test
    void rejectsEmptyHandle() {
        assertThrows(IllegalArgumentException.class,
            () -> new ResumeState("", 0L));
    }

    @Test
    void rejectsNullHandle() {
        assertThrows(IllegalArgumentException.class,
            () -> new ResumeState(null, 0L));
    }
}
