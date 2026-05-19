/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.auth;

/**
 * Pluggable auth provider for the W2 SDK.
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.auth_providers.AuthProvider}. Both clients
 * accept the same four concrete providers
 * ({@link PasswordTotpAuth}, {@link BearerAuth},
 * {@link BootstrapAdminAuth}, {@link OIDCAuth} stub), and
 * {@link global.thalion.ttio.workbench.WorkbenchClient#connect}
 * mirrors {@code ttio.workbench.connect}.</p>
 *
 * <p>Each provider exposes the username it should attribute
 * uploads to plus an {@link #authenticate(String, int, String)}
 * method that returns a {@link Session}. The SDK caches the
 * session on the client; re-login is the caller's choice (no
 * automatic refresh in v1.0).</p>
 */
public interface AuthProvider {

    /** Resolve to an authenticated {@link Session}. Called once
     *  by {@code WorkbenchClient.connect()}. Implementations raise
     *  {@link WorkbenchAuthException} on failure. */
    Session authenticate(String host, int port, String scheme);

    /** Username the SDK will attribute uploads to (the WS
     *  handshake {@code owner} field). Surfaced ahead of the WS
     *  open so the SDK can validate without a daemon round-trip. */
    String username();
}
