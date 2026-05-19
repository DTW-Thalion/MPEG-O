/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.auth;

import global.thalion.ttio.workbench.WorkbenchJson;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;

/**
 * Reads {@code <staging_root>/bootstrap-credentials.json} (mode
 * 0600, written by {@code tti-workbench-server} on first boot)
 * and logs in as the bootstrap admin.
 *
 * <p>Mirrors the smoke harness path in
 * {@code tti-workbench-server/Tests/load/upload_one.py}. NOT
 * intended for production use -- operators are expected to
 * rotate the bootstrap admin out after first login. Useful for
 * local development and smoke tests.</p>
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.auth_providers.BootstrapAdminAuth}.</p>
 */
public final class BootstrapAdminAuth implements AuthProvider {

    private final String stagingRoot;

    public BootstrapAdminAuth(String stagingRoot) {
        if (stagingRoot == null || stagingRoot.isEmpty()) {
            throw new IllegalArgumentException("stagingRoot required");
        }
        this.stagingRoot = stagingRoot;
    }

    @Override
    @SuppressWarnings("unchecked")
    public String username() {
        Map<String, Object> creds = readCreds();
        Object u = creds.get("username");
        if (!(u instanceof String s)) {
            throw new IllegalStateException(
                "bootstrap-credentials.json missing string `username`");
        }
        return s;
    }

    @Override
    @SuppressWarnings("unchecked")
    public Session authenticate(String host, int port, String scheme) {
        Map<String, Object> creds = readCreds();
        Object u = creds.get("username");
        Object pw = creds.get("password");
        Object secret = creds.get("totp_secret_base32");
        if (!(u instanceof String username) || !(pw instanceof String password)
                || !(secret instanceof String secretB32)) {
            throw new IllegalStateException(
                "bootstrap-credentials.json missing username/password/"
                + "totp_secret_base32 string fields");
        }
        String totp = Totp.current(secretB32);
        return Login.loginPassword(host, port, username, password, totp,
                                     scheme, java.time.Duration.ofSeconds(5));
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> readCreds() {
        Path p = Path.of(stagingRoot, "bootstrap-credentials.json");
        String content;
        try {
            content = Files.readString(p);
        } catch (IOException e) {
            throw new IllegalStateException(
                "could not read " + p + ": " + e.getMessage(), e);
        }
        Object parsed = WorkbenchJson.parse(content);
        if (!(parsed instanceof Map<?, ?> m)) {
            throw new IllegalStateException(
                p + " did not contain a JSON object");
        }
        return (Map<String, Object>) m;
    }
}
