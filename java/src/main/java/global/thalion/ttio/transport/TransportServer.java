/*
 * TTI-O Java Implementation5 (parity backfill).
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums;
import global.thalion.ttio.IRImage;
import global.thalion.ttio.Identification;
import global.thalion.ttio.MSImage;
import global.thalion.ttio.ProvenanceRecord;
import global.thalion.ttio.Quantification;
import global.thalion.ttio.RamanImage;
import global.thalion.ttio.Sample;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.Subject;
import global.thalion.ttio.genomics.ReferenceImport;

import org.java_websocket.WebSocket;
import org.java_websocket.handshake.ClientHandshake;
import org.java_websocket.server.WebSocketServer;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
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

    /**
     * Delegate to {@link DatasetWalker}; relay every event through a
     * {@link TransportWriter} sinked at a per-event byte buffer, then
     * split the buffer back into individual packets and send each as
     * its own WebSocket binary frame.
     *
     * <p>Previously this method hand-rolled the emission loop and
     * walked only {@code msRuns()}, so every v0.11 prelude accessor
     * (references, subjects, samples, identifications, quantifications,
     * image cubes, dataset_provenance, encryption_algorithm) plus all
     * genomic AUs were silently dropped on the wire (#145). Walker
     * delegation matches the Python reference server ({@code
     * ttio.transport.server._emit_stream}) and the workbench daemon's
     * Objective-C download visitor.</p>
     *
     * <p>The per-packet framing matters: {@link TransportWriter#writeReferenceGroup}
     * and its siblings emit MULTIPLE packets per call
     * (HEADER + N × CHROMOSOME + FOOTER, etc.). {@link TransportClient}
     * parses one packet per frame, so the per-call buffer is re-split
     * into individual frames before sending. Same shape as #144's
     * Python framing fix.</p>
     */
    private static void streamDataset(WebSocket conn, SpectralDataset dataset,
                                        AUFilter filter) throws Exception {
        DatasetWalker walker = new DatasetWalker();
        WriterDispatchVisitor visitor = new WriterDispatchVisitor(conn);
        walker.walk(dataset, filter, visitor);
        if (visitor.failure != null) throw visitor.failure;
    }

    /**
     * AccessUnitVisitor that dispatches every event into a fresh
     * TransportWriter sinked at a ByteArrayOutputStream, then ships
     * each produced packet as its own binary frame.
     */
    private static final class WriterDispatchVisitor
            implements AccessUnitVisitor {
        private final WebSocket conn;
        Exception failure;

        WriterDispatchVisitor(WebSocket conn) { this.conn = conn; }

        /**
         * Encode {@code emit} via a fresh TransportWriter, split the
         * concatenated packets into per-packet slices, and send each
         * as its own WS binary frame.
         */
        private void dispatch(WriterCall emit) {
            if (failure != null) return;
            ByteArrayOutputStream buf = new ByteArrayOutputStream();
            try (TransportWriter w = new TransportWriter(buf)) {
                emit.invoke(w);
            } catch (IOException ex) {
                failure = ex;
                return;
            } catch (RuntimeException ex) {
                failure = ex;
                return;
            }
            byte[] raw = buf.toByteArray();
            int off = 0;
            while (off + PacketHeader.HEADER_SIZE <= raw.length) {
                PacketHeader h = PacketHeader.decode(
                    Arrays.copyOfRange(raw, off,
                                       off + PacketHeader.HEADER_SIZE));
                boolean hasCrc = (h.flags & PacketHeader.FLAG_HAS_CHECKSUM) != 0;
                int packetLen = PacketHeader.HEADER_SIZE
                              + (int) h.payloadLength
                              + (hasCrc ? 4 : 0);
                conn.send(Arrays.copyOfRange(raw, off, off + packetLen));
                off += packetLen;
            }
        }

        @FunctionalInterface
        private interface WriterCall { void invoke(TransportWriter w) throws IOException; }

        @Override
        public void visitStreamHeader(DatasetWalker walker,
                                        String formatVersion,
                                        String title,
                                        String isaInvestigation,
                                        List<String> features,
                                        int nDatasets) {
            dispatch(w -> w.writeStreamHeader(formatVersion, title,
                    isaInvestigation, features, nDatasets));
        }

        @Override
        public void visitDatasetHeader(DatasetWalker walker,
                                         int datasetId, String name,
                                         int acquisitionMode,
                                         String spectrumClass,
                                         List<String> channelNames,
                                         String instrumentJson,
                                         int expectedAUCount) {
            dispatch(w -> w.writeDatasetHeader(datasetId, name,
                    acquisitionMode, spectrumClass, channelNames,
                    instrumentJson, expectedAUCount));
        }

        @Override
        public void visitAccessUnit(DatasetWalker walker, AccessUnit au,
                                      int datasetId, int auSequence) {
            dispatch(w -> w.writeAccessUnit(datasetId, auSequence, au));
        }

        @Override
        public void visitEndOfDataset(DatasetWalker walker, int datasetId,
                                       int finalAUSequence) {
            dispatch(w -> w.writeEndOfDataset(datasetId, finalAUSequence));
        }

        @Override
        public void visitEndOfStream(DatasetWalker walker) {
            dispatch(TransportWriter::writeEndOfStream);
        }

        // v0.11 §5.4 prelude

        @Override
        public void visitEncryptionAlgorithm(DatasetWalker walker, String algorithm) {
            dispatch(w -> w.writeEncryptionAlgorithm(algorithm));
        }

        @Override
        public void visitDatasetProvenance(DatasetWalker walker, List<ProvenanceRecord> records) {
            dispatch(w -> w.writeDatasetProvenance(records));
        }

        @Override
        public void visitSubjectMetadata(DatasetWalker walker, List<Subject> rows) {
            dispatch(w -> w.writeSubjectMetadata(rows));
        }

        @Override
        public void visitSampleMetadata(DatasetWalker walker, List<Sample> rows) {
            dispatch(w -> w.writeSampleMetadata(rows));
        }

        @Override
        public void visitReferenceGroup(DatasetWalker walker, ReferenceImport reference) {
            dispatch(w -> w.writeReferenceGroup(reference));
        }

        @Override
        public void visitImage(DatasetWalker walker, MSImage image) {
            dispatch(w -> w.writeImage(image));
        }

        @Override
        public void visitRamanImage(DatasetWalker walker, RamanImage image) {
            dispatch(w -> w.writeRamanImage(image));
        }

        @Override
        public void visitIRImage(DatasetWalker walker, IRImage image) {
            dispatch(w -> w.writeIRImage(image));
        }

        @Override
        public void visitIdentificationsTable(DatasetWalker walker, List<Identification> rows) {
            dispatch(w -> w.writeIdentifications(rows));
        }

        @Override
        public void visitQuantificationsTable(DatasetWalker walker, List<Quantification> rows) {
            dispatch(w -> w.writeQuantifications(rows));
        }
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
