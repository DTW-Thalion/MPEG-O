/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.shell.containers;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class ContainerRosterTest {
    @Test
    void emptySnapshotHasNoProjects() {
        var s = new ContainerRoster.Snapshot(java.util.Map.of());
        assertTrue(s.byProject().isEmpty());
    }
    // Live round-trip is exercised via UnifiedContainerTreeViewTest's
    // mocked ConnectionManager + real list().
}
