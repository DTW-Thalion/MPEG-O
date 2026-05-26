/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.transport;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.util.Objects;

/**
 * File-backed {@link PayloadSource} for streaming uploads.
 *
 * <p>Reads at most {@code dst.remaining()} bytes per call via
 * {@link FileChannel#read(ByteBuffer, long)} — no scratch byte array,
 * no full-payload slurp. Peak heap during an upload is therefore
 * bounded by the WS frame buffer (one chunk) plus the chunk currently
 * in flight on the WS thread.</p>
 *
 * <p>Package-private. Constructed only from inside
 * {@link WorkbenchTransportClient#upload(String, String,
 * java.nio.file.Path, ResumeState, TransferProgress)}.</p>
 */
final class FilePayloadSource implements PayloadSource {

    private final FileChannel channel;
    private final long size;
    private volatile boolean closed = false;

    /** Cumulative number of {@link #read} invocations. Visible for
     *  tests; the streaming-upload unit test asserts this rises in
     *  step with the number of chunks the driver emits, which proves
     *  the upload path is reading in slices instead of slurping. */
    final java.util.concurrent.atomic.AtomicLong readCalls =
        new java.util.concurrent.atomic.AtomicLong(0L);

    /** Largest single-read byte count served. Visible for tests; the
     *  bounded-heap test asserts this never exceeds {@code chunkSize},
     *  pinning the per-call resident-bytes ceiling. */
    final java.util.concurrent.atomic.AtomicInteger maxReadBytes =
        new java.util.concurrent.atomic.AtomicInteger(0);

    FilePayloadSource(FileChannel channel, long size) {
        this.channel = Objects.requireNonNull(channel, "channel");
        if (size < 0L) throw new IllegalArgumentException("size < 0");
        this.size = size;
    }

    @Override
    public long size() {
        return size;
    }

    @Override
    public int read(ByteBuffer dst, long offset) throws IOException {
        if (closed) throw new IOException("PayloadSource is closed");
        if (offset < 0L) throw new IllegalArgumentException("offset < 0");
        if (offset >= size) return -1;
        // Bound the read so we never deliver more than size-offset bytes
        // (sparse / oversize files just-in-case).
        long remainingInFile = size - offset;
        int oldLimit = dst.limit();
        if (dst.remaining() > remainingInFile) {
            dst.limit(dst.position() + (int) remainingInFile);
        }
        try {
            int n = channel.read(dst, offset);
            if (n > 0) {
                readCalls.incrementAndGet();
                maxReadBytes.accumulateAndGet(n, Math::max);
            }
            return n;
        } finally {
            dst.limit(oldLimit);
        }
    }

    @Override
    public void close() throws IOException {
        if (closed) return;
        closed = true;
        channel.close();
    }
}
