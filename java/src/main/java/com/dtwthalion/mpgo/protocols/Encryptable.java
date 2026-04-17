/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo.protocols;

import com.dtwthalion.mpgo.Enums.EncryptionLevel;

/**
 * Objects implementing {@code Encryptable} support MPEG-G-style
 * multi-level content protection. Encryption can be applied at
 * dataset-group, dataset, descriptor-stream, or access-unit
 * granularity, enabling selective protection (for example, encrypting
 * intensity values while leaving m/z and scan metadata readable for
 * indexing and search).
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code MPGOEncryptable}, Python
 * {@code mpeg_o.protocols.Encryptable}.</p>
 *
 * @since 0.6
 */
public interface Encryptable {

    /**
     * Encrypt this object's protectable content at the given granularity.
     *
     * @param key   raw key material; length and format are algorithm-specific
     * @param level the granularity at which to apply protection
     * @throws Exception if encryption fails (key material invalid, I/O error, etc.)
     */
    void encryptWithKey(byte[] key, EncryptionLevel level) throws Exception;

    /**
     * Decrypt previously-encrypted content.
     *
     * @param key raw key material matching the key used to encrypt
     * @throws Exception if decryption fails (wrong key, data corrupt, etc.)
     */
    void decryptWithKey(byte[] key) throws Exception;

    /** @return the current access policy, or {@code null} if none. */
    Object accessPolicy();

    /**
     * Replace the current access policy.
     *
     * @param policy the new policy object, or {@code null} to clear
     */
    void setAccessPolicy(Object policy);
}
