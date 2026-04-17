/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo.providers;

import java.util.*;

/**
 * Provider registry + factory. Discovers implementations via
 * {@link java.util.ServiceLoader} (service file
 * {@code META-INF/services/com.dtwthalion.mpgo.providers.StorageProvider}).
 * In-process registration is also supported for tests.
 *
 * <p>API status: Stable (Provisional per M39 — may change before v1.0).</p>
 *
 * <p>Cross-language equivalents:
 * <ul>
 *   <li>Objective-C: {@code MPGOProviderRegistry} (singleton class)</li>
 *   <li>Python: module-level functions in {@code mpeg_o.providers}
 *       ({@code discover_providers}, {@code open_provider},
 *       {@code register_provider}) — idiomatic for Python packaging.</li>
 * </ul>
 *
 * @since 0.6
 */
public final class ProviderRegistry {

    private static final Map<String, Class<? extends StorageProvider>> OVERRIDES =
            new LinkedHashMap<>();

    private ProviderRegistry() {}

    /** Register (or override) a provider by short name. */
    public static synchronized void register(String name,
                                               Class<? extends StorageProvider> cls) {
        OVERRIDES.put(name, cls);
    }

    /** Clear an in-process override (does not affect ServiceLoader entries). */
    public static synchronized void unregister(String name) {
        OVERRIDES.remove(name);
    }

    /** All known providers, keyed by short name. */
    public static synchronized Map<String, Class<? extends StorageProvider>> discover() {
        Map<String, Class<? extends StorageProvider>> out = new LinkedHashMap<>();
        ServiceLoader<StorageProvider> loader = ServiceLoader.load(StorageProvider.class);
        for (StorageProvider p : loader) {
            out.put(p.providerName(), p.getClass());
        }
        // Fallback if ServiceLoader metadata didn't land (e.g. split
        // classpath in tests before maven-resources copies it).
        out.putIfAbsent("hdf5", Hdf5Provider.class);
        out.putIfAbsent("memory", MemoryProvider.class);
        out.putAll(OVERRIDES);
        return out;
    }

    /** Open the appropriate provider for the given URL or path. */
    public static StorageProvider open(String pathOrUrl,
                                        StorageProvider.Mode mode) {
        return open(pathOrUrl, mode, null);
    }

    /** Open with an explicit provider name override (bypasses URL detection). */
    public static StorageProvider open(String pathOrUrl,
                                        StorageProvider.Mode mode,
                                        String providerName) {
        Map<String, Class<? extends StorageProvider>> registry = discover();

        Class<? extends StorageProvider> cls;
        if (providerName != null) {
            cls = registry.get(providerName);
            if (cls == null) {
                throw new IllegalArgumentException(
                        "unknown provider '" + providerName + "'. Known: "
                        + registry.keySet());
            }
        } else {
            cls = null;
            for (StorageProvider p : ServiceLoader.load(StorageProvider.class)) {
                if (p.supportsUrl(pathOrUrl)) {
                    cls = p.getClass();
                    break;
                }
            }
            if (cls == null) {
                // Try instances of the fallbacks
                for (Class<? extends StorageProvider> candidate : registry.values()) {
                    try {
                        StorageProvider inst = candidate.getDeclaredConstructor().newInstance();
                        if (inst.supportsUrl(pathOrUrl)) {
                            cls = candidate;
                            break;
                        }
                    } catch (ReflectiveOperationException ignored) {}
                }
            }
            if (cls == null) {
                throw new IllegalArgumentException(
                        "no registered provider supports URL: " + pathOrUrl);
            }
        }

        StorageProvider provider;
        try {
            provider = cls.getDeclaredConstructor().newInstance();
        } catch (ReflectiveOperationException e) {
            throw new IllegalStateException(
                    "provider " + cls + " lacks a no-arg constructor", e);
        }
        return provider.open(pathOrUrl, mode);
    }
}
