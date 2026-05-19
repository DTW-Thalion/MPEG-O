/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench;

import global.thalion.ttio.workbench.auth.Session;

import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Direct tests for the {@link Session} record's validation +
 * accessors. The {@code Login} path drives Session construction
 * in production but it's excluded from coverage (deferred
 * daemon-integration tests); these tests cover the constructor
 * branches directly.
 */
class SessionTest {

    private static Session sample() {
        return new Session(
            "ttiowbs_abc",
            "alice",
            "01HXYUSR",
            Set.of("containers.read.any_project"),
            List.of("alpha", "beta"),
            2_000_000_000L,
            "password-totp",
            "01HXYSES");
    }

    @Test
    void authorizationHeaderHasBearerPrefix() {
        assertEquals("Bearer ttiowbs_abc", sample().authorizationHeader());
    }

    @Test
    void hasCapabilityChecksContainment() {
        Session s = sample();
        assertTrue(s.hasCapability("containers.read.any_project"));
        assertFalse(s.hasCapability("sessions.start"));
    }

    @Test
    void notExpiredFor2034Token() {
        // Sample expires in 2033-ish; "now" comparison is current
        // system clock. Test passes until 2033, after which the
        // baseline epoch becomes stale (intentional sentinel).
        assertFalse(sample().isExpired());
    }

    @Test
    void expiredFor1970Token() {
        Session s = new Session(
            "ttiowbs_abc", "alice", "01HXYUSR",
            Set.of(), List.of(),
            0L, "password-totp", "01HXYSES");
        assertTrue(s.isExpired());
    }

    @Test
    void rejectsWrongTokenPrefix() {
        assertThrows(IllegalArgumentException.class,
            () -> new Session(
                "wrong_prefix_abc", "alice", "01HXYUSR",
                Set.of(), List.of(), 2_000_000_000L,
                "password-totp", "01HXYSES"));
    }

    @Test
    void rejectsNullToken() {
        assertThrows(IllegalArgumentException.class,
            () -> new Session(
                null, "alice", "01HXYUSR",
                Set.of(), List.of(), 2_000_000_000L,
                "password-totp", "01HXYSES"));
    }

    @Test
    void rejectsEmptyUsername() {
        assertThrows(IllegalArgumentException.class,
            () -> new Session(
                "ttiowbs_abc", "", "01HXYUSR",
                Set.of(), List.of(), 2_000_000_000L,
                "password-totp", "01HXYSES"));
    }

    @Test
    void rejectsNullCapabilities() {
        assertThrows(IllegalArgumentException.class,
            () -> new Session(
                "ttiowbs_abc", "alice", "01HXYUSR",
                null, List.of(), 2_000_000_000L,
                "password-totp", "01HXYSES"));
    }

    @Test
    void rejectsNullProjects() {
        assertThrows(IllegalArgumentException.class,
            () -> new Session(
                "ttiowbs_abc", "alice", "01HXYUSR",
                Set.of(), null, 2_000_000_000L,
                "password-totp", "01HXYSES"));
    }

    @Test
    void capabilitiesAndProjectsAreDefensivelyCopied() {
        Set<String> caps = new java.util.HashSet<>();
        caps.add("a");
        List<String> projs = new java.util.ArrayList<>();
        projs.add("alpha");
        Session s = new Session(
            "ttiowbs_abc", "alice", "01HXYUSR",
            caps, projs, 2_000_000_000L,
            "password-totp", "01HXYSES");
        caps.clear();
        projs.clear();
        // Session held its own copies; clearing the originals
        // doesn't affect the session view.
        assertTrue(s.hasCapability("a"));
        assertEquals(List.of("alpha"), s.projects());
    }
}
