/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.auth;

/**
 * v1.1 stub. Spec section 10.1 marks OIDC as the primary
 * production auth mechanism; v1.0 servers only speak password +
 * TOTP. This class exists so the spec section 8.3-shaped sample
 * ({@code WorkbenchClient.connect(url, new OIDCAuth())}) is
 * import-clean today; calling {@link #authenticate(String, int, String)}
 * raises a clear "v1.1" error rather than a misleading login failure.
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.auth_providers.OIDCAuth}.</p>
 */
public final class OIDCAuth implements AuthProvider {

    private final String issuer;
    private final String clientId;

    public OIDCAuth() { this(null, null); }

    public OIDCAuth(String issuer, String clientId) {
        this.issuer = issuer;
        this.clientId = clientId;
    }

    public String issuer()   { return issuer; }
    public String clientId() { return clientId; }

    @Override
    public String username() {
        throw new UnsupportedOperationException(
            "OIDC auth is a v1.1 feature; the v1.0 workbench server "
            + "speaks password + TOTP only. Use "
            + "`new PasswordTotpAuth(username, password, totp)` instead.");
    }

    @Override
    public Session authenticate(String host, int port, String scheme) {
        throw new UnsupportedOperationException(
            "OIDC auth is a v1.1 feature; the v1.0 workbench server "
            + "speaks password + TOTP only. Use "
            + "`new PasswordTotpAuth(username, password, totp)` instead.");
    }
}
