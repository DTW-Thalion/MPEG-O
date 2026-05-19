/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class TransferStateTest {

    @Test
    void terminalStatesAreCompletedAndFailed() {
        assertFalse(TransferState.PENDING.isTerminal());
        assertFalse(TransferState.RUNNING.isTerminal());
        assertTrue(TransferState.COMPLETED.isTerminal());
        assertTrue(TransferState.FAILED.isTerminal());
    }

    @Test
    void enumValuesAreStable() {
        // State-machine wire shape lives in workbench-client tests
        // upstream; here we only pin the local enum order so a
        // re-arrangement is a visible code change.
        TransferState[] values = TransferState.values();
        assertEquals(4, values.length);
        assertEquals(TransferState.PENDING,   values[0]);
        assertEquals(TransferState.RUNNING,   values[1]);
        assertEquals(TransferState.COMPLETED, values[2]);
        assertEquals(TransferState.FAILED,    values[3]);
    }
}
