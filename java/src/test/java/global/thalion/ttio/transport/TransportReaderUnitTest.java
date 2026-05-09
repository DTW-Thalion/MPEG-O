/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.SpectrumIndex;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Unit tests for {@link TransportReader} error branches and constructor
 * variants — complements {@link TransportClientTest} (cross-language
 * happy-path) and {@link TransportCodecTest} (round-trip).
 *
 * <p>Hand-rolled byte streams cover malformed packet streams that an
 * encoder-driven test cannot reach.</p>
 */
class TransportReaderUnitTest {

    // ── Hand-rolled wire helpers ──────────────────────────────────

    /** Encode one packet header + payload with no checksum. */
    private static byte[] makePacket(PacketType type, int datasetId,
                                       long auSequence, byte[] payload) {
        PacketHeader h = new PacketHeader(type, 0, datasetId, auSequence,
                payload.length, 0L);
        byte[] hdr = h.encode();
        byte[] out = new byte[hdr.length + payload.length];
        System.arraycopy(hdr, 0, out, 0, hdr.length);
        System.arraycopy(payload, 0, out, hdr.length, payload.length);
        return out;
    }

    /** Build a minimal StreamHeader payload (1.2 / "" / "" / 0 features
     *  / 0 datasets). */
    private static byte[] streamHeaderPayload(String... features) {
        return streamHeaderPayloadFull("1.2", "", "", features);
    }

    private static byte[] streamHeaderPayloadFull(String version, String title,
                                                    String isa, String... features) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try {
            out.write(leStr2(version));
            out.write(leStr2(title));
            out.write(leStr2(isa));
            out.write(u16(features.length));
            for (String f : features) out.write(leStr2(f));
            out.write(u16(0));  // n_datasets
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
        return out.toByteArray();
    }

    private static byte[] leStr2(String s) {
        byte[] b = s.getBytes(StandardCharsets.UTF_8);
        ByteBuffer buf = ByteBuffer.allocate(2 + b.length).order(ByteOrder.LITTLE_ENDIAN);
        buf.putShort((short) (b.length & 0xFFFF));
        buf.put(b);
        return buf.array();
    }

    private static byte[] u16(int v) {
        ByteBuffer b = ByteBuffer.allocate(2).order(ByteOrder.LITTLE_ENDIAN);
        b.putShort((short) (v & 0xFFFF));
        return b.array();
    }

    private static byte[] u32(long v) {
        ByteBuffer b = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN);
        b.putInt((int) (v & 0xFFFFFFFFL));
        return b.array();
    }

    private static byte[] concat(byte[]... parts) {
        int total = 0;
        for (byte[] p : parts) total += p.length;
        byte[] out = new byte[total];
        int off = 0;
        for (byte[] p : parts) {
            System.arraycopy(p, 0, out, off, p.length);
            off += p.length;
        }
        return out;
    }

    /** Use the writer to lay down a small, valid round-trip stream. */
    private static byte[] writerEmittedRoundTripStream(Path scratch) throws Exception {
        int n = 2;
        int p = 2;
        double[] mzAll = new double[n * p];
        double[] intAll = new double[n * p];
        for (int i = 0; i < n * p; i++) {
            mzAll[i] = 100.0 + i;
            intAll[i] = 1000.0 + i;
        }
        long[] offsets = {0, 2};
        int[] lengths = {2, 2};
        double[] rts = {1.0, 2.0};
        int[] msLevels = {1, 1};
        int[] pols = {1, 1};
        double[] pmzs = {0.0, 0.0};
        int[] pcs = {0, 0};
        double[] bpis = {1001.0, 1003.0};
        SpectrumIndex idx = new SpectrumIndex(n, offsets, lengths, rts,
                msLevels, pols, pmzs, pcs, bpis);
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("mz", mzAll);
        channels.put("intensity", intAll);
        InstrumentConfig cfg = new InstrumentConfig("", "", "", "", "", "");
        AcquisitionRun run = new AcquisitionRun("run_0001",
                Enums.AcquisitionMode.MS1_DDA, idx, cfg, channels,
                List.of(), List.of(), "", 0.0);
        Path src = scratch.resolve("rsrc.tio");
        try (SpectralDataset ds = SpectralDataset.create(src.toString(),
                "rt", "ISA",
                List.of(run), List.of(), List.of(), List.of())) { /* close */ }
        SpectralDataset reopened = SpectralDataset.open(src.toString());
        ByteArrayOutputStream stream = new ByteArrayOutputStream();
        try (TransportWriter tw = new TransportWriter(stream)) {
            tw.writeDataset(reopened);
        }
        reopened.close();
        return stream.toByteArray();
    }

    // ── Constructor variants ──────────────────────────────────────

    @Test
    void inputStreamConstructorDoesNotOwnStream() throws Exception {
        // The non-owning ctor must NOT close the upstream stream when
        // the reader is closed (caller retains responsibility).
        byte[] eosOnly = makePacket(PacketType.END_OF_STREAM, 0, 0, new byte[0]);
        // Wrap in a tracking stream so we can detect close().
        boolean[] closed = {false};
        ByteArrayInputStream upstream = new ByteArrayInputStream(eosOnly) {
            @Override public void close() throws IOException {
                closed[0] = true;
                super.close();
            }
        };
        try (TransportReader tr = new TransportReader(upstream)) {
            // EOS-only stream parses cleanly at the raw-packet level.
            List<TransportReader.PacketRecord> packets = tr.readAllPackets();
            assertEquals(1, packets.size());
            assertEquals(PacketType.END_OF_STREAM, packets.get(0).header.packetType);
        }
        assertFalse(closed[0],
            "TransportReader(InputStream) must not close caller-owned stream");
    }

    @Test
    void pathConstructorReadsFromDisk(@TempDir Path tmp) throws Exception {
        byte[] stream = writerEmittedRoundTripStream(tmp);
        Path p = tmp.resolve("packets.tis");
        Files.write(p, stream);
        try (TransportReader tr = new TransportReader(p)) {
            List<TransportReader.PacketRecord> packets = tr.readAllPackets();
            assertEquals(PacketType.STREAM_HEADER,
                packets.get(0).header.packetType);
            assertEquals(PacketType.END_OF_STREAM,
                packets.get(packets.size() - 1).header.packetType);
        }
    }

    // ── Truncation paths ──────────────────────────────────────────

    @Test
    void emptyStreamReturnsEmptyPacketList() throws Exception {
        try (TransportReader tr = new TransportReader(new byte[0])) {
            assertTrue(tr.readAllPackets().isEmpty());
        }
    }

    @Test
    void truncatedHeaderRaisesIOException() {
        // Less than HEADER_SIZE bytes: header.length < 24 but > 0.
        byte[] partial = new byte[10];
        partial[0] = 'T'; partial[1] = 'I'; partial[2] = 0x01;
        try (TransportReader tr = new TransportReader(partial)) {
            IOException ex = assertThrows(IOException.class, tr::readAllPackets);
            assertTrue(ex.getMessage().contains("truncated header"),
                "got: " + ex.getMessage());
        } catch (IOException e) {
            fail(e);
        }
    }

    @Test
    void truncatedPayloadRaisesIOException() {
        // Header announces 100-byte payload, only 5 bytes of payload follow.
        PacketHeader h = new PacketHeader(PacketType.STREAM_HEADER, 0, 0, 0,
                100, 0L);
        byte[] hdr = h.encode();
        byte[] partial = new byte[hdr.length + 5];
        System.arraycopy(hdr, 0, partial, 0, hdr.length);
        try (TransportReader tr = new TransportReader(partial)) {
            IOException ex = assertThrows(IOException.class, tr::readAllPackets);
            assertTrue(ex.getMessage().contains("truncated payload"),
                "got: " + ex.getMessage());
        } catch (IOException e) {
            fail(e);
        }
    }

    @Test
    void truncatedCrcRaisesIOException() {
        // Build a packet with FLAG_HAS_CHECKSUM but withhold the CRC bytes.
        byte[] payload = streamHeaderPayload();
        PacketHeader h = new PacketHeader(PacketType.STREAM_HEADER,
                PacketHeader.FLAG_HAS_CHECKSUM, 0, 0, payload.length, 0L);
        byte[] truncated = concat(h.encode(), payload);  // no CRC suffix
        try (TransportReader tr = new TransportReader(truncated)) {
            IOException ex = assertThrows(IOException.class, tr::readAllPackets);
            assertTrue(ex.getMessage().contains("truncated CRC"),
                "got: " + ex.getMessage());
        } catch (IOException e) {
            fail(e);
        }
    }

    // ── Stream-shape errors ───────────────────────────────────────

    @Test
    void firstPacketMustBeStreamHeader(@TempDir Path tmp) {
        // Emit a DatasetHeader before any StreamHeader.
        byte[] dsHdrPayload = concat(
            u16(1),                  // dataset_id
            leStr2("ds"),            // name
            new byte[]{0},           // acq_mode
            leStr2("TTIOMassSpectrum"),
            new byte[]{0},           // n_channels
            // instrument_json LEStr4
            new byte[]{0,0,0,0},
            u32(0)                   // expected_au_count
        );
        byte[] stream = makePacket(PacketType.DATASET_HEADER, 1, 0, dsHdrPayload);
        Path out = tmp.resolve("should-not-create.tio");
        try (TransportReader tr = new TransportReader(stream)) {
            // readAllPackets succeeds (no StreamHeader is fine at the
            // raw-packet level), but materializeTo enforces ordering.
            assertThrows(IOException.class,
                () -> tr.materializeTo(out.toString()));
        } catch (IOException e) {
            fail(e);
        }
    }

    @Test
    void nonMonotonicAuSequenceRejected(@TempDir Path tmp) throws Exception {
        // StreamHeader → DatasetHeader → AU(seq=5) → AU(seq=5) (duplicate).
        byte[] shdr = makePacket(PacketType.STREAM_HEADER, 0, 0,
                streamHeaderPayload());
        byte[] dsPayload = concat(
            u16(1),
            leStr2("run_0001"),
            new byte[]{0},
            leStr2("TTIOMassSpectrum"),
            new byte[]{2},  // 2 channels
            leStr2("mz"), leStr2("intensity"),
            // instrument_json LEStr4 = empty
            new byte[]{0,0,0,0},
            u32(2)
        );
        byte[] dshdr = makePacket(PacketType.DATASET_HEADER, 1, 0, dsPayload);
        AccessUnit au = new AccessUnit(0, 0, 1, 0,
                1.0, 0.0, 0, 0.0, 0.0,
                List.of(),  // empty channels — accumulator won't crash
                0, 0, 0);
        byte[] auBytes = au.encode();
        byte[] au1 = makePacket(PacketType.ACCESS_UNIT, 1, 5, auBytes);
        byte[] au2 = makePacket(PacketType.ACCESS_UNIT, 1, 5, auBytes);  // dup
        byte[] eos = makePacket(PacketType.END_OF_STREAM, 0, 0, new byte[0]);
        byte[] stream = concat(shdr, dshdr, au1, au2, eos);
        Path out = tmp.resolve("rt.tio");
        try (TransportReader tr = new TransportReader(stream)) {
            IOException ex = assertThrows(IOException.class,
                () -> tr.materializeTo(out.toString()));
            assertTrue(ex.getMessage().contains("non-monotonic"),
                "got: " + ex.getMessage());
        }
    }

    @Test
    void accessUnitBeforeDatasetHeaderRejected(@TempDir Path tmp) {
        byte[] shdr = makePacket(PacketType.STREAM_HEADER, 0, 0,
                streamHeaderPayload());
        AccessUnit au = new AccessUnit(0, 0, 1, 0, 1.0, 0.0, 0, 0.0, 0.0,
                List.of(), 0, 0, 0);
        byte[] auPkt = makePacket(PacketType.ACCESS_UNIT, 7, 0, au.encode());
        byte[] stream = concat(shdr, auPkt);
        Path out = tmp.resolve("rt.tio");
        try (TransportReader tr = new TransportReader(stream)) {
            IOException ex = assertThrows(IOException.class,
                () -> tr.materializeTo(out.toString()));
            assertTrue(ex.getMessage().contains("AccessUnit before DatasetHeader"),
                "got: " + ex.getMessage());
        } catch (IOException e) {
            fail(e);
        }
    }

    // ── Bulk mode v2 blob path errors ─────────────────────────────

    @Test
    void bulkModeDeclaredButNoBlobsRaises(@TempDir Path tmp) {
        // StreamHeader declares bulk_mode_v2_blobs but ships zero
        // BlobV2* packets — must reject in materializeTo.
        byte[] shdr = makePacket(PacketType.STREAM_HEADER, 0, 0,
                streamHeaderPayload(PacketType.BULK_MODE_V2_BLOBS_FEATURE));
        byte[] eos = makePacket(PacketType.END_OF_STREAM, 0, 0, new byte[0]);
        byte[] stream = concat(shdr, eos);
        Path out = tmp.resolve("rt.tio");
        try (TransportReader tr = new TransportReader(stream)) {
            IOException ex = assertThrows(IOException.class,
                () -> tr.materializeTo(out.toString()));
            assertTrue(ex.getMessage().contains("bulk_mode_v2_blobs"),
                "got: " + ex.getMessage());
        } catch (IOException e) {
            fail(e);
        }
    }

    @Test
    void blobV2MateInfoBadCodecIdRaises(@TempDir Path tmp) {
        byte[] shdr = makePacket(PacketType.STREAM_HEADER, 0, 0,
                streamHeaderPayload(PacketType.BULK_MODE_V2_BLOBS_FEATURE));
        byte[] payload = concat(
            u16(1),                  // dataset_id
            new byte[]{(byte) 99},   // bad codec id (expected 13)
            u16(0),                  // n_chrom_names
            u32(0)                   // blob length
        );
        byte[] mate = makePacket(PacketType.BLOB_V2_MATE_INFO, 1, 0, payload);
        byte[] eos = makePacket(PacketType.END_OF_STREAM, 0, 0, new byte[0]);
        byte[] stream = concat(shdr, mate, eos);
        Path out = tmp.resolve("rt.tio");
        try (TransportReader tr = new TransportReader(stream)) {
            IOException ex = assertThrows(IOException.class,
                () -> tr.materializeTo(out.toString()));
            assertTrue(ex.getMessage().contains("bad codec_id"),
                "got: " + ex.getMessage());
        } catch (IOException e) {
            fail(e);
        }
    }

    @Test
    void blobV2MateInfoDatasetIdMismatchRaises(@TempDir Path tmp) {
        byte[] shdr = makePacket(PacketType.STREAM_HEADER, 0, 0,
                streamHeaderPayload(PacketType.BULK_MODE_V2_BLOBS_FEATURE));
        byte[] payload = concat(
            u16(7),                                                 // body says 7
            new byte[]{(byte) PacketType.CODEC_ID_MATE_INLINE_V2},
            u16(0),
            u32(0)
        );
        byte[] mate = makePacket(PacketType.BLOB_V2_MATE_INFO, 1, 0, payload); // header says 1
        byte[] eos = makePacket(PacketType.END_OF_STREAM, 0, 0, new byte[0]);
        byte[] stream = concat(shdr, mate, eos);
        Path out = tmp.resolve("rt.tio");
        try (TransportReader tr = new TransportReader(stream)) {
            IOException ex = assertThrows(IOException.class,
                () -> tr.materializeTo(out.toString()));
            assertTrue(ex.getMessage().contains("dataset_id"),
                "got: " + ex.getMessage());
        } catch (IOException e) {
            fail(e);
        }
    }

    @Test
    void blobV2MateInfoDuplicateRaises(@TempDir Path tmp) {
        byte[] shdr = makePacket(PacketType.STREAM_HEADER, 0, 0,
                streamHeaderPayload(PacketType.BULK_MODE_V2_BLOBS_FEATURE));
        byte[] body = concat(
            u16(1),
            new byte[]{(byte) PacketType.CODEC_ID_MATE_INLINE_V2},
            u16(0),
            u32(0)
        );
        byte[] mate1 = makePacket(PacketType.BLOB_V2_MATE_INFO, 1, 0, body);
        byte[] mate2 = makePacket(PacketType.BLOB_V2_MATE_INFO, 1, 0, body);
        byte[] eos = makePacket(PacketType.END_OF_STREAM, 0, 0, new byte[0]);
        byte[] stream = concat(shdr, mate1, mate2, eos);
        Path out = tmp.resolve("rt.tio");
        try (TransportReader tr = new TransportReader(stream)) {
            IOException ex = assertThrows(IOException.class,
                () -> tr.materializeTo(out.toString()));
            assertTrue(ex.getMessage().contains("duplicate"),
                "got: " + ex.getMessage());
        } catch (IOException e) {
            fail(e);
        }
    }

    @Test
    void blobV2RefDiffBadCodecIdRaises(@TempDir Path tmp) {
        byte[] shdr = makePacket(PacketType.STREAM_HEADER, 0, 0,
                streamHeaderPayload(PacketType.BULK_MODE_V2_BLOBS_FEATURE));
        byte[] payload = concat(
            u16(1),
            new byte[]{(byte) 99},   // bad codec id (expected 14)
            leStr2(""),              // ref uri
            u32(0)
        );
        byte[] ref = makePacket(PacketType.BLOB_V2_REF_DIFF, 1, 0, payload);
        byte[] eos = makePacket(PacketType.END_OF_STREAM, 0, 0, new byte[0]);
        byte[] stream = concat(shdr, ref, eos);
        Path out = tmp.resolve("rt.tio");
        try (TransportReader tr = new TransportReader(stream)) {
            IOException ex = assertThrows(IOException.class,
                () -> tr.materializeTo(out.toString()));
            assertTrue(ex.getMessage().contains("bad codec_id"),
                "got: " + ex.getMessage());
        } catch (IOException e) {
            fail(e);
        }
    }

    @Test
    void blobV2RefDiffDatasetIdMismatchRaises(@TempDir Path tmp) {
        byte[] shdr = makePacket(PacketType.STREAM_HEADER, 0, 0,
                streamHeaderPayload(PacketType.BULK_MODE_V2_BLOBS_FEATURE));
        byte[] payload = concat(
            u16(7),    // body says 7
            new byte[]{(byte) PacketType.CODEC_ID_REF_DIFF_V2},
            leStr2(""),
            u32(0)
        );
        byte[] ref = makePacket(PacketType.BLOB_V2_REF_DIFF, 1, 0, payload); // header 1
        byte[] eos = makePacket(PacketType.END_OF_STREAM, 0, 0, new byte[0]);
        byte[] stream = concat(shdr, ref, eos);
        Path out = tmp.resolve("rt.tio");
        try (TransportReader tr = new TransportReader(stream)) {
            IOException ex = assertThrows(IOException.class,
                () -> tr.materializeTo(out.toString()));
            assertTrue(ex.getMessage().contains("dataset_id"),
                "got: " + ex.getMessage());
        } catch (IOException e) {
            fail(e);
        }
    }

    @Test
    void blobV2RefDiffDuplicateRaises(@TempDir Path tmp) {
        byte[] shdr = makePacket(PacketType.STREAM_HEADER, 0, 0,
                streamHeaderPayload(PacketType.BULK_MODE_V2_BLOBS_FEATURE));
        byte[] body = concat(
            u16(1),
            new byte[]{(byte) PacketType.CODEC_ID_REF_DIFF_V2},
            leStr2("ref://uri"),
            u32(3),
            new byte[]{1, 2, 3}
        );
        byte[] ref1 = makePacket(PacketType.BLOB_V2_REF_DIFF, 1, 0, body);
        byte[] ref2 = makePacket(PacketType.BLOB_V2_REF_DIFF, 1, 0, body);
        byte[] eos = makePacket(PacketType.END_OF_STREAM, 0, 0, new byte[0]);
        byte[] stream = concat(shdr, ref1, ref2, eos);
        Path out = tmp.resolve("rt.tio");
        try (TransportReader tr = new TransportReader(stream)) {
            IOException ex = assertThrows(IOException.class,
                () -> tr.materializeTo(out.toString()));
            assertTrue(ex.getMessage().contains("duplicate"),
                "got: " + ex.getMessage());
        } catch (IOException e) {
            fail(e);
        }
    }

    @Test
    void blobV2NameTokBadCodecIdRaises(@TempDir Path tmp) {
        byte[] shdr = makePacket(PacketType.STREAM_HEADER, 0, 0,
                streamHeaderPayload(PacketType.BULK_MODE_V2_BLOBS_FEATURE));
        byte[] payload = concat(
            u16(1),
            new byte[]{(byte) 99},   // bad codec id (expected 15)
            u32(0)
        );
        byte[] nm = makePacket(PacketType.BLOB_V2_NAME_TOK, 1, 0, payload);
        byte[] eos = makePacket(PacketType.END_OF_STREAM, 0, 0, new byte[0]);
        byte[] stream = concat(shdr, nm, eos);
        Path out = tmp.resolve("rt.tio");
        try (TransportReader tr = new TransportReader(stream)) {
            IOException ex = assertThrows(IOException.class,
                () -> tr.materializeTo(out.toString()));
            assertTrue(ex.getMessage().contains("bad codec_id"),
                "got: " + ex.getMessage());
        } catch (IOException e) {
            fail(e);
        }
    }

    @Test
    void blobV2NameTokDatasetIdMismatchRaises(@TempDir Path tmp) {
        byte[] shdr = makePacket(PacketType.STREAM_HEADER, 0, 0,
                streamHeaderPayload(PacketType.BULK_MODE_V2_BLOBS_FEATURE));
        byte[] payload = concat(
            u16(9),     // body says 9
            new byte[]{(byte) PacketType.CODEC_ID_NAME_TOKENIZED_V2},
            u32(0)
        );
        byte[] nm = makePacket(PacketType.BLOB_V2_NAME_TOK, 1, 0, payload); // header 1
        byte[] eos = makePacket(PacketType.END_OF_STREAM, 0, 0, new byte[0]);
        byte[] stream = concat(shdr, nm, eos);
        Path out = tmp.resolve("rt.tio");
        try (TransportReader tr = new TransportReader(stream)) {
            IOException ex = assertThrows(IOException.class,
                () -> tr.materializeTo(out.toString()));
            assertTrue(ex.getMessage().contains("dataset_id"),
                "got: " + ex.getMessage());
        } catch (IOException e) {
            fail(e);
        }
    }

    @Test
    void blobV2NameTokDuplicateRaises(@TempDir Path tmp) {
        byte[] shdr = makePacket(PacketType.STREAM_HEADER, 0, 0,
                streamHeaderPayload(PacketType.BULK_MODE_V2_BLOBS_FEATURE));
        byte[] body = concat(
            u16(1),
            new byte[]{(byte) PacketType.CODEC_ID_NAME_TOKENIZED_V2},
            u32(2),
            new byte[]{1, 2}
        );
        byte[] nm1 = makePacket(PacketType.BLOB_V2_NAME_TOK, 1, 0, body);
        byte[] nm2 = makePacket(PacketType.BLOB_V2_NAME_TOK, 1, 0, body);
        byte[] eos = makePacket(PacketType.END_OF_STREAM, 0, 0, new byte[0]);
        byte[] stream = concat(shdr, nm1, nm2, eos);
        Path out = tmp.resolve("rt.tio");
        try (TransportReader tr = new TransportReader(stream)) {
            IOException ex = assertThrows(IOException.class,
                () -> tr.materializeTo(out.toString()));
            assertTrue(ex.getMessage().contains("duplicate"),
                "got: " + ex.getMessage());
        } catch (IOException e) {
            fail(e);
        }
    }

    // ── Repeated StreamHeader silently ignored ────────────────────

    @Test
    void duplicateStreamHeaderIsIgnored(@TempDir Path tmp) throws Exception {
        // Two StreamHeader packets back-to-back; reader keeps the first
        // and silently skips subsequent ones.
        byte[] shdr1 = makePacket(PacketType.STREAM_HEADER, 0, 0,
                streamHeaderPayloadFull("1.2", "first", "isa1"));
        byte[] shdr2 = makePacket(PacketType.STREAM_HEADER, 0, 0,
                streamHeaderPayloadFull("1.2", "second", "isa2"));
        byte[] eos = makePacket(PacketType.END_OF_STREAM, 0, 0, new byte[0]);
        byte[] stream = concat(shdr1, shdr2, eos);
        Path out = tmp.resolve("rt.tio");
        try (TransportReader tr = new TransportReader(stream);
             SpectralDataset rt = tr.materializeTo(out.toString())) {
            // First StreamHeader's title wins.
            assertEquals("first", rt.title());
        }
    }

    // ── readAllPackets terminates on early END_OF_STREAM ──────────

    @Test
    void readAllPacketsStopsAtEndOfStream() throws Exception {
        byte[] shdr = makePacket(PacketType.STREAM_HEADER, 0, 0,
                streamHeaderPayload());
        byte[] eos = makePacket(PacketType.END_OF_STREAM, 0, 0, new byte[0]);
        // Trailing junk after EOS should NOT be read.
        byte[] junk = new byte[]{0x55, (byte) 0xAA};
        byte[] stream = concat(shdr, eos, junk);
        try (TransportReader tr = new TransportReader(stream)) {
            List<TransportReader.PacketRecord> packets = tr.readAllPackets();
            assertEquals(2, packets.size());
            assertEquals(PacketType.END_OF_STREAM,
                packets.get(packets.size() - 1).header.packetType);
        }
    }
}
