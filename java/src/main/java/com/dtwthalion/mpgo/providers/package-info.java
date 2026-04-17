/**
 * Storage/transport provider abstraction — Milestone 39.
 *
 * The MPEG-O data model and API are the standard; the storage
 * backend is a pluggable implementation detail. Providers register
 * via {@link java.util.ServiceLoader} (service interface:
 * {@link com.dtwthalion.mpgo.providers.StorageProvider}) and are
 * resolved by URL scheme or explicit name.
 *
 * Two providers ship with v0.6:
 * <ul>
 *   <li>{@link com.dtwthalion.mpgo.providers.Hdf5Provider} — wraps
 *   the existing {@link com.dtwthalion.mpgo.hdf5.Hdf5File}.</li>
 *   <li>{@link com.dtwthalion.mpgo.providers.MemoryProvider} —
 *   in-memory tree for tests and transient pipelines.</li>
 * </ul>
 *
 * <p><b>API status:</b> Stable (Provisional per M39 — may change
 * before v1.0).</p>
 *
 * @since 0.6
 */
package com.dtwthalion.mpgo.providers;
