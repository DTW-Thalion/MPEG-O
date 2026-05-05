/*
 * TTI-O Java Implementation5 (parity backfill).
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums;
import global.thalion.ttio.SpectralDataset;

import org.java_websocket.WebSocket;
import org.java_websocket.handshake.ClientHandshake;
import org.java_websocket.server.WebSocketServer;

import java.net.InetSocketAddress;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * WebSocket transport server (parity backfill).
 *
 * <p>Serves a {@link SpectralDataset} to WebSocket clients. Clients
 * send a JSON query; the server streams StreamHeader + DatasetHeaders
 * + filtered AccessUnits + EndOfDataset + EndOfStream as binary
 * frames. Wire protocol identical to Python
 * {@code ttio.transport.server.TransportServer}.</p>
 */
public final class TransportServer {

    private final String datasetPath;
    private final String host;
    private int port;

    private volatile InnerServer server;
    private final CountDownLatch startedLatch = new CountDownLatch(1);

    public TransportServer(String datasetPath, String host, int port) {
        this.datasetPath = datasetPath;
        this.host = host;
        this.port = port;
    }

    public int port() { return port; }

    /**
     * Start serving on a background thread. Returns once the socket
     * is bound (port discoverable via {@link #port()} even when {@code
     * port == 0}).
     */
    public void start() throws InterruptedException {
        server = new InnerServer(new InetSocketAddress(host, port), this);
        server.setReuseAddr(true);
        server.start();
        startedLatch.await(5, TimeUnit.SECONDS);
        port = server.getPort();
    }

    public void stop() throws InterruptedException {
        if (server != null) server.stop(2000);
    }

    private void markStarted() { startedLatch.countDown(); }

    // ---------------------------------------------------------- inner

    private static final class InnerServer extends WebSocketServer {
        private final TransportServer outer;

        InnerServer(InetSocketAddress addr, TransportServer outer) {
            super(addr);
            this.outer = outer;
        }

        @Override
        public void onStart() { outer.markStarted(); }

        @Override
        public void onOpen(WebSocket conn, ClientHandshake handshake) { /* noop */ }

        @Override
        public void onClose(WebSocket conn, int code, String reason, boolean remote) {}

        @Override
        public void onError(WebSocket conn, Exception ex) {
            if (conn != null) conn.close();
        }

        @Override
        public void onMessage(WebSocket conn, String message) {
            AUFilter filter = AUFilter.fromQueryJson(message);
            try (SpectralDataset dataset = SpectralDataset.open(outer.datasetPath)) {
                streamDataset(conn, dataset, filter);
            } catch (Exception e) {
                conn.close();
            }
        }
    }

    // ---------------------------------------------------------- streaming

    private static void streamDataset(WebSocket conn, SpectralDataset dataset,
                                        AUFilter filter) throws Exception {
        Map<String, AcquisitionRun> runs = dataset.msRuns();
        List<String> features = new ArrayList<>();
        for (String f : dataset.featureFlags().features()) features.add(f);

        // StreamHeader
        sendBinary(conn, packetBytes(
                PacketType.STREAM_HEADER, 0, 0,
                streamHeaderPayload(
                        dataset.title(), dataset.isaInvestigationId(),
                        features, runs.size())));

        // DatasetHeaders
        int did = 1;
        for (Map.Entry<String, AcquisitionRun> e : runs.entrySet()) {
            if (filter.datasetId != null && did != filter.datasetId) {
                did++;
                continue;
            }
            AcquisitionRun run = e.getValue();
            List<String> channelNames = new ArrayList<>(run.channels().keySet());
            String instrumentJson = TransportWriter.instrumentConfigJson(run.instrumentConfig());
            sendBinary(conn, packetBytes(PacketType.DATASET_HEADER, did, 0,
                    datasetHeaderPayload(did, e.getKey(),
                            run.acquisitionMode().ordinal(),
                            run.spectrumClassName(),
                            channelNames, instrumentJson,
                            run.spectrumCount())));
            did++;
        }

        // AccessUnits with filter evaluation.
        int emitted = 0;
        did = 1;
        outer:
        for (Map.Entry<String, AcquisitionRun> e : runs.entrySet()) {
            if (filter.datasetId != null && did != filter.datasetId) {
                did++;
                continue;
            }
            AcquisitionRun run = e.getValue();
            int count = run.spectrumCount();
            List<String> channelNames = new ArrayList<>(run.channels().keySet());
            for (int i = 0; i < count; i++) {
                AccessUnit au = TransportWriter.spectrumToAccessUnit(run, i, channelNames);
                if (!filter.matches(au, did)) continue;
                if (filter.maxAu != null && emitted >= filter.maxAu) break outer;
                sendBinary(conn, packetBytes(
                        PacketType.ACCESS_UNIT, did, i, au.encode()));
                emitted++;
            }
            did++;
        }

        // EndOfDataset per run.
        did = 1;
        for (Map.Entry<String, AcquisitionRun> e : runs.entrySet()) {
            if (filter.datasetId != null && did != filter.datasetId) {
                did++;
                continue;
            }
            AcquisitionRun run = e.getValue();
            ByteBuffer buf = ByteBuffer.allocate(6).order(ByteOrder.LITTLE_ENDIAN);
            buf.putShort((short) (did & 0xFFFF));
            buf.putInt(run.spectrumCount());
            sendBinary(conn, packetBytes(PacketType.END_OF_DATASET, did, 0,
                    buf.array()));
            did++;
        }

        // EndOfStream. Don't call conn.close() here — Java-WebSocket's
        // close() can drop buffered outgoing frames before they
        // flush. Let the client close the connection after it
        // observes EndOfStream (which is what every language's
        // TransportClient does by design).
        sendBinary(conn, packetBytes(PacketType.END_OF_STREAM, 0, 0, new byte[0]));
    }

    private static void sendBinary(WebSocket conn, byte[] data) {
        conn.send(data);
    }

    private static byte[] packetBytes(PacketType type, int datasetId,
                                         long auSequence, byte[] payload) {
        PacketHeader h = new PacketHeader(type, 0, datasetId, auSequence,
                payload.length, System.currentTimeMillis() * 1_000_000L);
        byte[] headerBytes = h.encode();
        byte[] out = new byte[headerBytes.length + payload.length];
        System.arraycopy(headerBytes, 0, out, 0, headerBytes.length);
        System.arraycopy(payload, 0, out, headerBytes.length, payload.length);
        return out;
    }

    private static byte[] streamHeaderPayload(String title, String isa,
                                                List<String> features,
                                                int nDatasets) {
        byte[] versionBytes = "1.2".getBytes(StandardCharsets.UTF_8);
        byte[] titleBytes = (title == null ? "" : title).getBytes(StandardCharsets.UTF_8);
        byte[] isaBytes = (isa == null ? "" : isa).getBytes(StandardCharsets.UTF_8);
        int size = 2 + versionBytes.length
                 + 2 + titleBytes.length
                 + 2 + isaBytes.length
                 + 2;
        List<byte[]> featureBytes = new ArrayList<>();
        for (String f : features) {
            byte[] fb = f.getBytes(StandardCharsets.UTF_8);
            featureBytes.add(fb);
            size += 2 + fb.length;
        }
        size += 2;
        ByteBuffer buf = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN);
        putLEString(buf, versionBytes, 2);
        putLEString(buf, titleBytes, 2);
        putLEString(buf, isaBytes, 2);
        buf.putShort((short) (features.size() & 0xFFFF));
        for (byte[] fb : featureBytes) putLEString(buf, fb, 2);
        buf.putShort((short) (nDatasets & 0xFFFF));
        return buf.array();
    }

    private static byte[] datasetHeaderPayload(int datasetId, String name,
                                                  int acquisitionMode,
                                                  String spectrumClass,
                                                  List<String> channelNames,
                                                  String instrumentJson,
                                                  long expectedAUCount) {
        byte[] nameBytes = (name == null ? "" : name).getBytes(StandardCharsets.UTF_8);
        byte[] classBytes = (spectrumClass == null ? "" : spectrumClass)
                .getBytes(StandardCharsets.UTF_8);
        byte[] instrBytes = (instrumentJson == null ? "" : instrumentJson)
                .getBytes(StandardCharsets.UTF_8);
        int size = 2
                 + 2 + nameBytes.length
                 + 1
                 + 2 + classBytes.length
                 + 1;
        List<byte[]> chBytes = new ArrayList<>();
        for (String c : channelNames) {
            byte[] cb = c.getBytes(StandardCharsets.UTF_8);
            chBytes.add(cb);
            size += 2 + cb.length;
        }
        size += 4 + instrBytes.length + 4;
        ByteBuffer buf = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN);
        buf.putShort((short) (datasetId & 0xFFFF));
        putLEString(buf, nameBytes, 2);
        buf.put((byte) (acquisitionMode & 0xFF));
        putLEString(buf, classBytes, 2);
        buf.put((byte) (channelNames.size() & 0xFF));
        for (byte[] cb : chBytes) putLEString(buf, cb, 2);
        putLEString(buf, instrBytes, 4);
        buf.putInt((int) (expectedAUCount & 0xFFFFFFFFL));
        return buf.array();
    }

    private static void putLEString(ByteBuffer buf, byte[] bytes, int width) {
        if (width == 2) buf.putShort((short) (bytes.length & 0xFFFF));
        else            buf.putInt(bytes.length);
        buf.put(bytes);
    }
}
