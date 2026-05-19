/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.containers;

import java.util.Map;

/**
 * One layer entry from {@code GET /v1/containers/{uri}/layers}.
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.containers.ContainerLayer}.</p>
 */
public record ContainerLayer(
        String layerType,
        String layerPath,
        long byteSize,
        long createdAt) {

    public static ContainerLayer fromJson(Map<String, Object> body) {
        return new ContainerLayer(
            (String) body.get("layer_type"),
            (String) body.get("layer_path"),
            Container.longField(body.get("byte_size")),
            Container.longField(body.get("created_at")));
    }
}
