/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.transport;

import java.nio.ByteBuffer;
import java.util.Objects;

/**
 * In-memory {@link PayloadSource} backed by a {@code byte[]}.
 *
 * <p>Used by the legacy {@code upload(byte[], ...)} entry points
 * (small payloads, in-memory test fixtures, the Python/ObjC bridge
 * helpers in {@link global.thalion.ttio.workbench.WorkbenchClient}
 * that {@code bos.toByteArray()} a small staging buffer).</p>
 *
 * <p>Package-private. Constructed only from inside
 * {@link WorkbenchTransportClient}.</p>
 */
final class BytesPayloadSource implements PayloadSource {

    private final byte[] payload;

    BytesPayloadSource(byte[] payload) {
        this.payload = Objects.requireNonNull(payload, "payload");
    }

    @Override
    public long size() {
        return payload.length;
    }

    @Override
    public int read(ByteBuffer dst, long offset) {
        if (offset < 0L) throw new IllegalArgumentException("offset < 0");
        if (offset >= payload.length) return -1;
        int from = (int) offset;
        int avail = payload.length - from;
        int n = Math.min(avail, dst.remaining());
        dst.put(payload, from, n);
        return n;
    }

    @Override
    public void close() {
        // No resources to release. byte[] is GC'd with this object.
    }
}
