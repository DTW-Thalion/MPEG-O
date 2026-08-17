/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums;
import global.thalion.ttio.FeatureFlags;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.SpectrumIndex;
import global.thalion.ttio.genomics.GenomicRun;
import global.thalion.ttio.genomics.WrittenGenomicRun;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayOutputStream;
import java.io.OutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Unit tests for {@link TransportWriter} branches not exercised by the
 * happy-path round-trip in {@link TransportCodecTest} or the
 * cross-language test in {@link TransportClientTest}.
 *
 * <p>Targets: getter accessors, direct {@link
 * TransportWriter#writeBlobV2RefDiff} / {@link
 * TransportWriter#writeGenomicRun} entry points, JSON-escape branch in
 * {@code instrument_json} emission, NEGATIVE/UNKNOWN polarity wiring,
 * and the file-Path constructor's stream-ownership semantics.</p>
 */
class TransportWriterUnitTest {

    private static SpectralDataset makeMsFixture(Path dir, String runName,
                                                    Enums.AcquisitionMode mode) {
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
        // Wire-polarity 1 (NEGATIVE) on idx 0 and 0 (POSITIVE) on idx 1
        // exercises the wireToPolarityInt path on the reader; the
        // writer reads polarity from MassSpectrum.polarity() via
        // wireFromPolarity which only sees POSITIVE.
        int[] pols = {0, 0};
        double[] pmzs = {0.0, 0.0};
        int[] pcs = {0, 0};
        double[] bpis = {1001.0, 1003.0};
        SpectrumIndex idx = new SpectrumIndex(n, offsets, lengths, rts,
                msLevels, pols, pmzs, pcs, bpis);
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("mz", mzAll);
        channels.put("intensity", intAll);
        // InstrumentConfig with a quote and a backslash to exercise
        // the JSON escape branch in TransportWriter.appendField.
        InstrumentConfig cfg = new InstrumentConfig("Q-TOF",
                "MCP", "Th\"alion\\co", "model_x", "SN-1", "ESI");
        AcquisitionRun run = new AcquisitionRun(runName, mode, idx, cfg, channels,
                List.of(), List.of(), "", 0.0);
        Path src = dir.resolve("src.tio");
        return SpectralDataset.create(src.toString(),
                "writer-unit", "ISA-WUT",
                List.of(run), List.of(), List.of(), List.of());
    }

    private static WrittenGenomicRun smallGenomicRun() {
        int n = 2;
        int readLen = 4;
        byte[] template = "ACGT".getBytes(StandardCharsets.US_ASCII);
        byte[] sequences = new byte[n * readLen];
        byte[] qualities = new byte[n * readLen];
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        for (int i = 0; i < n; i++) {
            System.arraycopy(template, 0, sequences, i * readLen, readLen);
            offsets[i] = (long) i * readLen;
            lengths[i] = readLen;
        }
        Arrays.fill(qualities, (byte) 30);
        long[] positions = {100L, 200L};
        byte[] mqs = {(byte) 60, (byte) 60};
        int[] flags = {0x0003, 0x0003};
        List<String> chroms = new ArrayList<>(List.of("chr1", "chr1"));
        List<String> cigars = new ArrayList<>(List.of("4M", "4M"));
        List<String> readNames = new ArrayList<>(List.of("r0", "r1"));
        List<String> mateChroms = new ArrayList<>(List.of("", ""));
        long[] matePos = {-1L, -1L};
        int[] tlens = {0, 0};
        return new WrittenGenomicRun(
            Enums.AcquisitionMode.GENOMIC_WGS,
            "GRCh38", "ILLUMINA", "S1",
            positions, mqs, flags, sequences, qualities,
            offsets, lengths, cigars, readNames, mateChroms,
            matePos, tlens, chroms, Enums.Compression.ZLIB);
    }

    private static SpectralDataset makeGenomicFixture(Path dir) {
        WrittenGenomicRun run = smallGenomicRun();
        Path src = dir.resolve("g.tio");
        SpectralDataset.create(src.toString(),
            "g", "ISA-G",
            List.of(), List.of(run),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        return SpectralDataset.open(src.toString());
    }

    // ── Boolean getters/setters ───────────────────────────────────

    @Test
    void getterAccessorsReturnSetValues() {
        TransportWriter tw = new TransportWriter(new ByteArrayOutputStream());
        assertFalse(tw.useCompression());
        assertFalse(tw.useBulkMode());
        tw.setUseCompression(true);
        tw.setUseBulkMode(true);
        assertTrue(tw.useCompression());
        assertTrue(tw.useBulkMode());
        tw.setUseCompression(false);
        tw.setUseBulkMode(false);
        assertFalse(tw.useCompression());
        assertFalse(tw.useBulkMode());
    }

    // ── Path constructor ──────────────────────────────────────────

    @Test
    void pathConstructorWritesToDisk(@TempDir Path dir) throws Exception {
        Path packets = dir.resolve("packets.tis");
        try (TransportWriter tw = new TransportWriter(packets)) {
            tw.writeStreamHeader("1.2", "t", "isa", List.of(), 0);
            tw.writeEndOfStream();
        }
        assertTrue(Files.exists(packets));
        assertTrue(Files.size(packets) > 0);
        // Verify the stream parses cleanly.
        try (TransportReader tr = new TransportReader(packets)) {
            List<TransportReader.PacketRecord> packetsParsed = tr.readAllPackets();
            assertEquals(2, packetsParsed.size());
            assertEquals(PacketType.STREAM_HEADER,
                packetsParsed.get(0).header.packetType);
            assertEquals(PacketType.END_OF_STREAM,
                packetsParsed.get(1).header.packetType);
        }
    }

    @Test
    void streamConstructorDoesNotCloseUpstream() throws Exception {
        // The TransportWriter(OutputStream) ctor must not propagate
        // close() to the upstream stream (caller owns it).
        boolean[] closed = {false};
        OutputStream upstream = new ByteArrayOutputStream() {
            @Override public void close() throws IOException {
                closed[0] = true;
                super.close();
            }
        };
        try (TransportWriter tw = new TransportWriter(upstream)) {
            tw.writeEndOfStream();
        }
        assertFalse(closed[0],
            "TransportWriter(OutputStream) must not close caller-owned stream");
    }

    // ── writeBlobV2RefDiff direct invocation ──────────────────────

    @Test
    void writeBlobV2RefDiffEmitsDecodableBlob() throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try (TransportWriter tw = new TransportWriter(out)) {
            tw.writeBlobV2RefDiff(7, "ref://example/uri", new byte[]{1, 2, 3, 4, 5});
        }
        byte[] bytes = out.toByteArray();
        try (TransportReader tr = new TransportReader(bytes)) {
            List<TransportReader.PacketRecord> packets = tr.readAllPackets();
            assertEquals(1, packets.size());
            TransportReader.PacketRecord rec = packets.get(0);
            assertEquals(PacketType.BLOB_V2_REF_DIFF, rec.header.packetType);
            assertEquals(7, rec.header.datasetId);
        }
    }

    @Test
    void writeBlobV2RefDiffEmptyUriAndBlob() throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try (TransportWriter tw = new TransportWriter(out)) {
            tw.writeBlobV2RefDiff(1, "", new byte[0]);
        }
        // Header (24) + dataset_id(2) + codec(1) + uri-len(2) + blob-len(4) = 33.
        assertEquals(33, out.size());
    }

    // ── writeGenomicRun direct invocation ─────────────────────────

    @Test
    void writeGenomicRunEmitsHeaderAusEndOfDataset(@TempDir Path tmp) throws Exception {
        try (SpectralDataset src = makeGenomicFixture(tmp)) {
            GenomicRun run = src.genomicRuns().values().iterator().next();
            assertNotNull(run);

            ByteArrayOutputStream out = new ByteArrayOutputStream();
            try (TransportWriter tw = new TransportWriter(out)) {
                tw.writeStreamHeader("1.2", "t", "isa", List.of(), 1);
                tw.writeGenomicRun(1, "myrun", run);
                tw.writeEndOfStream();
            }
            try (TransportReader tr = new TransportReader(out.toByteArray())) {
                List<TransportReader.PacketRecord> pkts = tr.readAllPackets();
                List<PacketType> types = new ArrayList<>();
                for (TransportReader.PacketRecord p : pkts) types.add(p.header.packetType);
                // StreamHeader, DatasetHeader, 2 AUs, EndOfDataset, EndOfStream = 6.
                assertEquals(List.of(
                    PacketType.STREAM_HEADER,
                    PacketType.DATASET_HEADER,
                    PacketType.ACCESS_UNIT,
                    PacketType.ACCESS_UNIT,
                    PacketType.END_OF_DATASET,
                    PacketType.END_OF_STREAM
                ), types);
            }
        }
    }

    // ── Compression parameter variant ─────────────────────────────

    @Test
    void writeDatasetWithCompressionEmitsZlibChannels(@TempDir Path tmp) throws Exception {
        try (SpectralDataset src = makeMsFixture(tmp, "run_0001",
                Enums.AcquisitionMode.MS1_DDA)) { /* close */ }
        SpectralDataset src = SpectralDataset.open(tmp.resolve("src.tio").toString());
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try (TransportWriter tw = new TransportWriter(out)) {
            tw.setUseCompression(true);
            tw.setCompressionCodec("zlib");
            assertTrue(tw.useCompression());
            tw.writeDataset(src);
        }
        src.close();
        // The compressed channel data must round-trip back to the same
        // values via ZLIB inflate in the reader.
        Path rt = tmp.resolve("rt.tio");
        byte[] streamBytes = out.toByteArray();
        try (TransportReader tr = new TransportReader(streamBytes);
             SpectralDataset ds = tr.materializeTo(rt.toString())) {
            assertEquals(2, ds.msRuns().get("run_0001").spectrumCount());
        }
        // Verify at the wire level that AU channels carry compression=ZLIB
        // (round-trip alone can't observe this — the reader inflates).
        try (TransportReader tr = new TransportReader(streamBytes)) {
            List<TransportReader.PacketRecord> pkts = tr.readAllPackets();
            boolean sawAu = false;
            for (TransportReader.PacketRecord rec : pkts) {
                if (rec.header.packetType == PacketType.ACCESS_UNIT) {
                    sawAu = true;
                    AccessUnit au = AccessUnit.decode(rec.payload);
                    assertFalse(au.channels.isEmpty(),
                        "AU has no channels");
                    for (ChannelData ch : au.channels) {
                        assertEquals(Enums.Compression.ZLIB.ordinal(),
                            ch.compression,
                            "channel " + ch.name + " not ZLIB-compressed");
                    }
                    break;
                }
            }
            assertTrue(sawAu, "stream contained no ACCESS_UNIT packets");
        }
    }

    // ── Bulk-mode round-trip ──────────────────────────────────────

    @Test
    void bulkModeFeatureNotDeclaredWhenNoGenomicRuns(@TempDir Path tmp) throws Exception {
        // useBulkMode=true on a pure-MS dataset must NOT add the
        // bulk_mode feature flag (writer guards on genomicRuns nonempty).
        try (SpectralDataset src = makeMsFixture(tmp, "run_0001",
                Enums.AcquisitionMode.MS1_DDA)) { /* close */ }
        SpectralDataset src = SpectralDataset.open(tmp.resolve("src.tio").toString());
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try (TransportWriter tw = new TransportWriter(out)) {
            tw.setUseBulkMode(true);
            assertTrue(tw.useBulkMode());
            tw.writeDataset(src);
        }
        src.close();
        // Decode the stream back and verify the bulk-mode feature is absent.
        byte[] streamBytes = out.toByteArray();
        try (TransportReader tr = new TransportReader(streamBytes)) {
            // Round-trip parse — reader must not raise the
            // "bulk_mode_v2_blobs but no BlobV2*" guard.
            Path rt = tmp.resolve("rt.tio");
            try (SpectralDataset ds = tr.materializeTo(rt.toString())) {
                assertEquals(2, ds.msRuns().get("run_0001").spectrumCount());
            }
        }
        // Wire-level: parse the StreamHeader payload and assert the
        // BULK_MODE_V2_BLOBS feature is NOT in the declared feature list.
        try (TransportReader tr = new TransportReader(streamBytes)) {
            List<TransportReader.PacketRecord> pkts = tr.readAllPackets();
            assertFalse(pkts.isEmpty(), "stream is empty");
            TransportReader.PacketRecord first = pkts.get(0);
            assertEquals(PacketType.STREAM_HEADER, first.header.packetType,
                "first packet must be StreamHeader");
            java.nio.ByteBuffer buf = java.nio.ByteBuffer.wrap(first.payload)
                .order(java.nio.ByteOrder.LITTLE_ENDIAN);
            // Skip format_version, title, isa (each LE u16 length + bytes).
            for (int i = 0; i < 3; i++) {
                int len = buf.getShort() & 0xFFFF;
                buf.position(buf.position() + len);
            }
            int nFeatures = buf.getShort() & 0xFFFF;
            List<String> features = new ArrayList<>(nFeatures);
            for (int i = 0; i < nFeatures; i++) {
                int len = buf.getShort() & 0xFFFF;
                byte[] b = new byte[len];
                buf.get(b);
                features.add(new String(b, java.nio.charset.StandardCharsets.UTF_8));
            }
            assertFalse(features.contains(PacketType.BULK_MODE_V2_BLOBS_FEATURE),
                "bulk_mode_v2_blobs feature must NOT be declared on a "
                + "pure-MS dataset; got features=" + features);
        }
    }

    // ── instrument_json escape branch ─────────────────────────────

    @Test
    void instrumentConfigJsonEscapesQuotesAndBackslashes() {
        InstrumentConfig cfg = new InstrumentConfig(
            "ana\"lyz", "det\\ec", "man\"u", "mod", "ser", "src");
        String json = TransportWriter.instrumentConfigJson(cfg);
        // Quotes must be backslash-escaped; backslashes must be doubled.
        assertTrue(json.contains("ana\\\"lyz"),
            "expected escaped quote in: " + json);
        assertTrue(json.contains("det\\\\ec"),
            "expected escaped backslash in: " + json);
    }

    @Test
    void instrumentConfigJsonNullReturnsEmptyObject() {
        assertEquals("{}", TransportWriter.instrumentConfigJson(null));
    }

    // ── genomicRunMetadataJson sanity ─────────────────────────────

    @Test
    void genomicRunMetadataJsonHasSortedKeys(@TempDir Path tmp) throws Exception {
        try (SpectralDataset src = makeGenomicFixture(tmp)) {
            GenomicRun run = src.genomicRuns().values().iterator().next();
            String json = TransportWriter.genomicRunMetadataJson(run);
            // Field order: modality, platform, reference_uri, sample_name.
            int mod = json.indexOf("modality");
            int plat = json.indexOf("platform");
            int ref = json.indexOf("reference_uri");
            int sn = json.indexOf("sample_name");
            assertTrue(mod >= 0 && mod < plat && plat < ref && ref < sn,
                "unexpected key order in: " + json);
        }
    }

    // ── spectrumToAccessUnit branch coverage ──────────────────────

    @Test
    void spectrumToAccessUnitNmrRunGetsClass1() {
        // NMR_1D acquisition mode → spectrumClassName="TTIONMRSpectrum"
        // → wire spectrum_class = 1.
        int n = 1;
        double[] mz = {1.0};
        double[] intensity = {2.0};
        long[] offsets = {0};
        int[] lengths = {1};
        double[] rts = {1.0};
        int[] msLevels = {1};
        int[] pols = {0};
        double[] pmzs = {0.0};
        int[] pcs = {0};
        double[] bpis = {2.0};
        SpectrumIndex idx = new SpectrumIndex(n, offsets, lengths, rts,
                msLevels, pols, pmzs, pcs, bpis);
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("mz", mz);
        channels.put("intensity", intensity);
        AcquisitionRun run = new AcquisitionRun("nmr_run",
                Enums.AcquisitionMode.NMR_1D, idx,
                new InstrumentConfig("", "", "", "", "", ""),
                channels, List.of(), List.of(), "", 0.0);

        AccessUnit au = TransportWriter.spectrumToAccessUnit(
                run, 0, new ArrayList<>(channels.keySet()));
        assertEquals(1, au.spectrumClass);
    }

    @Test
    void spectrumToAccessUnitNegativePolarity() {
        // Build an MS run with NEGATIVE polarity at index 0 to drive the
        // wireFromPolarity NEGATIVE branch via objectAtIndex →
        // MassSpectrum.polarity().
        int n = 1;
        double[] mz = {1.0};
        double[] intensity = {2.0};
        long[] offsets = {0};
        int[] lengths = {1};
        double[] rts = {1.0};
        int[] msLevels = {1};
        // -1 = NEGATIVE in the SpectrumIndex polarity wire convention.
        int[] pols = {-1};
        double[] pmzs = {0.0};
        int[] pcs = {0};
        double[] bpis = {2.0};
        SpectrumIndex idx = new SpectrumIndex(n, offsets, lengths, rts,
                msLevels, pols, pmzs, pcs, bpis);
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("mz", mz);
        channels.put("intensity", intensity);
        AcquisitionRun run = new AcquisitionRun("ms_neg",
                Enums.AcquisitionMode.MS1_DDA, idx,
                new InstrumentConfig("", "", "", "", "", ""),
                channels, List.of(), List.of(), "", 0.0);

        AccessUnit au = TransportWriter.spectrumToAccessUnit(
                run, 0, new ArrayList<>(channels.keySet()));
        // Wire polarity 1 = NEGATIVE.
        assertEquals(1, au.polarity);
    }

    @Test
    void spectrumToAccessUnitWithCompression() {
        // Drive the compressed payload branch in spectrumToAccessUnit.
        int n = 1;
        double[] mz = new double[8];
        double[] intensity = new double[8];
        for (int i = 0; i < 8; i++) { mz[i] = i; intensity[i] = i * 10.0; }
        long[] offsets = {0};
        int[] lengths = {8};
        double[] rts = {1.0};
        int[] msLevels = {1};
        int[] pols = {0};
        double[] pmzs = {0.0};
        int[] pcs = {0};
        double[] bpis = {70.0};
        SpectrumIndex idx = new SpectrumIndex(n, offsets, lengths, rts,
                msLevels, pols, pmzs, pcs, bpis);
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("mz", mz);
        channels.put("intensity", intensity);
        AcquisitionRun run = new AcquisitionRun("ms_zlib",
                Enums.AcquisitionMode.MS1_DDA, idx,
                new InstrumentConfig("", "", "", "", "", ""),
                channels, List.of(), List.of(), "", 0.0);

        AccessUnit au = TransportWriter.spectrumToAccessUnit(
                run, 0, new ArrayList<>(channels.keySet()), true, "zlib");
        // ZLIB compression = ordinal of Compression.ZLIB.
        for (ChannelData ch : au.channels) {
            assertEquals(Enums.Compression.ZLIB.ordinal(), ch.compression);
        }
        // Compression on with no codec named: FLOAT_DELTA_ZSTD (id 17),
        // one FDZ1 stream per channel.
        AccessUnit dflt = TransportWriter.spectrumToAccessUnit(
                run, 0, new ArrayList<>(channels.keySet()), true);
        for (ChannelData ch : dflt.channels) {
            assertEquals(Enums.Compression.FLOAT_DELTA_ZSTD.ordinal(), ch.compression);
            assertEquals('F', ch.data[0]);
            assertEquals('D', ch.data[1]);
            assertEquals('Z', ch.data[2]);
            assertEquals('1', ch.data[3]);
        }
    }

    // ── writeStreamHeader / writeDatasetHeader scalar variants ────

    @Test
    void writeStreamHeaderEmptyFeaturesAndDatasetCount() throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try (TransportWriter tw = new TransportWriter(out)) {
            tw.writeStreamHeader("1.2", null, null, List.of(), 0);
            tw.writeEndOfStream();
        }
        try (TransportReader tr = new TransportReader(out.toByteArray())) {
            List<TransportReader.PacketRecord> pkts = tr.readAllPackets();
            assertEquals(2, pkts.size());
        }
    }

    // ── EndOfDataset framing ──────────────────────────────────────

    @Test
    void writeEndOfDatasetEmitsCorrectPayloadShape() throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try (TransportWriter tw = new TransportWriter(out)) {
            tw.writeEndOfDataset(42, 7);
        }
        try (TransportReader tr = new TransportReader(out.toByteArray())) {
            List<TransportReader.PacketRecord> pkts = tr.readAllPackets();
            assertEquals(1, pkts.size());
            assertEquals(PacketType.END_OF_DATASET, pkts.get(0).header.packetType);
            assertEquals(42, pkts.get(0).header.datasetId);
            // Payload: dataset_id(2) + final_au_sequence(4) = 6 bytes.
            assertEquals(6, pkts.get(0).payload.length);
        }
    }

    // ── emitRawPacket with custom flags ───────────────────────────

    @Test
    void emitRawPacketAddsChecksumWhenEnabled() throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try (TransportWriter tw = new TransportWriter(out)) {
            tw.setUseChecksum(true);
            tw.emitRawPacket(PacketType.STREAM_HEADER, 0, 0, 0,
                    new byte[]{1, 2, 3, 4});
        }
        // Header(24) + payload(4) + crc(4) = 32 bytes.
        assertEquals(32, out.size());
    }

    @Test
    void emitRawPacketRespectsCustomFlags() throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try (TransportWriter tw = new TransportWriter(out)) {
            tw.emitRawPacket(PacketType.ACCESS_UNIT,
                    PacketHeader.FLAG_ENCRYPTED,
                    1, 0, new byte[]{9, 9, 9});
        }
        try (TransportReader tr = new TransportReader(out.toByteArray())) {
            List<TransportReader.PacketRecord> pkts = tr.readAllPackets();
            assertEquals(1, pkts.size());
            assertEquals(PacketHeader.FLAG_ENCRYPTED,
                pkts.get(0).header.flags & PacketHeader.FLAG_ENCRYPTED);
        }
    }
}
