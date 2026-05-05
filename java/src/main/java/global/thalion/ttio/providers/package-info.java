/**
 * Storage/transport provider abstraction — .
 *
 * The TTI-O data model and API are the standard; the storage
 * backend is a pluggable implementation detail. Providers register
 * via {@link java.util.ServiceLoader} (service interface:
 * {@link global.thalion.ttio.providers.StorageProvider}) and are
 * resolved by URL scheme or explicit name.
 *
 * Two providers ship with v0.6:
 * <ul>
 *   <li>{@link global.thalion.ttio.providers.Hdf5Provider} — wraps
 *   the existing {@link global.thalion.ttio.hdf5.Hdf5File}.</li>
 *   <li>{@link global.thalion.ttio.providers.MemoryProvider} —
 *   in-memory tree for tests and transient pipelines.</li>
 * </ul>
 *
 * <p><b>API status:</b> Stable (Provisional per M39 — may change
 * before v1.0).</p>
 *
 *
 */
package global.thalion.ttio.providers;
