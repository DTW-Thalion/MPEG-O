/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.containers;

import java.util.Map;

/**
 * Per-container detail row as returned by
 * {@code GET /v1/containers/{uri}}. Adds on-disk metadata
 * ({@link #sizeBytes()} and {@link #modifiedAt()}) on top of the
 * fields surfaced by the list endpoint.
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.containers.ContainerDetail}.</p>
 */
public record ContainerDetail(
        String uri,
        String project,
        String owner,
        boolean encrypted,
        String storagePath,
        long createdAt,
        long updatedAt,
        long sizeBytes,
        long modifiedAt) {

    /** Strip the detail fields and return a list-shaped {@link Container}. */
    public Container asContainer() {
        return new Container(uri, project, owner, encrypted, storagePath,
            createdAt, updatedAt);
    }

    public static ContainerDetail fromJson(Map<String, Object> body) {
        return new ContainerDetail(
            (String) body.get("uri"),
            (String) body.get("project"),
            (String) body.get("owner"),
            Boolean.TRUE.equals(body.get("encrypted")),
            (String) body.get("storage_path"),
            Container.longField(body.get("created_at")),
            Container.longField(body.get("updated_at")),
            Container.longField(body.get("size_bytes")),
            Container.longField(body.get("modified_at")));
    }
}
