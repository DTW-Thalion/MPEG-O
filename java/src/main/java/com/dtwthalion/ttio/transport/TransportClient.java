/*
 * TTI-O Java Implementation — v0.10 M68.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio.transport;

import com.dtwthalion.ttio.SpectralDataset;

import org.java_websocket.client.WebSocketClient;
import org.java_websocket.handshake.ServerHandshake;

import java.io.ByteArrayOutputStream;
import java.net.URI;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;

/**
 * Java client for the TTI-O streaming transport protocol (v0.10 M68).
 *
 * <p>Connects to a {@link com.dtwthalion.ttio.transport.TransportClient}-compatible
 * WebSocket server (the Python reference server ships in
 * {@code ttio.transport.server}), sends a JSON query, and collects
 * binary transport packets.</p>
 *
 * <p>Cross-language equivalents: Python
 * {@code ttio.transport.client.TransportClient}, Objective-C
 * {@code TTIOTransportClient}.</p>
 */
public final class TransportClient {

    private final URI uri;

    public TransportClient(String url) {
        this.uri = URI.create(url);
    }

    /**
     * Open a connection, send the query, collect all packets up to
     * and including {@code EndOfStream}. Blocks up to
     * {@code timeoutMs} milliseconds.
     */
    public List<TransportReader.PacketRecord> fetchPackets(Map<String, Object> filters,
                                                             long timeoutMs)
            throws Exception {
        CollectingClient client = new CollectingClient(uri, filters);
        if (!client.connectBlocking(timeoutMs, TimeUnit.MILLISECONDS)) {
            throw new IllegalStateException("TransportClient: connect timed out");
        }
        List<TransportReader.PacketRecord> packets =
                client.done.get(timeoutMs, TimeUnit.MILLISECONDS);
        client.closeBlocking();
        return packets;
    }

    public List<TransportReader.PacketRecord> fetchPackets(Map<String, Object> filters)
            throws Exception {
        return fetchPackets(filters, 30_000);
    }

    /**
     * Stream a filtered dataset into a new {@code .tio} file via the
     * offline {@link TransportReader} materializer.
     */
    public SpectralDataset streamToFile(String outputPath,
                                          Map<String, Object> filters) throws Exception {
        List<TransportReader.PacketRecord> packets = fetchPackets(filters);
        ByteArrayOutputStream buf = new ByteArrayOutputStream();
        for (TransportReader.PacketRecord rec : packets) {
            buf.write(rec.header.encode());
            buf.write(rec.payload);
            if ((rec.header.flags & PacketHeader.FLAG_HAS_CHECKSUM) != 0) {
                ByteBuffer crcBuf = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN);
                crcBuf.putInt(Crc32c.compute(rec.payload));
                buf.write(crcBuf.array());
            }
        }
        try (TransportReader reader = new TransportReader(buf.toByteArray())) {
            return reader.materializeTo(outputPath);
        }
    }

    // ---------------------------------------------------------- helpers

    private static String encodeQuery(Map<String, Object> filters) {
        StringBuilder sb = new StringBuilder();
        sb.append("{\"type\":\"query\",\"filters\":{");
        if (filters != null) {
            boolean first = true;
            for (Map.Entry<String, Object> e : filters.entrySet()) {
                if (!first) sb.append(',');
                first = false;
                sb.append('"').append(e.getKey()).append("\":");
                Object v = e.getValue();
                if (v == null) sb.append("null");
                else if (v instanceof Number || v instanceof Boolean) sb.append(v);
                else sb.append('"').append(v).append('"');
            }
        }
        sb.append("}}");
        return sb.toString();
    }

    private static final class CollectingClient extends WebSocketClient {
        final Map<String, Object> filters;
        final List<TransportReader.PacketRecord> packets = new ArrayList<>();
        final CompletableFuture<List<TransportReader.PacketRecord>> done =
                new CompletableFuture<>();

        CollectingClient(URI uri, Map<String, Object> filters) {
            super(uri);
            this.filters = filters;
        }

        @Override
        public void onOpen(ServerHandshake handshake) {
            send(encodeQuery(filters));
        }

        @Override
        public void onMessage(String message) {
            // Server-pushed text; not used in the transport wire protocol.
        }

        @Override
        public void onMessage(ByteBuffer bytes) {
            byte[] raw = new byte[bytes.remaining()];
            bytes.get(raw);
            TransportReader.PacketRecord rec = splitPacket(raw);
            packets.add(rec);
            if (rec.header.packetType == PacketType.END_OF_STREAM) {
                done.complete(Collections.unmodifiableList(new ArrayList<>(packets)));
            }
        }

        @Override
        public void onClose(int code, String reason, boolean remote) {
            if (!done.isDone()) {
                done.complete(Collections.unmodifiableList(new ArrayList<>(packets)));
            }
        }

        @Override
        public void onError(Exception ex) {
            if (!done.isDone()) done.completeExceptionally(ex);
        }
    }

    private static TransportReader.PacketRecord splitPacket(byte[] raw) {
        if (raw.length < PacketHeader.HEADER_SIZE) {
            throw new IllegalStateException(
                    "transport frame shorter than header: " + raw.length);
        }
        byte[] headerBytes = new byte[PacketHeader.HEADER_SIZE];
        System.arraycopy(raw, 0, headerBytes, 0, PacketHeader.HEADER_SIZE);
        PacketHeader header = PacketHeader.decode(headerBytes);
        int end = PacketHeader.HEADER_SIZE + (int) header.payloadLength;
        if (raw.length < end) {
            throw new IllegalStateException(
                    "transport frame truncated: " + raw.length + "/" + end);
        }
        byte[] payload = new byte[(int) header.payloadLength];
        System.arraycopy(raw, PacketHeader.HEADER_SIZE, payload, 0, payload.length);
        if ((header.flags & PacketHeader.FLAG_HAS_CHECKSUM) != 0) {
            if (raw.length < end + 4) {
                throw new IllegalStateException("frame missing CRC-32C");
            }
            int expected = ByteBuffer.wrap(raw, end, 4)
                    .order(ByteOrder.LITTLE_ENDIAN).getInt();
            int actual = Crc32c.compute(payload);
            if (expected != actual) {
                throw new IllegalStateException(
                        "CRC-32C mismatch on packet type " + header.packetType);
            }
        }
        return new TransportReader.PacketRecord(header, payload);
    }
}
