/*
 * TTI-O Java Implementation - v0.11 M89.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums;
import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.FeatureFlags;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.SpectrumIndex;
import global.thalion.ttio.genomics.AlignedRead;
import global.thalion.ttio.genomics.GenomicRun;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.protection.PerAUEncryption;
import global.thalion.ttio.protection.PerAUEncryption.GcmResult;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * v0.11 M89 transport-layer parity tests for the GenomicRead AU.
 *
 * <p>Mirrors:
 * <ul>
 *   <li>Python {@code tests/test_transport_packets.py::TestAccessUnit}
 *       genomic cases (M89.1 wire-suffix round-trip, unmapped read,
 *       long chromosome, truncated suffix raises, non-genomic AU
 *       silently ignores accidentally-set chromosome).</li>
 *   <li>Python {@code tests/test_au_filter.py::TestGenomicPredicates}
 *       (M89.3 chromosome / position predicates, MS/genomic separation
 *       in multiplexed streams).</li>
 *   <li>Python {@code tests/test_transport_codec.py::TestGenomicRoundTrip}
 *       and {@code TestMultiplexedRoundTrip} (M89.2 / M89.4).</li>
 *   <li>Python {@code tests/test_m89_5_genomic_encryption.py}
 *       (M89.5: per-AU AES-GCM round-trip preserves the genomic
 *       suffix).</li>
 * </ul>
 */
class M89GenomicTransportTest {

    // ────────────────────────────────────────────────────────────────
    // M89.1 — AccessUnit wire-suffix round-trip
    // ────────────────────────────────────────────────────────────────

    @Test
    void genomicReadRoundTrip() {
        AccessUnit au = new AccessUnit(
            5, 0, 0, 2,
            0.0, 0.0, 0,
            0.0, 0.0,
            List.of(new ChannelData("seq", 6, 0, 1, new byte[8])),
            0L, 0L, 0L,
            "chr1", 123_456_789L, 60, 0x0003);
        AccessUnit decoded = AccessUnit.decode(au.encode());
        assertEquals(5, decoded.spectrumClass);
        assertEquals("chr1", decoded.chromosome);
        assertEquals(123_456_789L, decoded.position);
        assertEquals(60, decoded.mappingQuality);
        assertEquals(0x0003, decoded.flags);
        assertEquals(1, decoded.channels.size());
    }

    @Test
    void genomicReadUnmappedRead() {
        // BAM convention: unmapped reads carry chromosome="*",
        // position=-1. Flag bit 0x4 (segment unmapped) set.
        AccessUnit au = new AccessUnit(
            5, 0, 0, 2,
            0.0, 0.0, 0,
            0.0, 0.0,
            List.of(),
            0L, 0L, 0L,
            "*", -1L, 0, 0x0004);
        AccessUnit decoded = AccessUnit.decode(au.encode());
        assertEquals(-1L, decoded.position);
        assertEquals("*", decoded.chromosome);
        assertEquals(0x0004, decoded.flags);
    }

    @Test
    void genomicReadLongChromosomeMaxMapqMaxFlags() {
        // Decoy contigs can have long names; mapq is uint8 (max 255);
        // flags are uint16 (max 0xFFFF).
        String longChr = "chr22_KI270739v1_random";
        AccessUnit au = new AccessUnit(
            5, 0, 0, 2,
            0.0, 0.0, 0,
            0.0, 0.0,
            List.of(),
            0L, 0L, 0L,
            longChr, 42L, 255, 0xFFFF);
        AccessUnit decoded = AccessUnit.decode(au.encode());
        assertEquals(longChr, decoded.chromosome);
        assertEquals(255, decoded.mappingQuality);
        assertEquals(0xFFFF, decoded.flags);
    }

    @Test
    void genomicReadTruncatedSuffixRaises() {
        // Missing the genomic suffix on a spectrum_class==5 AU should
        // raise a clear exception, not silently decode to zeros.
        AccessUnit au = new AccessUnit(
            5, 0, 0, 2,
            0.0, 0.0, 0,
            0.0, 0.0,
            List.of(),
            0L, 0L, 0L,
            "chr1", 100L, 60, 0);
        byte[] full = au.encode();
        // Drop the trailing flags (last 2 bytes) so the suffix is short.
        byte[] truncated = Arrays.copyOf(full, full.length - 2);
        IllegalArgumentException ex = assertThrows(
            IllegalArgumentException.class,
            () -> AccessUnit.decode(truncated));
        assertTrue(ex.getMessage().contains("GenomicRead"),
            "exception message should mention GenomicRead, got: " + ex.getMessage());
    }

    @Test
    void nonGenomicAuSilentlyIgnoresAccidentalChromosome() {
        // An MS AU (spectrum_class==0) with chromosome accidentally
        // passed should not write a genomic suffix; the decoder returns
        // the default "" / 0 / 0 / 0.
        AccessUnit au = new AccessUnit(
            0, 0, 1, 0,
            1.0, 0.0, 0,
            0.0, 0.0,
            List.of(),
            0L, 0L, 0L,
            "should-be-ignored", 999L, 42, 0xBEEF);
        AccessUnit decoded = AccessUnit.decode(au.encode());
        assertEquals(0, decoded.spectrumClass);
        assertEquals("", decoded.chromosome);
        assertEquals(0L, decoded.position);
        assertEquals(0, decoded.mappingQuality);
        assertEquals(0, decoded.flags);
    }

    // ────────────────────────────────────────────────────────────────
    // M89.3 — AUFilter chromosome + position predicates
    // ────────────────────────────────────────────────────────────────

    private static AccessUnit makeMsAu(double rt, int msLevel) {
        return new AccessUnit(
            0, 0, msLevel, 0,
            rt, 0.0, 0,
            0.0, 0.0,
            List.of(),
            0L, 0L, 0L,
            "", 0L, 0, 0);
    }

    private static AccessUnit makeGenomicAu(String chrom, long position) {
        return new AccessUnit(
            5, 0, 0, 2,
            0.0, 0.0, 0,
            0.0, 0.0,
            List.of(),
            0L, 0L, 0L,
            chrom, position, 60, 0);
    }

    @Test
    void filterChromosomeMatch() {
        AUFilter f = new AUFilter(null, null, null, null, null, null, null, null,
                                    "chr1", null, null);
        assertTrue(f.matches(makeGenomicAu("chr1", 100), 1));
        assertFalse(f.matches(makeGenomicAu("chr2", 100), 1));
    }

    @Test
    void filterPositionRange() {
        AUFilter f = new AUFilter(null, null, null, null, null, null, null, null,
                                    null, 100L, 200L);
        assertFalse(f.matches(makeGenomicAu("chr1", 50), 1));
        assertTrue(f.matches(makeGenomicAu("chr1", 100), 1));
        assertTrue(f.matches(makeGenomicAu("chr1", 150), 1));
        assertTrue(f.matches(makeGenomicAu("chr1", 200), 1));
        assertFalse(f.matches(makeGenomicAu("chr1", 201), 1));
    }

    @Test
    void filterChromosomeAndPositionCombined() {
        AUFilter f = new AUFilter(null, null, null, null, null, null, null, null,
                                    "chr3", 1000L, 2000L);
        assertTrue(f.matches(makeGenomicAu("chr3", 1500), 1));
        assertFalse(f.matches(makeGenomicAu("chr1", 1500), 1));
        assertFalse(f.matches(makeGenomicAu("chr3", 500), 1));
    }

    @Test
    void filterUnmappedReadsMatchChromosomeStar() {
        AUFilter f = new AUFilter(null, null, null, null, null, null, null, null,
                                    "*", null, null);
        assertTrue(f.matches(makeGenomicAu("*", -1L), 1));
    }

    @Test
    void filterChromosomeExcludesMsAus() {
        // MS AU (spectrum_class==0, chromosome=="") MUST NOT match a
        // chromosome filter - clean separation in multiplexed streams.
        AUFilter f = new AUFilter(null, null, null, null, null, null, null, null,
                                    "chr1", null, null);
        assertFalse(f.matches(makeMsAu(1.0, 1), 1));
    }

    @Test
    void filterPositionExcludesMsAus() {
        // MS AU has no notion of position; a position filter MUST
        // exclude it (semantic separation in multiplexed streams).
        AUFilter f = new AUFilter(null, null, null, null, null, null, null, null,
                                    null, 100L, null);
        assertFalse(f.matches(makeMsAu(1.0, 1), 1));
    }

    @Test
    void emptyFilterAcceptsBothModalities() {
        AUFilter f = new AUFilter();
        assertTrue(f.matches(makeMsAu(1.5, 1), 1));
        assertTrue(f.matches(makeGenomicAu("chrZ", 999), 1));
    }

    @Test
    void filterFromQueryJsonParsesGenomicKeys() {
        String json = "{\"type\":\"query\",\"filters\":{\"chromosome\":\"chrX\","
                + "\"position_min\":10,\"position_max\":20}}";
        AUFilter f = AUFilter.fromQueryJson(json);
        assertEquals("chrX", f.chromosome);
        assertEquals(Long.valueOf(10L), f.positionMin);
        assertEquals(Long.valueOf(20L), f.positionMax);
    }

    @Test
    void filterEmptyAcceptsAllGenomic() {
        AUFilter f = new AUFilter();
        assertTrue(f.matches(makeGenomicAu("chrZ", 999), 1));
    }

    // ────────────────────────────────────────────────────────────────
    // Helper fixtures for round-trip tests
    // ────────────────────────────────────────────────────────────────

    private static WrittenGenomicRun makeMinimalGenomicRun() {
        // 4 reads on chr1/chr1/chr2/* with the layout used by the
        // Python TestGenomicRoundTrip fixture.
        int n = 4;
        String[] chroms = {"chr1", "chr1", "chr2", "*"};
        long[] positions = {100L, 200L, 50L, -1L};
        byte[] mqs = {(byte) 60, (byte) 55, (byte) 40, (byte) 0};
        int[] flags = {0x0003, 0x0003, 0x0003, 0x0004};
        // Each read 12 bases of "ACGTACGTACGT"; qualities all 30.
        byte[] template = "ACGTACGTACGT".getBytes(StandardCharsets.US_ASCII);
        int readLen = template.length;
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
        List<String> chromsList = new ArrayList<>(Arrays.asList(chroms));
        List<String> cigars = new ArrayList<>(n);
        List<String> readNames = new ArrayList<>(n);
        List<String> mateChroms = new ArrayList<>(n);
        long[] matePos = new long[n];
        int[] tlens = new int[n];
        for (int i = 0; i < n; i++) {
            cigars.add(readLen + "M");
            readNames.add(String.format("read_%03d", i));
            mateChroms.add("");
            matePos[i] = -1L;
            tlens[i] = 0;
        }
        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS,
            "GRCh38.p14", "ILLUMINA", "NA12878",
            positions, mqs, flags, sequences, qualities,
            offsets, lengths, cigars, readNames, mateChroms,
            matePos, tlens, chromsList, Compression.ZLIB);
    }

    private static SpectralDataset writeMinimalGenomicDataset(Path file) {
        WrittenGenomicRun run = makeMinimalGenomicRun();
        // Pattern (from GenomicRunTest): create then re-open so the
        // returned dataset's StorageGroups are live for downstream
        // read paths (the create() call closes its read-side handles
        // after writing).
        SpectralDataset.create(file.toString(),
            "M89 genomic round-trip fixture", "ISA-M89-TEST",
            List.of(), List.of(run),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        return SpectralDataset.open(file.toString());
    }

    // ────────────────────────────────────────────────────────────────
    // M89.2 — TransportWriter / Reader genomic round-trip
    // ────────────────────────────────────────────────────────────────

    @Test
    void emitsOneAuPerRead(@TempDir Path tmp) throws Exception {
        try (SpectralDataset src = writeMinimalGenomicDataset(tmp.resolve("src.tio"))) {
            ByteArrayOutputStream stream = new ByteArrayOutputStream();
            try (TransportWriter tw = new TransportWriter(stream)) {
                tw.writeDataset(src);
            }
            try (TransportReader tr = new TransportReader(stream.toByteArray())) {
                List<TransportReader.PacketRecord> packets = tr.readAllPackets();
                List<PacketType> types = new ArrayList<>(packets.size());
                for (TransportReader.PacketRecord p : packets) {
                    types.add(p.header.packetType);
                }
                // StreamHeader, DatasetHeader, 4 AUs, EndOfDataset, EndOfStream = 8.
                assertEquals(List.of(
                    PacketType.STREAM_HEADER,
                    PacketType.DATASET_HEADER,
                    PacketType.ACCESS_UNIT,
                    PacketType.ACCESS_UNIT,
                    PacketType.ACCESS_UNIT,
                    PacketType.ACCESS_UNIT,
                    PacketType.END_OF_DATASET,
                    PacketType.END_OF_STREAM
                ), types);
            }
        }
    }

    @Test
    void auCarriesGenomicSuffix(@TempDir Path tmp) throws Exception {
        try (SpectralDataset src = writeMinimalGenomicDataset(tmp.resolve("src.tio"))) {
            ByteArrayOutputStream stream = new ByteArrayOutputStream();
            try (TransportWriter tw = new TransportWriter(stream)) {
                tw.writeDataset(src);
            }
            List<AccessUnit> aus = new ArrayList<>();
            try (TransportReader tr = new TransportReader(stream.toByteArray())) {
                for (TransportReader.PacketRecord p : tr.readAllPackets()) {
                    if (p.header.packetType == PacketType.ACCESS_UNIT) {
                        aus.add(AccessUnit.decode(p.payload));
                    }
                }
            }
            assertEquals(4, aus.size());
            for (AccessUnit au : aus) assertEquals(5, au.spectrumClass);
            assertEquals(List.of("chr1", "chr1", "chr2", "*"),
                List.of(aus.get(0).chromosome, aus.get(1).chromosome,
                        aus.get(2).chromosome, aus.get(3).chromosome));
            assertEquals(100L, aus.get(0).position);
            assertEquals(200L, aus.get(1).position);
            assertEquals(50L, aus.get(2).position);
            assertEquals(-1L, aus.get(3).position);
            assertEquals(60, aus.get(0).mappingQuality);
            assertEquals(0x0003, aus.get(0).flags);
            assertEquals(0x0004, aus.get(3).flags);
            // Sequences came back as one UINT8 channel per AU.
            ChannelData seqCh = null;
            for (ChannelData c : aus.get(0).channels) {
                if ("sequences".equals(c.name)) { seqCh = c; break; }
            }
            assertNotNull(seqCh);
            assertEquals("ACGTACGTACGT",
                new String(seqCh.data, 0, 12, StandardCharsets.US_ASCII));
        }
    }

    @Test
    void roundTripGenomicToFile(@TempDir Path tmp) throws Exception {
        try (SpectralDataset src = writeMinimalGenomicDataset(tmp.resolve("src.tio"))) {
            ByteArrayOutputStream stream = new ByteArrayOutputStream();
            try (TransportWriter tw = new TransportWriter(stream)) {
                tw.writeDataset(src);
            }
            Path outPath = tmp.resolve("rt.tio");
            try (TransportReader tr = new TransportReader(stream.toByteArray());
                 SpectralDataset rt = tr.materializeTo(outPath.toString())) {
                assertEquals(1, rt.genomicRuns().size());
                GenomicRun gr = rt.genomicRuns().get("genomic_0001");
                assertNotNull(gr);
                assertEquals(4, gr.readCount());
                assertEquals(List.of("chr1", "chr1", "chr2", "*"),
                    List.of(gr.index().chromosomeAt(0), gr.index().chromosomeAt(1),
                            gr.index().chromosomeAt(2), gr.index().chromosomeAt(3)));
                assertEquals(100L, gr.index().positionAt(0));
                assertEquals(200L, gr.index().positionAt(1));
                assertEquals(50L, gr.index().positionAt(2));
                assertEquals(-1L, gr.index().positionAt(3));
                assertEquals(60, gr.index().mappingQualityAt(0));
                assertEquals(0x0003, gr.index().flagsAt(0));
                assertEquals(0x0004, gr.index().flagsAt(3));
                AlignedRead r0 = gr.readAt(0);
                assertEquals("ACGTACGTACGT", r0.sequence());
                byte[] expectedQuals = new byte[12];
                Arrays.fill(expectedQuals, (byte) 30);
                assertArrayEquals(expectedQuals, r0.qualities());
            }
        }
    }

    // ────────────────────────────────────────────────────────────────
    // M89.4 — Multiplexed MS + genomic round-trip
    // ────────────────────────────────────────────────────────────────

    private static SpectralDataset writeMultiplexedDataset(Path file) {
        // ── MS run (3 spectra, 4 points each) ──
        int msN = 3, msPoints = 4;
        int msTotal = msN * msPoints;
        double[] mzAll = new double[msTotal];
        double[] intAll = new double[msTotal];
        for (int i = 0; i < msTotal; i++) {
            mzAll[i] = 100.0 + i;
            intAll[i] = 1000.0 * (i + 1);
        }
        long[] msOffsets = {0, 4, 8};
        int[] msLengths = {4, 4, 4};
        double[] msRts = {1.0, 2.0, 3.0};
        int[] msLevels = {1, 2, 1};
        int[] msPols = {1, 1, 1};
        double[] msPmzs = {0.0, 500.25, 0.0};
        int[] msPcs = {0, 2, 0};
        double[] msBpis = new double[msN];
        for (int i = 0; i < msN; i++) {
            double best = 0;
            for (int k = 0; k < msPoints; k++)
                best = Math.max(best, intAll[i * msPoints + k]);
            msBpis[i] = best;
        }
        SpectrumIndex idx = new SpectrumIndex(msN, msOffsets, msLengths, msRts,
                msLevels, msPols, msPmzs, msPcs, msBpis);
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("mz", mzAll);
        channels.put("intensity", intAll);
        InstrumentConfig cfg = new InstrumentConfig("", "", "", "", "", "");
        AcquisitionRun msRun = new AcquisitionRun("run_0001",
                AcquisitionMode.MS1_DDA, idx, cfg, channels,
                List.of(), List.of(), "", 0.0);

        // ── Genomic run (3 reads, 8 bases each) ──
        int gN = 3, gLen = 8;
        byte[] template = "ACGTACGT".getBytes(StandardCharsets.US_ASCII);
        byte[] sequences = new byte[gN * gLen];
        byte[] qualities = new byte[gN * gLen];
        long[] gOffsets = new long[gN];
        int[] gLengths = new int[gN];
        for (int i = 0; i < gN; i++) {
            System.arraycopy(template, 0, sequences, i * gLen, gLen);
            gOffsets[i] = (long) i * gLen;
            gLengths[i] = gLen;
        }
        Arrays.fill(qualities, (byte) 30);
        long[] gPositions = {100L, 200L, 300L};
        byte[] gMqs = new byte[gN];
        Arrays.fill(gMqs, (byte) 60);
        int[] gFlags = {0x0003, 0x0003, 0x0003};
        List<String> gChroms = new ArrayList<>(List.of("chr1", "chr1", "chr2"));
        List<String> gCigars = new ArrayList<>(gN);
        List<String> gReadNames = new ArrayList<>(gN);
        List<String> gMateChroms = new ArrayList<>(gN);
        long[] gMatePos = new long[gN];
        int[] gTlens = new int[gN];
        for (int i = 0; i < gN; i++) {
            gCigars.add(gLen + "M");
            gReadNames.add(String.format("read_%03d", i));
            gMateChroms.add("");
            gMatePos[i] = -1L;
            gTlens[i] = 0;
        }
        WrittenGenomicRun gRun = new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS,
            "GRCh38.p14", "ILLUMINA", "NA12878",
            gPositions, gMqs, gFlags, sequences, qualities,
            gOffsets, gLengths, gCigars, gReadNames, gMateChroms,
            gMatePos, gTlens, gChroms, Compression.ZLIB);

        SpectralDataset.create(file.toString(),
            "M89.4 multiplexed fixture", "ISA-M89-MUX",
            List.of(msRun), List.of(gRun),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        return SpectralDataset.open(file.toString());
    }

    @Test
    void multiplexedPacketSequenceCarriesBothModalities(@TempDir Path tmp) throws Exception {
        try (SpectralDataset src = writeMultiplexedDataset(tmp.resolve("mux.tio"))) {
            ByteArrayOutputStream stream = new ByteArrayOutputStream();
            try (TransportWriter tw = new TransportWriter(stream)) {
                tw.writeDataset(src);
            }
            try (TransportReader tr = new TransportReader(stream.toByteArray())) {
                List<PacketType> types = new ArrayList<>();
                for (TransportReader.PacketRecord p : tr.readAllPackets()) {
                    types.add(p.header.packetType);
                }
                // StreamHeader, 2 DatasetHeaders, 3 MS AUs + EndOfDataset,
                // 3 genomic AUs + EndOfDataset, EndOfStream = 12.
                assertEquals(List.of(
                    PacketType.STREAM_HEADER,
                    PacketType.DATASET_HEADER,
                    PacketType.DATASET_HEADER,
                    PacketType.ACCESS_UNIT,
                    PacketType.ACCESS_UNIT,
                    PacketType.ACCESS_UNIT,
                    PacketType.END_OF_DATASET,
                    PacketType.ACCESS_UNIT,
                    PacketType.ACCESS_UNIT,
                    PacketType.ACCESS_UNIT,
                    PacketType.END_OF_DATASET,
                    PacketType.END_OF_STREAM
                ), types);
            }
        }
    }

    @Test
    void multiplexedRoundTripPreservesBothModalities(@TempDir Path tmp) throws Exception {
        try (SpectralDataset src = writeMultiplexedDataset(tmp.resolve("mux.tio"))) {
            ByteArrayOutputStream stream = new ByteArrayOutputStream();
            try (TransportWriter tw = new TransportWriter(stream)) {
                tw.writeDataset(src);
            }
            Path outPath = tmp.resolve("rt.tio");
            try (TransportReader tr = new TransportReader(stream.toByteArray());
                 SpectralDataset rt = tr.materializeTo(outPath.toString())) {
                // MS preserved.
                assertTrue(rt.msRuns().containsKey("run_0001"));
                AcquisitionRun msRt = rt.msRuns().get("run_0001");
                assertEquals(3, msRt.spectrumCount());
                // Genomic preserved.
                assertTrue(rt.genomicRuns().containsKey("genomic_0001"));
                GenomicRun gRt = rt.genomicRuns().get("genomic_0001");
                assertEquals(3, gRt.readCount());
                assertEquals("chr1", gRt.index().chromosomeAt(0));
                assertEquals("chr1", gRt.index().chromosomeAt(1));
                assertEquals("chr2", gRt.index().chromosomeAt(2));
                assertEquals(100L, gRt.index().positionAt(0));
                assertEquals(200L, gRt.index().positionAt(1));
                assertEquals(300L, gRt.index().positionAt(2));
                assertEquals("ACGTACGT", gRt.readAt(2).sequence());
            }
        }
    }

    @Test
    void multiplexedDatasetIdsDisjointPerModality(@TempDir Path tmp) throws Exception {
        // MS occupies dataset_id 1; genomic gets dataset_id 2.
        try (SpectralDataset src = writeMultiplexedDataset(tmp.resolve("mux.tio"))) {
            ByteArrayOutputStream stream = new ByteArrayOutputStream();
            try (TransportWriter tw = new TransportWriter(stream)) {
                tw.writeDataset(src);
            }
            List<Integer> ids = new ArrayList<>();
            try (TransportReader tr = new TransportReader(stream.toByteArray())) {
                for (TransportReader.PacketRecord p : tr.readAllPackets()) {
                    if (p.header.packetType == PacketType.ACCESS_UNIT) {
                        ids.add(p.header.datasetId);
                    }
                }
            }
            assertEquals(List.of(1, 1, 1, 2, 2, 2), ids);
        }
    }

    @Test
    void multiplexedGenomicFilterSkipsMsAus(@TempDir Path tmp) throws Exception {
        // A chromosome filter MUST skip MS AUs in a multiplexed stream.
        try (SpectralDataset src = writeMultiplexedDataset(tmp.resolve("mux.tio"))) {
            ByteArrayOutputStream stream = new ByteArrayOutputStream();
            try (TransportWriter tw = new TransportWriter(stream)) {
                tw.writeDataset(src);
            }
            AUFilter f = new AUFilter(null, null, null, null, null, null, null, null,
                                        "chr1", null, null);
            List<Integer> kept = new ArrayList<>();
            try (TransportReader tr = new TransportReader(stream.toByteArray())) {
                for (TransportReader.PacketRecord p : tr.readAllPackets()) {
                    if (p.header.packetType != PacketType.ACCESS_UNIT) continue;
                    AccessUnit au = AccessUnit.decode(p.payload);
                    if (f.matches(au, p.header.datasetId)) {
                        kept.add(au.spectrumClass);
                    }
                }
            }
            // Two genomic reads on chr1; zero MS AUs.
            assertEquals(List.of(5, 5), kept);
        }
    }

    // ────────────────────────────────────────────────────────────────
    // M89.5 — Per-AU AES-GCM round-trip preserves the genomic suffix
    // ────────────────────────────────────────────────────────────────

    private static final byte[] KEY32 = new byte[32];
    static {
        Arrays.fill(KEY32, (byte) 0x42);
    }

    private static byte[] aesGcmRoundTrip(byte[] plaintext) {
        // Use the per-AU AES-GCM primitive (no AAD; the genomic suffix
        // is opaque payload bytes from the cipher's perspective). Pass
        // null IV so PerAUEncryption generates a fresh random nonce -
        // GCM forbids IV reuse on the same key (Cipher.init throws
        // InvalidAlgorithmParameterException otherwise).
        GcmResult r = PerAUEncryption.encryptWithAad(plaintext, KEY32, null, null);
        return PerAUEncryption.decryptWithAad(r.iv(), r.tag(), r.ciphertext(),
                                                KEY32, null);
    }

    private static AccessUnit makeGenomicAuWithChannels(String chrom, long position,
                                                          int mapq, int flags,
                                                          byte[] sequence,
                                                          byte[] qualities) {
        return new AccessUnit(
            5, 0, 0, 2,
            0.0, 0.0, 0,
            0.0, 0.0,
            List.of(new ChannelData("sequences", 6, 0, sequence.length, sequence),
                    new ChannelData("qualities", 6, 0, qualities.length, qualities)),
            0L, 0L, 0L,
            chrom, position, mapq, flags);
    }

    @Test
    void perAuEncryptionPreservesGenomicSuffix() {
        AccessUnit au = makeGenomicAuWithChannels(
            "chr1", 123_456_789L, 60, 0x0003,
            "ACGTACGT".getBytes(StandardCharsets.US_ASCII),
            new byte[] {30, 30, 30, 30, 30, 30, 30, 30});
        AccessUnit decoded = AccessUnit.decode(aesGcmRoundTrip(au.encode()));
        assertEquals(5, decoded.spectrumClass);
        assertEquals("chr1", decoded.chromosome);
        assertEquals(123_456_789L, decoded.position);
        assertEquals(60, decoded.mappingQuality);
        assertEquals(0x0003, decoded.flags);
    }

    @Test
    void perAuEncryptionPreservesGenomicChannelsAndUnmappedRead() {
        AccessUnit au = makeGenomicAuWithChannels(
            "*", -1L, 0, 0x0004,
            "NNNNNN".getBytes(StandardCharsets.US_ASCII),
            new byte[] {2, 2, 2, 2, 2, 2});
        AccessUnit decoded = AccessUnit.decode(aesGcmRoundTrip(au.encode()));
        assertEquals("*", decoded.chromosome);
        assertEquals(-1L, decoded.position);
        assertEquals(0x0004, decoded.flags);
        assertEquals(2, decoded.channels.size());
        assertEquals("sequences", decoded.channels.get(0).name);
        assertArrayEquals("NNNNNN".getBytes(StandardCharsets.US_ASCII),
            decoded.channels.get(0).data);
        assertEquals("qualities", decoded.channels.get(1).name);
        assertArrayEquals(new byte[] {2, 2, 2, 2, 2, 2},
            decoded.channels.get(1).data);
    }
}
