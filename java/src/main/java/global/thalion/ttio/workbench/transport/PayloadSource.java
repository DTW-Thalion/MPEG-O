/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.transport;

import java.io.Closeable;
import java.io.IOException;
import java.nio.ByteBuffer;

/**
 * Strategy interface for an upload payload source.
 *
 * <p>Two implementations exist:
 * <ul>
 *   <li>{@link BytesPayloadSource} — wraps a pre-buffered {@code byte[]}
 *       (kept for the existing {@link WorkbenchTransportClient#upload(
 *       String, String, byte[], ResumeState, TransferProgress)} entry
 *       point and small-payload / in-memory test fixtures).</li>
 *   <li>{@link FilePayloadSource} — wraps a {@link java.nio.channels.FileChannel}
 *       so that multi-GB {@code .tis} uploads stream from disk in
 *       chunk-sized slices without pinning heap ~= file size.</li>
 * </ul>
 *
 * <p>The contract is intentionally minimal: random-access reads at
 * a caller-supplied offset, bounded by {@link #size()}. Implementations
 * must be thread-safe with respect to {@link #read} being invoked from
 * one thread at a time (the upload pump thread).</p>
 *
 * <p>Package-private — not part of the public API. The streaming
 * upload entry point is exposed via
 * {@link WorkbenchTransportClient#upload(String, String,
 * java.nio.file.Path, ResumeState, TransferProgress)}.</p>
 */
interface PayloadSource extends Closeable {

    /** Total payload size in bytes. */
    long size();

    /** Read up to {@code dst.remaining()} bytes starting at byte
     *  {@code offset}. Returns the number of bytes actually placed
     *  into {@code dst} (advances {@code dst.position()} by that
     *  many). Returns {@code -1} if {@code offset >= size()} (EOF).
     *  Short reads are permitted and the caller (UploadDriver) handles
     *  them by issuing another read at the new offset. */
    int read(ByteBuffer dst, long offset) throws IOException;

    /** Release any underlying resources. Idempotent. */
    @Override
    void close() throws IOException;
}
