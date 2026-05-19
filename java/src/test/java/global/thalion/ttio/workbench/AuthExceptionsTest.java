/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench;

import global.thalion.ttio.workbench.auth.AccountDisabledException;
import global.thalion.ttio.workbench.auth.InvalidCredentialsException;
import global.thalion.ttio.workbench.auth.RateLimitExceededException;
import global.thalion.ttio.workbench.auth.WorkbenchAuthException;

import org.junit.jupiter.api.Test;

import java.util.OptionalInt;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Direct construction tests for the auth exception hierarchy.
 * Production wiring throws these from {@code Login}, which is
 * excluded from coverage; these tests cover the constructor
 * branches.
 */
class AuthExceptionsTest {

    @Test
    void workbenchAuthExceptionMessage() {
        WorkbenchAuthException e = new WorkbenchAuthException("bang");
        assertEquals("bang", e.getMessage());
    }

    @Test
    void workbenchAuthExceptionMessageWithCause() {
        Throwable cause = new RuntimeException("inner");
        WorkbenchAuthException e = new WorkbenchAuthException("outer", cause);
        assertEquals("outer", e.getMessage());
        assertSame(cause, e.getCause());
    }

    @Test
    void invalidCredentials() {
        InvalidCredentialsException e = new InvalidCredentialsException("bad creds");
        assertEquals("bad creds", e.getMessage());
        assertInstanceOf(WorkbenchAuthException.class, e);
    }

    @Test
    void accountDisabled() {
        AccountDisabledException e = new AccountDisabledException("disabled");
        assertEquals("disabled", e.getMessage());
        assertInstanceOf(WorkbenchAuthException.class, e);
    }

    @Test
    void rateLimitWithRetryAfter() {
        RateLimitExceededException e = new RateLimitExceededException(
            "slow down", OptionalInt.of(30));
        assertEquals("slow down", e.getMessage());
        assertEquals(30, e.retryAfterSeconds().getAsInt());
    }

    @Test
    void rateLimitWithoutRetryAfter() {
        RateLimitExceededException e = new RateLimitExceededException(
            "slow down", OptionalInt.empty());
        assertTrue(e.retryAfterSeconds().isEmpty());
    }

    @Test
    void rateLimitWithNullRetryAfter() {
        RateLimitExceededException e = new RateLimitExceededException(
            "slow down", null);
        assertTrue(e.retryAfterSeconds().isEmpty());
    }
}
