/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class JobMonitorTest {

    // ---- formatTimestamp ----

    @Test
    void formatTimestampRendersUtcIso() {
        // 1700000000 = 2023-11-14T22:13:20Z
        assertEquals("2023-11-14T22:13:20Z",
            JobMonitor.formatTimestamp(1700000000L));
    }

    @Test
    void formatTimestampNullIsBlank() {
        assertEquals("", JobMonitor.formatTimestamp(null));
    }

    @Test
    void formatTimestampZeroIsBlank() {
        assertEquals("", JobMonitor.formatTimestamp(0L));
    }

    @Test
    void formatTimestampNegativeIsBlank() {
        assertEquals("", JobMonitor.formatTimestamp(-1L));
    }

    // ---- filterValue ----

    @Test
    void filterValueResolvesAll() {
        assertNull(JobMonitor.filterValue("(all)"));
        assertNull(JobMonitor.filterValue(""));
        assertNull(JobMonitor.filterValue(null));
    }

    @Test
    void filterValuePassesThroughKnownStatus() {
        assertEquals("running", JobMonitor.filterValue("running"));
        assertEquals("completed", JobMonitor.filterValue("completed"));
        assertEquals("failed", JobMonitor.filterValue("failed"));
    }
}
