/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.auth;

import java.util.List;
import java.util.Set;

/**
 * Pre-acquired bearer-token provider. No round-trip on
 * {@link #authenticate(String, int, String)} -- we synthesise a
 * minimal {@link Session} from the inputs. The token's actual
 * expiry / capability set isn't visible to the client; pre-flight
 * failures surface when the first REST or WS call hits the daemon.
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.auth_providers.BearerAuth}.</p>
 */
public final class BearerAuth implements AuthProvider {

    private final String token;
    private final String username;
    private final List<String> projects;
    private final Set<String> capabilities;
    private final long expiresAt;

    public BearerAuth(String token, String username) {
        this(token, username, List.of(), Set.of(), 0L);
    }

    public BearerAuth(String token, String username,
                       List<String> projects,
                       Set<String> capabilities,
                       long expiresAt) {
        if (token == null || !token.startsWith("ttiowbs_")) {
            throw new IllegalArgumentException(
                "token must be a workbench bearer (ttiowbs_...); got: " + token);
        }
        if (username == null || username.isEmpty()) {
            throw new IllegalArgumentException("username required");
        }
        this.token = token;
        this.username = username;
        this.projects = List.copyOf(projects);
        this.capabilities = Set.copyOf(capabilities);
        this.expiresAt = expiresAt;
    }

    @Override
    public String username() { return username; }

    @Override
    public Session authenticate(String host, int port, String scheme) {
        return new Session(
            token, username,
            /*userId=*/ "",            // unknown without round-trip
            capabilities, projects,
            expiresAt,
            /*provider=*/ "bearer",
            /*sessionId=*/ "");
    }
}
