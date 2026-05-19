/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.auth;

/**
 * Base class for {@code /v1/auth/login} failures against
 * {@code tti-workbench-server}.
 *
 * <p>The three concrete subclasses correspond 1-to-1 with the
 * server's auth-handler HTTP responses (see
 * {@code tti-workbench-server/Source/HTTP/handlers/TTIOWBAuthHandler.m}):
 * 401 -> {@link InvalidCredentialsException}, 423 ->
 * {@link AccountDisabledException}, 429 -> {@link RateLimitExceededException}.
 * Other failures (5xx, network, malformed response) surface as the
 * base {@code WorkbenchAuthException}.</p>
 */
public class WorkbenchAuthException extends RuntimeException {

    public WorkbenchAuthException(String message) {
        super(message);
    }

    public WorkbenchAuthException(String message, Throwable cause) {
        super(message, cause);
    }
}
