/* TTI-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: LGPL-3.0-or-later */
package com.dtwthalion.ttio.protection;

import java.util.Map;

/**
 * Access policy describing who may decrypt which streams in an
 * {@code .tio} file.
 *
 * <p>Stored as a JSON string under
 * {@code /protection/access_policies} on disk, so the policy is
 * human-inspectable and recoverable independently of any
 * key-management system.</p>
 *
 * <p>Schema-free at this layer: the map holds arbitrary key/value
 * pairs the application interprets (typical fields: {@code subjects},
 * {@code streams}, {@code expiry}, {@code key_id},
 * {@code audit_contact}).</p>
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOAccessPolicy}, Python
 * {@code ttio.access_policy.AccessPolicy}.</p>
 *
 * @param policy Arbitrary key/value policy payload.
 * @since 0.6
 */
public record AccessPolicy(Map<String, Object> policy) {
    /**
     * Defensive copy; substitutes empty map for null.
     *
     * @param policy Arbitrary key/value policy payload (null treated as empty).
     */
    public AccessPolicy {
        policy = policy != null ? Map.copyOf(policy) : Map.of();
    }
}
