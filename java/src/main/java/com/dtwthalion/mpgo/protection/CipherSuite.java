/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo.protection;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Cipher-suite catalog and algorithm-dispatched parameter helpers
 * (v0.7 M48).
 *
 * <p>Pre-v0.7, encryption / signing / key-wrap APIs accepted an
 * implicit fixed algorithm (AES-256-GCM for bulk, HMAC-SHA256 for
 * signatures, AES-KW-style wrap for KEK). Key sizes and nonce lengths
 * were hardcoded module-level constants.</p>
 *
 * <p>v0.7 M48 generalises the public API with an {@code algorithm}
 * parameter backed by this catalog. The intent was to shape the
 * parameter hole so M49's post-quantum binding is a pure plug-in —
 * no API change — once ML-KEM-1024 / ML-DSA-87 are ready.</p>
 *
 * <p>v0.8 M49 activates the PQC entries. {@code "ml-kem-1024"} (FIPS
 * 203) and {@code "ml-dsa-87"} (FIPS 204) transition from
 * {@code RESERVED} to {@code ACTIVE}. The Java implementation uses
 * <b>Bouncy Castle</b> 1.79+ as the PQC provider (see
 * {@link PostQuantumCrypto}). Python and Objective-C use liboqs
 * instead — the Java path is different because liboqs's Java bindings
 * are immature and BC 1.79+ ships FIPS-compliant PQC natively. See
 * {@code docs/pqc.md} for the discrepancy rationale.</p>
 *
 * <p>{@code "shake256"} remains reserved in v0.8 (no consumer yet in
 * the protection APIs).</p>
 *
 * <p>Design note (binding decision 39): {@code CipherSuite} is a
 * <b>static allow-list</b>, not a plugin registry. Adding a new
 * algorithm is a source-code change. Runtime registration would let
 * callers push FIPS-unapproved algorithms through production code;
 * that complexity is deferred to v0.8+.</p>
 *
 * <p><b>Cross-language equivalents:</b> ObjC {@code MPGOCipherSuite},
 * Python {@code mpeg_o.cipher_suite}.</p>
 *
 * @since 0.7
 */
public final class CipherSuite {

    private CipherSuite() {}

    /** Category tag for catalog entries. */
    public enum Category { AEAD, KEM, MAC, SIGNATURE, HASH, XOF }

    /** Status tag; only {@link Status#ACTIVE} algorithms may be
     *  used for encrypt / sign / wrap operations. */
    public enum Status { ACTIVE, RESERVED }

    /** Catalog entry. Immutable.
     *
     * <p>For symmetric algorithms (AEAD / MAC / Hash / XOF),
     * {@code keySize} is the single key length. For asymmetric
     * algorithms (KEM / Signature), {@code keySize} is the
     * <i>public</i> key length and {@code privateKeySize} is the
     * decapsulation / signing key length.</p>
     */
    public record Entry(
        String algorithm,
        Category category,
        /** Symmetric key size, OR (for KEM/Signature) PUBLIC key length
         *  in bytes. {@code -1} = variable (HMAC). */
        int keySize,
        /** Nonce / IV length in bytes; zero for non-AEAD primitives. */
        int nonceSize,
        /** Auth-tag or signature size in bytes. */
        int tagSize,
        Status status,
        String notes,
        /** KEM / Signature: private (decaps / signing) key length in
         *  bytes. {@code 0} for symmetric algorithms. @since 0.8 */
        int privateKeySize
    ) {
        /** Shorthand for symmetric entries (keeps the M48 ctor shape
         *  working). */
        public Entry(String algorithm, Category category, int keySize,
                     int nonceSize, int tagSize, Status status,
                     String notes) {
            this(algorithm, category, keySize, nonceSize, tagSize,
                 status, notes, /* privateKeySize= */ 0);
        }
    }

    private static final Map<String, Entry> CATALOG;
    static {
        Map<String, Entry> m = new LinkedHashMap<>();
        m.put("aes-256-gcm", new Entry(
            "aes-256-gcm", Category.AEAD, 32, 12, 16, Status.ACTIVE,
            "Default for bulk encryption and envelope wrapping."
        ));
        m.put("ml-kem-1024", new Entry(
            "ml-kem-1024", Category.KEM,
            /* publicKeySize= */ 1568, 0, 0, Status.ACTIVE,
            "NIST FIPS 203 ML-KEM-1024. v0.8 M49 via Bouncy Castle. "
            + "Python / ObjC path uses liboqs; see docs/pqc.md.",
            /* privateKeySize= */ 3168
        ));
        m.put("hmac-sha256", new Entry(
            "hmac-sha256", Category.MAC, -1, 0, 32, Status.ACTIVE,
            "Default for v2 canonical signatures."
        ));
        m.put("ml-dsa-87", new Entry(
            "ml-dsa-87", Category.SIGNATURE,
            /* publicKeySize= */ 2592, 0, 4627, Status.ACTIVE,
            "NIST FIPS 204 ML-DSA-87. v0.8 M49 via Bouncy Castle. "
            + "Emits v3: signature-attribute prefix.",
            /* privateKeySize= */ 4896
        ));
        m.put("sha-256", new Entry(
            "sha-256", Category.HASH, 0, 0, 32, Status.ACTIVE,
            "Default hash primitive for canonical transcripts."
        ));
        m.put("shake256", new Entry(
            "shake256", Category.XOF, 0, 0, 0, Status.RESERVED,
            "SHA-3 family extendable-output function; reserved."
        ));
        CATALOG = Collections.unmodifiableMap(m);
    }

    // ── Catalog API ──────────────────────────────────────────────

    /** True iff {@code algorithm} is a known catalog entry with
     *  status ACTIVE. Reserved entries return false. */
    public static boolean isSupported(String algorithm) {
        Entry e = CATALOG.get(algorithm);
        return e != null && e.status == Status.ACTIVE;
    }

    /** True iff {@code algorithm} is listed in the catalog, including
     *  reserved entries. Useful for error messages that distinguish
     *  'unknown' from 'not yet implemented'. */
    public static boolean isRegistered(String algorithm) {
        return CATALOG.containsKey(algorithm);
    }

    public static Category category(String algorithm) {
        return require(algorithm).category;
    }

    /** @return the fixed key length in bytes, or {@code -1} for
     *          variable-length keys (HMAC). */
    public static int keyLength(String algorithm) {
        return require(algorithm).keySize;
    }

    /** @return the nonce / IV length in bytes. Zero for non-AEAD
     *          primitives. Replaces hardcoded {@code IV_BYTES = 12}
     *          constants. */
    public static int nonceLength(String algorithm) {
        return require(algorithm).nonceSize;
    }

    /** @return the tag / signature length in bytes. */
    public static int tagLength(String algorithm) {
        return require(algorithm).tagSize;
    }

    /** Raise {@link InvalidKeyException} if {@code key} does not
     *  match the algorithm's required length. Raise
     *  {@link UnsupportedAlgorithmException} for reserved or unknown
     *  algorithms.
     *
     *  <p>Asymmetric algorithms (KEM / Signature) raise
     *  {@link InvalidKeyException} directing the caller to
     *  {@link #validatePublicKey} / {@link #validatePrivateKey}; this
     *  keeps role confusion out of the symmetric-focused call sites
     *  (pre-M49 callers pass only symmetric keys here).</p>
     */
    public static void validateKey(String algorithm, byte[] key) {
        Entry e = requireActive(algorithm);
        if (e.category == Category.KEM || e.category == Category.SIGNATURE) {
            throw new InvalidKeyException(
                algorithm + " is asymmetric — use validatePublicKey "
                + "or validatePrivateKey instead of validateKey");
        }
        if (e.keySize < 0) {
            // Variable-length: HMAC tolerates anything non-empty.
            if (key.length == 0) {
                throw new InvalidKeyException(
                    algorithm + ": key must be non-empty (got 0 bytes)");
            }
            return;
        }
        if (key.length != e.keySize) {
            throw new InvalidKeyException(
                algorithm + ": key must be " + e.keySize
                + " bytes (got " + key.length + ")");
        }
    }

    /** Raise {@link InvalidKeyException} if {@code key} is not the
     *  right length for {@code algorithm}'s <b>public</b> key (KEM
     *  encapsulation / signature verification). Symmetric algorithms
     *  raise. @since 0.8 */
    public static void validatePublicKey(String algorithm, byte[] key) {
        Entry e = requireActive(algorithm);
        if (e.category != Category.KEM && e.category != Category.SIGNATURE) {
            throw new InvalidKeyException(
                algorithm + " is symmetric; use validateKey instead");
        }
        if (key.length != e.keySize) {
            throw new InvalidKeyException(
                algorithm + ": public key must be " + e.keySize
                + " bytes (got " + key.length + ")");
        }
    }

    /** Raise {@link InvalidKeyException} if {@code key} is not the
     *  right length for {@code algorithm}'s <b>private</b> key (KEM
     *  decapsulation / signing). Symmetric algorithms raise. @since 0.8 */
    public static void validatePrivateKey(String algorithm, byte[] key) {
        Entry e = requireActive(algorithm);
        if (e.category != Category.KEM && e.category != Category.SIGNATURE) {
            throw new InvalidKeyException(
                algorithm + " is symmetric; use validateKey instead");
        }
        if (e.privateKeySize <= 0) {
            throw new InvalidKeyException(
                algorithm + ": catalog entry is missing privateKeySize");
        }
        if (key.length != e.privateKeySize) {
            throw new InvalidKeyException(
                algorithm + ": private key must be " + e.privateKeySize
                + " bytes (got " + key.length + ")");
        }
    }

    /** @return asymmetric public-key length in bytes. Raises for
     *          symmetric algorithms. @since 0.8 */
    public static int publicKeySize(String algorithm) {
        Entry e = require(algorithm);
        if (e.category != Category.KEM && e.category != Category.SIGNATURE) {
            throw new UnsupportedAlgorithmException(
                algorithm + " is symmetric — no public key");
        }
        return e.keySize;
    }

    /** @return asymmetric private-key length in bytes. Raises for
     *          symmetric algorithms. @since 0.8 */
    public static int privateKeySize(String algorithm) {
        Entry e = require(algorithm);
        if (e.category != Category.KEM && e.category != Category.SIGNATURE) {
            throw new UnsupportedAlgorithmException(
                algorithm + " is symmetric — no private key");
        }
        if (e.privateKeySize <= 0) {
            throw new UnsupportedAlgorithmException(
                algorithm + ": catalog entry is missing privateKeySize");
        }
        return e.privateKeySize;
    }

    /** @return all catalog entries (active + reserved). */
    public static List<Entry> allEntries() {
        return List.copyOf(CATALOG.values());
    }

    // ── Exception types ──────────────────────────────────────────

    /** Thrown when a caller specifies an algorithm not in the
     *  catalog, or one with status RESERVED (activates in a later
     *  milestone). */
    public static final class UnsupportedAlgorithmException
            extends RuntimeException {
        private static final long serialVersionUID = 1L;
        public UnsupportedAlgorithmException(String message) {
            super(message);
        }
    }

    /** Thrown when a key's length does not match the selected
     *  algorithm. Extends RuntimeException for API-ergonomic reasons
     *  (key validation is a precondition, not an expected failure
     *  path). */
    public static final class InvalidKeyException extends RuntimeException {
        private static final long serialVersionUID = 1L;
        public InvalidKeyException(String message) { super(message); }
    }

    // ── Internal ─────────────────────────────────────────────────

    private static Entry require(String algorithm) {
        Entry e = CATALOG.get(algorithm);
        if (e == null) {
            throw new UnsupportedAlgorithmException(
                "unknown algorithm: " + algorithm
                + " (catalog: " + CATALOG.keySet() + ")");
        }
        return e;
    }

    private static Entry requireActive(String algorithm) {
        Entry e = require(algorithm);
        if (e.status != Status.ACTIVE) {
            throw new UnsupportedAlgorithmException(
                algorithm + " is in the catalog but has status "
                + e.status + " — this build does not ship the "
                + "primitive. Reserved algorithms activate in later "
                + "milestones (M49 for ml-kem-1024 / ml-dsa-87).");
        }
        return e;
    }
}
