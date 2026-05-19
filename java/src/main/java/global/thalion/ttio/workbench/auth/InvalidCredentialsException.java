/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.auth;

/**
 * HTTP 401 on login -- the server collapses bad username, bad
 * password, and bad TOTP to one response to defeat brute-force
 * username enumeration.
 */
public final class InvalidCredentialsException extends WorkbenchAuthException {

    public InvalidCredentialsException(String message) {
        super(message);
    }
}
