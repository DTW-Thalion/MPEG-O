/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio.providers;

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
 * <p><b>API status:</b> Stable (Provisional per M39 — may change
 * before v1.0).</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOStorageProvider}, Python
 * {@code ttio.providers.base.StorageProvider}.</p>
 *
 * @since 0.6
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

    /** Root group ("/"). Must be called after {@link #open}. */
    StorageGroup rootGroup();

    boolean isOpen();

    /** Return the underlying native storage handle — an
     *  {@link com.dtwthalion.ttio.hdf5.Hdf5File} for
     *  {@link Hdf5Provider}, {@code null} for {@link MemoryProvider}.
     *
     *  <p>Escape hatch for byte-level code (signatures, encryption,
     *  native compression filters) that cannot be expressed through
     *  the protocol. Any caller that invokes this is pinned to a
     *  specific backend.</p>
     *
     *  @deprecated Scheduled for removal at v1.0. M43-M45 eliminated
     *              every internal caller; external callers should
     *              migrate to the StorageGroup / StorageDataset
     *              protocol. See {@code docs/api-stability-v0.8.md} §6.
     */
    @Deprecated(since = "0.8", forRemoval = true)
    default Object nativeHandle() { return null; }

    // ── Capabilities (Appendix B Gap 3) ──────────────────────────

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

    // ── Transactions (Appendix B Gap 11) ─────────────────────────

    /** Start a write-batching transaction. Default no-op (HDF5,
     *  Memory). SQLiteProvider overrides this to issue {@code BEGIN}
     *  on the underlying JDBC connection.
     *
     *  <p>Callers that wrap bulk loads in
     *  {@code beginTransaction() / commitTransaction()} get the SQLite
     *  batch speedup without the ad-hoc per-provider convention the
     *  M39 providers used before.</p> */
    default void beginTransaction() {}

    /** Commit and end an open transaction started by
     *  {@link #beginTransaction()}. Default no-op. */
    default void commitTransaction() {}

    /** Roll back and end an open transaction started by
     *  {@link #beginTransaction()}. Default no-op. */
    default void rollbackTransaction() {}

    @Override
    void close();
}
