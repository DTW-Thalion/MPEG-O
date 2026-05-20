/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.encryption;

/**
 * Client payload-protection mode (spec UC-03.2/3).
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.encryption.ProtectionMode}.</p>
 */
public enum ProtectionMode {
    /** Researcher brings their own 32-byte DEK; key never leaves the
     *  client, so the protection carries no wrapped key. */
    BYOK,
    /** A fresh random DEK seals the payload and is wrapped under a KEK
     *  (AES-256-GCM symmetric, or ML-KEM-1024 public key). */
    ENVELOPE
}
