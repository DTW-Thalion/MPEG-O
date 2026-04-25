/* TTI-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: LGPL-3.0-or-later */
package global.thalion.ttio.protection;

/**
 * High-level verification API.
 *
 * <p>Collapses the three outcomes of a sign-and-verify cycle
 * (valid / invalid / not-signed) into a single enum, plus an
 * {@link Status#ERROR} fallback for I/O failures. Use this instead
 * of {@link SignatureManager} directly when you want to render a
 * status to an end user.</p>
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOVerifier}, Python
 * {@code ttio.verifier.Verifier}.</p>
 *
 * @since 0.6
 */
public final class Verifier {

    /** Sign-and-verify cycle outcome. */
    public enum Status {
        VALID,
        INVALID,
        NOT_SIGNED,
        ERROR
    }

    private Verifier() {}

    /**
     * Verify a signature string against data and key, returning a
     * four-state status.
     *
     * @param data      original bytes (never {@code null})
     * @param signature signature string, or {@code null} / empty for {@code NOT_SIGNED}
     * @param key       32-byte HMAC key
     * @return status
     */
    public static Status verify(byte[] data, String signature, byte[] key) {
        if (signature == null || signature.isEmpty()) return Status.NOT_SIGNED;
        try {
            return SignatureManager.verify(data, signature, key)
                ? Status.VALID : Status.INVALID;
        } catch (RuntimeException e) {
            return Status.ERROR;
        }
    }
}
