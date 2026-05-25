/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.shell.containers;

import global.thalion.ttio.workbench.WorkbenchClient;
import global.thalion.ttio.workbench.containers.Container;
import global.thalion.ttio.workbench.containers.ContainerListPage;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Async-friendly helper that fetches the workbench's container
 * roster and groups it by project. Kept off the JavaFX thread —
 * callers schedule it on a daemon worker.
 */
public final class ContainerRoster {

    private ContainerRoster() {}

    public record Snapshot(
        Map<String, List<UnifiedContainerNode.ServerContainer>> byProject) {}

    public static Snapshot fetchAndGroup(WorkbenchClient client, int pageSize) {
        Map<String, List<UnifiedContainerNode.ServerContainer>> grouped = new LinkedHashMap<>();
        String cursor = null;
        do {
            ContainerListPage page = client.containers().list(null, null, pageSize, cursor);
            for (Container c : page.containers()) {
                String project = c.project() == null || c.project().isEmpty()
                    ? "(unassigned)" : c.project();
                grouped.computeIfAbsent(project, k -> new ArrayList<>())
                    .add(new UnifiedContainerNode.ServerContainer(
                        c.uri(), deriveDisplayName(c.uri()), 0L));
            }
            cursor = page.nextCursor();
        } while (cursor != null);
        return new Snapshot(grouped);
    }

    private static String deriveDisplayName(String uri) {
        if (uri == null) return "(unnamed)";
        int slash = Math.max(uri.lastIndexOf('/'), uri.lastIndexOf(':'));
        return slash >= 0 ? uri.substring(slash + 1) : uri;
    }
}
