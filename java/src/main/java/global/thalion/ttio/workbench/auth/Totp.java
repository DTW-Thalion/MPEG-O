/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.auth;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.security.GeneralSecurityException;
import java.time.Clock;

/**
 * RFC 6238 TOTP generator matching {@code tti-workbench-server}'s
 * {@code TTIOWBTotp} (HMAC-SHA1, 30-second time-step, 6 digits,
 * T0 = 0).
 *
 * <p>The server tolerates +/- 1 step skew (60 seconds total
 * window). Clients should re-fetch the current TOTP just before
 * the login POST; the server has 90 seconds total of skew
 * tolerance from the second the code is produced, which is plenty
 * for any production-quality NTP setup.</p>
 *
 * <p>Cross-language equivalent: Python {@code ttio.workbench.auth.current_totp}.</p>
 */
public final class Totp {

    /** Time-step in seconds (RFC 6238 default + workbench server pin). */
    private static final long STEP_SECONDS = 30L;

    /** TOTP digit count (RFC 4226 default + workbench server pin). */
    private static final int DIGITS = 6;

    private Totp() {}

    /** Compute the current TOTP using the system clock. */
    public static String current(String secretBase32) {
        return current(secretBase32, Clock.systemUTC());
    }

    /** Compute the current TOTP using {@code clock} (test seam). */
    public static String current(String secretBase32, Clock clock) {
        long counter = clock.instant().getEpochSecond() / STEP_SECONDS;
        return atCounter(secretBase32, counter);
    }

    /** Compute the TOTP for a specific RFC 6238 counter. Useful for
     *  test vectors. */
    public static String atCounter(String secretBase32, long counter) {
        byte[] key = base32Decode(secretBase32);
        byte[] msg = ByteBuffer.allocate(8)
            .order(ByteOrder.BIG_ENDIAN)
            .putLong(counter)
            .array();
        byte[] mac;
        try {
            Mac hmac = Mac.getInstance("HmacSHA1");
            hmac.init(new SecretKeySpec(key, "HmacSHA1"));
            mac = hmac.doFinal(msg);
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException(
                "HmacSHA1 unavailable on this JVM", e);
        }
        int off = mac[mac.length - 1] & 0x0F;
        int code = ((mac[off]     & 0x7F) << 24)
                 | ((mac[off + 1] & 0xFF) << 16)
                 | ((mac[off + 2] & 0xFF) << 8)
                 |  (mac[off + 3] & 0xFF);
        int modulus = (int) Math.pow(10, DIGITS);
        return String.format("%0" + DIGITS + "d", code % modulus);
    }

    /** Standard RFC 4648 base32 decode -- the format the daemon's
     *  bootstrap-credentials file writes (matches Python's
     *  {@code base64.b32decode}). */
    static byte[] base32Decode(String s) {
        String stripped = s.replaceAll("=+$", "").toUpperCase();
        java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
        int buffer = 0;
        int bits = 0;
        for (int i = 0; i < stripped.length(); i++) {
            char c = stripped.charAt(i);
            int v;
            if (c >= 'A' && c <= 'Z') v = c - 'A';
            else if (c >= '2' && c <= '7') v = c - '2' + 26;
            else throw new IllegalArgumentException("bad base32 char: " + c);
            buffer = (buffer << 5) | v;
            bits += 5;
            if (bits >= 8) {
                bits -= 8;
                out.write((buffer >> bits) & 0xFF);
            }
        }
        return out.toByteArray();
    }
}
