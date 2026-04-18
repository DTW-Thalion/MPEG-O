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
 * parameter backed by this catalog. The intent is to shape the
 * parameter hole so M49's post-quantum binding is a pure plug-in —
 * no API change — once ML-KEM-1024 / ML-DSA-87 are ready.</p>
 *
 * <p><b>No new algorithms are activated by M48.</b>
 * {@code "ml-kem-1024"}, {@code "ml-dsa-87"}, {@code "shake256"}
 * entries are reserved: their metadata is recorded, but
 * {@link #validateKey} on those names raises
 * {@link UnsupportedAlgorithmException} until M49 adds the actual
 * primitive.</p>
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

    /** Catalog entry. Immutable. */
    public record Entry(
        String algorithm,
        Category category,
        /** Fixed key length in bytes, or {@code -1} if variable
         *  (HMAC). */
        int keySize,
        /** Nonce / IV length in bytes; zero for non-AEAD primitives. */
        int nonceSize,
        /** Auth-tag or signature size in bytes. */
        int tagSize,
        Status status,
        String notes
    ) {}

    private static final Map<String, Entry> CATALOG;
    static {
        Map<String, Entry> m = new LinkedHashMap<>();
        m.put("aes-256-gcm", new Entry(
            "aes-256-gcm", Category.AEAD, 32, 12, 16, Status.ACTIVE,
            "Default for bulk encryption and envelope wrapping."
        ));
        m.put("ml-kem-1024", new Entry(
            "ml-kem-1024", Category.KEM, 1568, 0, 0, Status.RESERVED,
            "NIST FIPS 203 ML-KEM-1024. Activates in M49 via Bouncy Castle PQC."
        ));
        m.put("hmac-sha256", new Entry(
            "hmac-sha256", Category.MAC, -1, 0, 32, Status.ACTIVE,
            "Default for v2 canonical signatures."
        ));
        m.put("ml-dsa-87", new Entry(
            "ml-dsa-87", Category.SIGNATURE, 4864, 0, 4627, Status.RESERVED,
            "NIST FIPS 204 ML-DSA-87. Activates in M49 via Bouncy Castle PQC."
        ));
        m.put("sha-256", new Entry(
            "sha-256", Category.HASH, 0, 0, 32, Status.ACTIVE,
            "Default hash primitive for canonical transcripts."
        ));
        m.put("shake256", new Entry(
            "shake256", Category.XOF, 0, 0, 0, Status.RESERVED,
            "SHA-3 family extendable-output function; reserved for M49."
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
     *  algorithms. Replaces inline {@code key.length != 32} checks. */
    public static void validateKey(String algorithm, byte[] key) {
        Entry e = requireActive(algorithm);
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
