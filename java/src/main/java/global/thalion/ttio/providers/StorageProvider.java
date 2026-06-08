/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.providers;

/**
 * Storage backend entry point.
 *
 * <p>Implementations are discovered via
 * {@link java.util.ServiceLoader}. Each implementation must also
 * expose a no-argument public constructor so the loader can
 * instantiate it; the useful work happens in {@link #open(String, Mode)}.</p>
 *
 * <p>Implementations are required to support the capability floor
 * listed in {@code docs/format-spec.md} — hierarchical groups,
 * typed 1-D datasets, partial reads, chunked storage, compression,
 * compound datasets with VL strings, scalar and array attributes.
 * Unsupported capabilities raise
 * {@link UnsupportedOperationException} at the call site.</p>
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOStorageProvider}, Python
 * {@code ttio.providers.base.StorageProvider}.</p>
 *
 *
 */
public interface StorageProvider extends AutoCloseable {

    /** Open modes mirroring h5py semantics. */
    enum Mode { READ, READ_WRITE, CREATE, APPEND }

    /** Short identifier used for logging and registry lookup. */
    String providerName();

    /** Return {@code true} if this provider supports opening the
     *  given path or URL. Used by the registry to pick a provider by
     *  scheme when the caller hasn't named one explicitly. */
    boolean supportsUrl(String pathOrUrl);

    /** Open the backing store. The provider instance is returned
     *  so chaining is possible: {@code new Hdf5Provider().open(...)}.
     *
     *  <p>Re-opening an already-open provider is an error.</p> */
    StorageProvider open(String pathOrUrl, Mode mode);

    /** Open the backing store with a backend-allocation hint.
     *
     *  <p>{@code largeBlocks} is advisory: when {@code true} the provider
     *  may pre-size its file free-space blocks for a metadata-heavy write
     *  (e.g. an HDF5 genome reference with tens of thousands of contigs).
     *  It affects only where bytes land in the file, never the logical
     *  content, so providers that don't allocate file blocks
     *  (Memory/SQLite/Zarr) ignore it. The default implementation
     *  delegates to {@link #open(String, Mode)} — only {@link Hdf5Provider}
     *  honours the hint. Added for issue #251 (small spectral {@code .tio}
     *  files no longer carry ~8 MB of dead meta-block space).</p>
     *
     *  @param pathOrUrl   backing-store path or URL
     *  @param mode        open mode
     *  @param largeBlocks {@code true} to request large amortising blocks
     *  @return this provider, opened */
    default StorageProvider open(String pathOrUrl, Mode mode, boolean largeBlocks) {
        return open(pathOrUrl, mode);
    }

    /** Root group ("/"). Must be called after {@link #open}. */
    StorageGroup rootGroup();

    /** @return {@code true} when the provider is currently open and
     *  ready for read / write calls. */
    boolean isOpen();

    /** Return the underlying native storage handle — an
     *  {@link global.thalion.ttio.hdf5.Hdf5File} for
     *  {@link Hdf5Provider}, {@code null} for {@link MemoryProvider}.
     *
     *  <p>Escape hatch for byte-level code (signatures, encryption,
     *  native compression filters) that cannot be expressed through
     *  the protocol. Any caller that invokes this is pinned to a
     *  specific backend.</p>
     *
     *  @deprecated Scheduled for removal. External callers should
     *              migrate to the {@link StorageGroup} /
     *              {@link StorageDataset} protocol.
     */
    @Deprecated(forRemoval = true)
    default Object nativeHandle() { return null; }

    // ── Capabilities ──────────────────────────

    /** {@code true} if the backend honors {@code chunkSize} in
     *  {@link StorageGroup#createDataset}. Defaults to {@code false}
     *  — only {@link Hdf5Provider} returns {@code true}. Memory and
     *  SQLite accept {@code chunkSize} for interface compatibility but
     *  silently ignore it. */
    default boolean supportsChunking() { return false; }

    /** {@code true} if the backend honors {@code compression} /
     *  {@code compressionLevel}. Defaults to {@code false}. Only
     *  {@link Hdf5Provider} returns {@code true} (zlib + LZ4). */
    default boolean supportsCompression() { return false; }

    // ── Transactions ─────────────────────────

    /** Start a write-batching transaction. Default no-op (HDF5,
     *  Memory). SQLiteProvider overrides this to issue {@code BEGIN}
     *  on the underlying JDBC connection.
     *
     *  <p>Callers that wrap bulk loads in
     *  {@code beginTransaction() / commitTransaction()} get the SQLite
     *  batch speedup without ad-hoc per-provider conventions.</p> */
    default void beginTransaction() {}

    /** Commit and end an open transaction started by
     *  {@link #beginTransaction()}. Default no-op. */
    default void commitTransaction() {}

    /** Roll back and end an open transaction started by
     *  {@link #beginTransaction()}. Default no-op. */
    default void rollbackTransaction() {}

    /** Release backend resources. After this call {@link #isOpen} must
     *  return {@code false}; calling {@code close} a second time is a
     *  no-op. */
    @Override
    void close();
}
