/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.auth;

import java.time.Instant;
import java.util.Set;

/**
 * Authenticated workbench session. Immutable; on expiry, re-login
 * rather than mutate.
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.auth.Session}.</p>
 *
 * @param token         bearer token for {@code Authorization: Bearer}
 *                       and the WS handshake {@code token} field.
 *                       Always {@code ttiowbs_<43-char-base64url>} for
 *                       v1.0 servers.
 * @param username      logged-in user's name.
 * @param userId        ULID of the user row in the daemon's DB.
 * @param capabilities  dot-delimited capability flag set
 *                       ({@code containers.write.own_project} etc.).
 * @param projects      projects the user is a member of.
 * @param expiresAt     unix epoch seconds at which the daemon will
 *                       reject this token. v1.0 default lifetime is
 *                       24 hours.
 * @param provider      auth provider that issued this session
 *                       ({@code password-totp} for v1.0).
 * @param sessionId     ULID of the row in the daemon's {@code sessions}
 *                       table; W2 logout uses this to revoke without
 *                       touching the user's other sessions.
 */
public record Session(
    String token,
    String username,
    String userId,
    Set<String> capabilities,
    java.util.List<String> projects,
    long expiresAt,
    String provider,
    String sessionId
) {

    public Session {
        if (token == null || !token.startsWith("ttiowbs_")) {
            throw new IllegalArgumentException(
                "token must be a workbench bearer (ttiowbs_...); got: " + token);
        }
        if (username == null || username.isEmpty()) {
            throw new IllegalArgumentException("username required");
        }
        if (capabilities == null) throw new IllegalArgumentException("capabilities");
        if (projects == null)     throw new IllegalArgumentException("projects");
        capabilities = Set.copyOf(capabilities);
        projects     = java.util.List.copyOf(projects);
    }

    public boolean isExpired() {
        return Instant.now().getEpochSecond() >= expiresAt;
    }

    public boolean hasCapability(String name) {
        return capabilities.contains(name);
    }

    public String authorizationHeader() {
        return "Bearer " + token;
    }
}
