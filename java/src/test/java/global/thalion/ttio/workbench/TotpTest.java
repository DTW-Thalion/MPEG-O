/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench;

import global.thalion.ttio.workbench.auth.Totp;

import org.junit.jupiter.api.Test;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;

import static org.junit.jupiter.api.Assertions.*;

/**
 * RFC 6238 + cross-language equivalence tests for {@link Totp}.
 *
 * <p>The two deterministic vectors are computed by both the
 * server's {@code TTIOWBTotp} and the Python client's
 * {@code current_totp} -- they MUST match here so the three
 * implementations stay byte-compatible.</p>
 */
class TotpTest {

    @Test
    void deterministicVectors() {
        // Same secret + epoch the Python client tests assert on.
        // Cross-language fixture: identical secret + identical
        // epoch must yield identical 6-digit code in Python, Java,
        // and ObjC.
        String secret = "JBSWY3DPEHPK3PXP";
        assertEquals("742275", Totp.current(secret,
            Clock.fixed(Instant.ofEpochSecond(1_234_567_890L), ZoneOffset.UTC)));
        assertEquals("324550", Totp.current(secret,
            Clock.fixed(Instant.ofEpochSecond(1_700_000_000L), ZoneOffset.UTC)));
    }

    @Test
    void changesPerStep() {
        String secret = "JBSWY3DPEHPK3PXP";
        String a = Totp.current(secret,
            Clock.fixed(Instant.ofEpochSecond(1_700_000_000L), ZoneOffset.UTC));
        String b = Totp.current(secret,
            Clock.fixed(Instant.ofEpochSecond(1_700_000_030L), ZoneOffset.UTC));
        assertNotEquals(a, b);
    }

    @Test
    void sixDigits() {
        String code = Totp.current("JBSWY3DPEHPK3PXP");
        assertEquals(6, code.length());
        for (char c : code.toCharArray()) assertTrue(Character.isDigit(c));
    }

    @Test
    void base32DecodeRejectsBadChars() {
        assertThrows(IllegalArgumentException.class,
            () -> Totp.atCounter("not-base32!", 0));
    }
}
