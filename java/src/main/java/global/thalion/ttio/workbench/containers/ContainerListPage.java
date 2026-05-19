/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.containers;

import java.util.List;
import java.util.Map;

/**
 * One page of {@code GET /v1/containers} results.
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.containers.ContainerListPage}.</p>
 *
 * @param containers rows on this page.
 * @param nextCursor opaque base64url cursor for the next page, or
 *                   {@code null} if this is the last page.
 */
public record ContainerListPage(List<Container> containers,
                                 String nextCursor) {

    public ContainerListPage {
        containers = containers == null ? List.of() : List.copyOf(containers);
    }

    public boolean hasMore() { return nextCursor != null && !nextCursor.isEmpty(); }

    @SuppressWarnings("unchecked")
    public static ContainerListPage fromJson(Map<String, Object> body) {
        List<Map<String, Object>> raw = (List<Map<String, Object>>)
            body.getOrDefault("containers", List.of());
        List<Container> rows = raw.stream().map(Container::fromJson).toList();
        Object cursor = body.get("next_cursor");
        return new ContainerListPage(rows,
            cursor instanceof String s && !s.isEmpty() ? s : null);
    }
}
