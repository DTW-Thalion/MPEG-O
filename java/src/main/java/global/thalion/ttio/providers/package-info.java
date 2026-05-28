/**
 * Storage/transport provider abstraction.
 *
 * <p>The TTI-O data model and API are the standard; the storage
 * backend is a pluggable implementation detail. Providers register
 * via {@link java.util.ServiceLoader} (service interface:
 * {@link global.thalion.ttio.providers.StorageProvider}) and are
 * resolved by URL scheme or explicit name.</p>
 *
 * <p>Four providers ship in the box:</p>
 * <ul>
 *   <li>{@link global.thalion.ttio.providers.Hdf5Provider} — wraps
 *   {@link global.thalion.ttio.hdf5.Hdf5File} for HDF5 containers.</li>
 *   <li>{@link global.thalion.ttio.providers.MemoryProvider} —
 *   in-memory tree for tests and transient pipelines.</li>
 *   <li>{@link global.thalion.ttio.providers.SqliteProvider} —
 *   SQLite-backed containers.</li>
 *   <li>{@link global.thalion.ttio.providers.ZarrProvider} —
 *   Zarr v3 stores.</li>
 * </ul>
 *
 * <p><b>API status:</b> Stable.</p>
 */
package global.thalion.ttio.providers;
