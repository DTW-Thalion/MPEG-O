/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.auth;

import java.util.Optional;
import java.util.OptionalInt;

/**
 * HTTP 429 on login -- the daemon's per-IP auth bucket is empty.
 * The server includes a {@code Retry-After} header; when present
 * it surfaces here so the caller can sleep before retrying.
 */
public final class RateLimitExceededException extends WorkbenchAuthException {

    private final OptionalInt retryAfterSeconds;

    public RateLimitExceededException(String message,
                                       OptionalInt retryAfterSeconds) {
        super(message);
        this.retryAfterSeconds = Optional.ofNullable(retryAfterSeconds)
            .orElse(OptionalInt.empty());
    }

    /** Server-suggested back-off in seconds, or empty when the
     *  {@code Retry-After} header was absent. */
    public OptionalInt retryAfterSeconds() {
        return retryAfterSeconds;
    }
}
