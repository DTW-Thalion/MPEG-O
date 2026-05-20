/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench;

import global.thalion.ttio.workbench.transport.TransferProgress;
import global.thalion.ttio.workbench.transport.WorkbenchTransportClient;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Unit tests for the transport progress-callback contract. The
 * end-to-end "callback fires with rising bytes during an upload"
 * behaviour is exercised by the live-daemon smoke; here we pin the
 * pure interface contract + that the progress overloads exist.
 */
class TransferProgressTest {

    @Test
    void unknownTotalSentinelIsNegativeOne() {
        assertEquals(-1L, TransferProgress.UNKNOWN_TOTAL);
    }

    @Test
    void callbackReceivesProgressTuples() {
        List<long[]> seen = new ArrayList<>();
        TransferProgress p = (done, total) -> seen.add(new long[]{done, total});
        p.onProgress(0, 100);
        p.onProgress(64, 100);
        p.onProgress(100, 100);
        assertEquals(3, seen.size());
        assertArrayEquals(new long[]{0, 100}, seen.get(0));
        assertArrayEquals(new long[]{100, 100}, seen.get(2));
    }

    @Test
    void progressOverloadsArePresent() throws NoSuchMethodException {
        // upload(project, uri, payload, ResumeState, TransferProgress)
        assertNotNull(WorkbenchTransportClient.class.getMethod(
            "upload", String.class, String.class, byte[].class,
            global.thalion.ttio.workbench.transport.ResumeState.class,
            TransferProgress.class));
        // download(uri, filter, OutputMode, int, TransferProgress)
        assertNotNull(WorkbenchTransportClient.class.getMethod(
            "download", String.class, java.util.Map.class,
            global.thalion.ttio.workbench.transport.WorkbenchHandshake.OutputMode.class,
            int.class, TransferProgress.class));
    }
}
