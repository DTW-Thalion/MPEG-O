/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.auth;

/**
 * Interactive credentials provider. The TOTP is computed once at
 * construction time; if it has expired by the time
 * {@link #authenticate(String, int, String)} runs, login will fail
 * with {@link InvalidCredentialsException} and the caller must
 * construct a new provider.
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.auth_providers.PasswordTotpAuth}.</p>
 */
public final class PasswordTotpAuth implements AuthProvider {

    private final String username;
    private final String password;
    private final String totp;

    public PasswordTotpAuth(String username, String password, String totp) {
        if (username == null || username.isEmpty()) {
            throw new IllegalArgumentException("username required");
        }
        if (password == null) {
            throw new IllegalArgumentException("password required");
        }
        if (totp == null || totp.isEmpty()) {
            throw new IllegalArgumentException("totp required");
        }
        this.username = username;
        this.password = password;
        this.totp = totp;
    }

    @Override
    public String username() { return username; }

    @Override
    public Session authenticate(String host, int port, String scheme) {
        return Login.loginPassword(host, port, username, password, totp,
                                     scheme, java.time.Duration.ofSeconds(5));
    }
}
