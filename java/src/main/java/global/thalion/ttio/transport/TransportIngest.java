/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Arrays;

/**
 * Callback-driven incremental transport-stream parser. Sits next to
 * {@link TransportReader}: where the reader assumes you have the whole
 * stream up front and want every packet back at once, the ingest is for
 * callers (e.g. the TTI-O Workbench Server's WebSocket upload session)
 * that feed bytes in chunks as they arrive and want each packet
 * delivered as soon as it's complete.
 *
 * <p>Lifecycle:</p>
 * <pre>{@code
 * TransportIngest ingest = new TransportIngest(new TransportIngest.Listener() {
 *     public void onPacket(TransportIngest.PacketRecord rec) { ... }
 *     public void onEndOfStream() { ... }
 *     public void onError(TransportIngest.IngestException e) { ... }
 * });
 * // ... when bytes arrive ...
 * ingest.feed(chunk);   // listener fires per packet
 * // ... on producer EOF ...
 * ingest.finish();      // throws if trailing partial
 * }</pre>
 *
 * <p>Validates everything {@link TransportReader} validates — magic,
 * version, header CRC, payload CRC when the
 * {@link PacketHeader#FLAG_HAS_CHECKSUM} flag is set, AU-sequence
 * monotonicity, StreamHeader-first — but does so packet-by-packet
 * instead of in one pass. A failed validation halts the ingest; the
 * rolling buffer is discarded and any subsequent {@link #feed} throws
 * {@link IngestException}.</p>
 *
 * <p>Not thread-safe: a single ingest instance must be driven from one
 * thread. The server pattern is one ingest per WS connection, owned by
 * the worker thread that accepted the connection.</p>
 *
 * <p>Cross-language equivalents:</p>
 * <ul>
 *   <li>Objective-C: {@code TTIOTransportIngest}</li>
 *   <li>Python: {@code ttio.transport.ingest.TransportIngest}</li>
 * </ul>
 */
public final class TransportIngest {

    /** Receives packets and lifecycle events as bytes arrive.
     *
     * <p>All callbacks fire on the thread that invoked {@link #feed};
     * callers managing their own queues (e.g. the workbench server's
     * worker thread) should keep the work in the callback short.</p>
     */
    public interface Listener {
        /** Fired once per complete packet as it lands in the rolling buffer. */
        void onPacket(PacketRecord record);

        /** Fired exactly once after an EndOfStream packet is parsed. */
        default void onEndOfStream() {}

        /** Fired on any parse error (bad magic, version, truncated header,
         *  CRC mismatch, etc.). The ingest moves to a permanently-failed
         *  state after this; subsequent {@link #feed} calls throw
         *  {@link IngestException} immediately. */
        default void onError(IngestException error) {}
    }

    /** One parsed packet as header + payload. Mirrors
     *  {@link TransportReader.PacketRecord} so listeners can share
     *  consumer code between the one-shot reader and the incremental
     *  ingest. */
    public static final class PacketRecord {
        public final PacketHeader header;
        public final byte[] payload;
        public PacketRecord(PacketHeader header, byte[] payload) {
            this.header = header;
            this.payload = payload;
        }
    }

    /** Thrown by {@link #feed} / {@link #finish} on any parse failure. */
    public static final class IngestException extends RuntimeException {
        public IngestException(String message) { super(message); }
        public IngestException(String message, Throwable cause) {
            super(message, cause);
        }
    }

    private final Listener listener;
    private byte[] buffer = new byte[0];
    private int bufferLen = 0;
    private long lastAuSequence = 0L;
    private boolean seenFirstAU = false;
    private boolean sawStreamHeader = false;
    private long packetCount = 0L;
    private boolean isFinished = false;

    public TransportIngest(Listener listener) {
        if (listener == null) throw new NullPointerException("listener");
        this.listener = listener;
    }

    // ---------------------------------------------------------- accessors

    /** Total packets emitted so far. Useful for resumable-upload
     *  progress reporting. */
    public long packetCount() { return packetCount; }

    /** Bytes currently buffered awaiting a complete packet. */
    public int bufferedBytes() { return bufferLen; }

    /** {@code true} once the ingest has received and emitted an
     *  EndOfStream packet, or has been put into the failed state by a
     *  parse error. Further {@link #feed} calls on a finished ingest
     *  throw {@link IngestException}. */
    public boolean isFinished() { return isFinished; }

    // ---------------------------------------------------------- feed/finish

    /** Feed a chunk of transport bytes.
     *
     * <p>As packets complete, delivers each to
     * {@link Listener#onPacket(PacketRecord)} synchronously on the
     * calling thread. Throws {@link IngestException} on the first parse
     * error; {@link Listener#onError(IngestException)} is also invoked
     * in that case (so callers may choose either failure-handling
     * style).</p>
     */
    public void feed(byte[] data) {
        feed(data, 0, data == null ? 0 : data.length);
    }

    /** Feed a slice of a byte array. */
    public void feed(byte[] data, int offset, int length) {
        if (isFinished) {
            throw fail("feed on finished ingest");
        }
        if (length == 0) return;
        if (data == null) throw new NullPointerException("data");
        if (offset < 0 || length < 0 || offset + length > data.length) {
            throw new IndexOutOfBoundsException(
                "feed range out of bounds: offset=" + offset
                + ", length=" + length + ", arrayLength=" + data.length);
        }
        ensureCapacity(bufferLen + length);
        System.arraycopy(data, offset, buffer, bufferLen, length);
        bufferLen += length;
        drain();
    }

    /** Signal end-of-input.
     *
     * <p>If the rolling buffer contains a partial packet (header
     * without payload, payload without CRC, …) throws
     * {@link IngestException} and fires the error callback. If the last
     * successfully parsed packet was EndOfStream this is a no-op.</p>
     */
    public void finish() {
        if (isFinished) return;
        if (bufferLen == 0) {
            throw fail("stream ended without EndOfStream packet");
        }
        throw fail("stream ended with " + bufferLen
                   + " bytes buffered (partial packet)");
    }

    // ---------------------------------------------------------- drain loop

    private void drain() {
        while (bufferLen >= PacketHeader.HEADER_SIZE) {
            PacketHeader header;
            try {
                header = PacketHeader.decode(
                    Arrays.copyOf(buffer, PacketHeader.HEADER_SIZE));
            } catch (IllegalArgumentException exc) {
                throw fail(exc.getMessage());
            }

            if (!sawStreamHeader
                    && header.packetType != PacketType.STREAM_HEADER) {
                throw fail("first packet must be StreamHeader");
            }

            boolean hasCrc =
                (header.flags & PacketHeader.FLAG_HAS_CHECKSUM) != 0;
            int trailing = hasCrc ? 4 : 0;
            long needed64 = (long) PacketHeader.HEADER_SIZE
                            + header.payloadLength + trailing;
            if (needed64 > Integer.MAX_VALUE) {
                throw fail("packet too large: " + needed64 + " bytes");
            }
            int needed = (int) needed64;
            if (bufferLen < needed) {
                // Wait for more bytes.
                return;
            }

            int payloadLen = (int) header.payloadLength;
            byte[] payload = new byte[payloadLen];
            System.arraycopy(buffer, PacketHeader.HEADER_SIZE,
                             payload, 0, payloadLen);

            if (hasCrc) {
                int crcOffset = PacketHeader.HEADER_SIZE + payloadLen;
                int advertised = ByteBuffer.wrap(
                    buffer, crcOffset, 4
                ).order(ByteOrder.LITTLE_ENDIAN).getInt();
                int computed = Crc32c.compute(payload);
                if (advertised != computed) {
                    throw fail(String.format(
                        "CRC-32C mismatch on packet type 0x%02x: "
                        + "advertised 0x%08x, computed 0x%08x",
                        header.packetTypeByte(),
                        advertised, computed));
                }
            }

            if (header.packetType == PacketType.ACCESS_UNIT) {
                // Use ``seenFirstAU`` rather than ``packetCount > 0`` so
                // the first AccessUnit can have any ``auSequence`` value
                // (including 0). The earlier check rejected writer-
                // produced streams whose first AU had ``auSequence=0``
                // because ``lastAuSequence`` was also 0 at init.
                if (seenFirstAU
                        && header.auSequence <= lastAuSequence) {
                    throw fail("AU sequence regressed: got "
                        + header.auSequence
                        + ", last seen " + lastAuSequence);
                }
                lastAuSequence = header.auSequence;
                seenFirstAU = true;
            }

            if (header.packetType == PacketType.STREAM_HEADER) {
                sawStreamHeader = true;
            }

            // Advance the buffer in place.
            int remaining = bufferLen - needed;
            if (remaining > 0) {
                System.arraycopy(buffer, needed, buffer, 0, remaining);
            }
            bufferLen = remaining;
            packetCount++;
            listener.onPacket(new PacketRecord(header, payload));

            if (header.packetType == PacketType.END_OF_STREAM) {
                isFinished = true;
                // Tolerate trailing bytes after EndOfStream — some
                // producers pad. Drop them so the next feed() rejects.
                bufferLen = 0;
                listener.onEndOfStream();
                return;
            }
        }
    }

    // ---------------------------------------------------------- helpers

    private void ensureCapacity(int required) {
        if (buffer.length >= required) return;
        int newCap = Math.max(buffer.length * 2, required);
        if (newCap < 64) newCap = 64;
        byte[] grown = new byte[newCap];
        System.arraycopy(buffer, 0, grown, 0, bufferLen);
        buffer = grown;
    }

    private IngestException fail(String message) {
        IngestException err = new IngestException(message);
        isFinished = true;
        bufferLen = 0;
        listener.onError(err);
        return err;
    }
}
