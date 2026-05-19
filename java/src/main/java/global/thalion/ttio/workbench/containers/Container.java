/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.containers;

import java.util.Map;

/**
 * A container row as returned by {@code GET /v1/containers}.
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.containers.Container}.</p>
 *
 * @param uri          opaque registry URI ({@code uri:tio:<safe-id>}).
 * @param project      project the container belongs to.
 * @param owner        username of the uploader.
 * @param encrypted    {@code true} if the on-disk container is
 *                     encrypted.
 * @param storagePath  server-side absolute path where the {@code .tio}
 *                     file lives. Surfaced for diagnostics; not
 *                     usable by the client.
 * @param createdAt    Unix epoch seconds of first ingest.
 * @param updatedAt    Unix epoch seconds of last write (re-upload).
 */
public record Container(
        String uri,
        String project,
        String owner,
        boolean encrypted,
        String storagePath,
        long createdAt,
        long updatedAt) {

    public static Container fromJson(Map<String, Object> body) {
        return new Container(
            (String) body.get("uri"),
            (String) body.get("project"),
            (String) body.get("owner"),
            Boolean.TRUE.equals(body.get("encrypted")),
            (String) body.get("storage_path"),
            longField(body.get("created_at")),
            longField(body.get("updated_at")));
    }

    static long longField(Object v) {
        if (v instanceof Number n) return n.longValue();
        return 0L;
    }
}
