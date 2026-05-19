/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.sessions;

import java.util.Map;
import java.util.Objects;

/**
 * Client-side mirror of the daemon's bind-mount validation. Catches
 * the obvious typos (relative path, contains `..`) before submit;
 * the server enforces the project-scope rule with 403 even if the
 * client doesn't have `containerStorageRoot`.
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.sessions.validate_bind_mounts}.</p>
 */
public final class BindMountValidator {

    private BindMountValidator() {}

    /** Validate the bind-mount map. Throws
     *  {@link IllegalArgumentException} on the first violation.
     *  Empty / null maps are valid no-ops. */
    public static void validate(
            Map<String, String> bindMounts,
            String project,
            String containerStorageRoot) {
        Objects.requireNonNull(project, "project");
        if (bindMounts == null || bindMounts.isEmpty()) return;
        for (Map.Entry<String, String> e : bindMounts.entrySet()) {
            String hostPath = e.getKey();
            String containerPath = e.getValue();
            if (!hostPath.startsWith("/")) {
                throw new IllegalArgumentException(
                    "bind-mount host path must be absolute: " + hostPath);
            }
            for (String part : hostPath.split("/")) {
                if ("..".equals(part)) {
                    throw new IllegalArgumentException(
                        "bind-mount host path contains `..`: " + hostPath);
                }
            }
            if (containerPath == null || !containerPath.startsWith("/")) {
                throw new IllegalArgumentException(
                    "bind-mount container path must be absolute: " + containerPath);
            }
            if (containerStorageRoot != null) {
                String prefix = containerStorageRoot.replaceAll("/+$", "")
                                + "/" + project + "/";
                if (!hostPath.startsWith(prefix)) {
                    throw new IllegalArgumentException(
                        "bind-mount host path " + hostPath
                        + " must sit under " + prefix);
                }
            }
        }
    }
}
