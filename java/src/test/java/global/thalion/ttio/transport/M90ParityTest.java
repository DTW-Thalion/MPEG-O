/*
 * TTI-O Java Implementation - M90.8 / M90.9 / M90.10 parity tests.
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
import global.thalion.ttio.protection.EncryptedTransport;
import global.thalion.ttio.protection.PerAUFile;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Java parity tests for M90.8 (encrypted-transport for genomic_runs),
 * M90.9 (AU compound fields cigar/read_name/mate_chromosome/mate_position/
 * template_length), and M90.10 (UINT8 wire compression dispatch via M86
 * codecs). Mirrors the Python tests of the same names.
 */
class M90ParityTest {

    @TempDir Path tmp;

    private static byte[] key32(int fill) {
        byte[] k = new byte[32];
        Arrays.fill(k, (byte) fill);
        return k;
    }

    /** Build a small genomic-only run with N reads of L bases. */
    private static WrittenGenomicRun buildGenomicRun(int n, int L,
                                                      String[] chroms,
                                                      long[] positions,
                                                      Map<String, Compression> overrides) {
        byte[] template = "ACGTACGTACGT".getBytes(StandardCharsets.US_ASCII);
        byte[] sequences = new byte[n * L];
        byte[] qualities = new byte[n * L];
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        for (int i = 0; i < n; i++) {
            for (int k = 0; k < L; k++) sequences[i * L + k] = template[k % template.length];
            offsets[i] = (long) i * L;
            lengths[i] = L;
        }
        Arrays.fill(qualities, (byte) 30);
        byte[] mqs = new byte[n];
        Arrays.fill(mqs, (byte) 60);
        int[] flags = new int[n];
        Arrays.fill(flags, 0x0003);
        List<String> chromsList = new ArrayList<>(Arrays.asList(chroms));
        List<String> cigars = new ArrayList<>(n);
        List<String> readNames = new ArrayList<>(n);
        List<String> mateChroms = new ArrayList<>(n);
        long[] mateP = new long[n];
        int[] tlens = new int[n];
        for (int i = 0; i < n; i++) {
            cigars.add(L + "M");
            readNames.add(String.format("read_%03d", i));
            mateChroms.add("");
            mateP[i] = -1L;
            tlens[i] = 0;
        }
        Map<String, Compression> ovr = overrides == null ? Map.of() : overrides;
        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS,
            "GRCh38.p14", "ILLUMINA", "NA12878",
            positions, mqs, flags, sequences, qualities,
            offsets, lengths, cigars, readNames, mateChroms,
            mateP, tlens, chromsList, Compression.ZLIB, ovr);
    }

    private static void writeGenomicFixture(Path path, WrittenGenomicRun run) {
        SpectralDataset.create(path.toString(),
            "M90 fixture", "ISA-M90",
            List.of(), List.of(run),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
    }

    // ================================ M90.8 ================================

    @Test
    void m908_roundTripPreservesDecryptableCiphertextGenomic() throws Exception {
        int n = 4, L = 8;
        long[] positions = {100L, 200L, 300L, 400L};
        WrittenGenomicRun run = buildGenomicRun(n, L,
            new String[]{"chr1", "chr1", "chr2", "chr2"},
            positions, null);
        Path src = tmp.resolve("src.tio");
        writeGenomicFixture(src, run);

        byte[] key = key32(0x42);
        PerAUFile.encryptFile(src.toString(), key, false, "hdf5");
        assertTrue(EncryptedTransport.isPerAUEncrypted(src.toString(), "hdf5"));

        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        try (TransportWriter writer = new TransportWriter(bos)) {
            EncryptedTransport.writeEncryptedDataset(src.toString(), writer, "hdf5");
        }
        byte[] stream = bos.toByteArray();
        assertTrue(stream.length > 0);

        // Sanity: AU packets carry FLAG_ENCRYPTED.
        try (TransportReader reader = new TransportReader(stream)) {
            int auCount = 0, encCount = 0;
            for (TransportReader.PacketRecord rec : reader.readAllPackets()) {
                if (rec.header.packetType == PacketType.ACCESS_UNIT) {
                    auCount++;
                    if ((rec.header.flags & PacketHeader.FLAG_ENCRYPTED) != 0) encCount++;
                }
            }
            assertEquals(n, auCount);
            assertEquals(n, encCount);
        }

        Path dst = tmp.resolve("rt.tio");
        EncryptedTransport.readEncryptedToPath(dst.toString(), stream, "hdf5");
        assertTrue(EncryptedTransport.isPerAUEncrypted(dst.toString(), "hdf5"));

        Map<String, PerAUFile.DecryptedRun> plain = PerAUFile.decryptFile(
            dst.toString(), key, "hdf5");
        assertTrue(plain.containsKey("genomic_0001"),
            "genomic_0001 missing; got: " + plain.keySet());
        byte[] expectedSeqs = new byte[n * L];
        byte[] tmpl = "ACGTACGTACGT".getBytes(StandardCharsets.US_ASCII);
        for (int i = 0; i < expectedSeqs.length; i++) expectedSeqs[i] = tmpl[i % tmpl.length];
        assertArrayEquals(expectedSeqs, plain.get("genomic_0001").channels().get("sequences"));
        byte[] expectedQuals = new byte[n * L];
        Arrays.fill(expectedQuals, (byte) 30);
        assertArrayEquals(expectedQuals, plain.get("genomic_0001").channels().get("qualities"));
    }

    @Test
    void m908_mixedMsAndGenomicEncryptedTransportRoundTrip() throws Exception {
        // 1 MS run + 1 genomic run; encrypt + transport + read back.
        int msN = 2, msPts = 4;
        double[] mz = new double[msN * msPts];
        double[] intensity = new double[msN * msPts];
        for (int i = 0; i < mz.length; i++) {
            mz[i] = 100.0 + i;
            intensity[i] = i + 1.0;
        }
        SpectrumIndex idx = new SpectrumIndex(msN,
            new long[]{0, msPts}, new int[]{msPts, msPts},
            new double[]{1.0, 2.0}, new int[]{1, 1}, new int[]{1, 1},
            new double[]{0.0, 0.0}, new int[]{0, 0},
            new double[]{4.0, 8.0});
        Map<String, double[]> chans = new LinkedHashMap<>();
        chans.put("mz", mz);
        chans.put("intensity", intensity);
        AcquisitionRun msRun = new AcquisitionRun("run_0001",
            AcquisitionMode.MS1_DDA, idx,
            new InstrumentConfig("", "", "", "", "", ""),
            chans, List.of(), List.of(), null, 0.0);

        int gN = 2, gL = 4;
        WrittenGenomicRun gRun = buildGenomicRun(gN, gL,
            new String[]{"chr1", "chr2"},
            new long[]{100L, 200L}, null);
        Path src = tmp.resolve("mux.tio");
        SpectralDataset.create(src.toString(), "mux", "ISA-MUX",
            List.of(msRun), List.of(gRun),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();

        byte[] key = key32(0x42);
        PerAUFile.encryptFile(src.toString(), key, false, "hdf5");

        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        try (TransportWriter writer = new TransportWriter(bos)) {
            EncryptedTransport.writeEncryptedDataset(src.toString(), writer, "hdf5");
        }
        Path dst = tmp.resolve("mux_rt.tio");
        EncryptedTransport.readEncryptedToPath(dst.toString(), bos.toByteArray(), "hdf5");

        Map<String, PerAUFile.DecryptedRun> plain = PerAUFile.decryptFile(
            dst.toString(), key, "hdf5");
        assertTrue(plain.containsKey("run_0001"), "MS run missing");
        assertTrue(plain.containsKey("genomic_0001"), "genomic run missing");

        // MS plaintext recovered byte-exactly.
        byte[] mzExpected = new byte[mz.length * 8];
        java.nio.ByteBuffer mb = java.nio.ByteBuffer.wrap(mzExpected).order(java.nio.ByteOrder.LITTLE_ENDIAN);
        for (double d : mz) mb.putDouble(d);
        assertArrayEquals(mzExpected, plain.get("run_0001").channels().get("mz"));
        // Genomic sequences recovered byte-exactly.
        byte[] expectedSeqs = new byte[gN * gL];
        byte[] tmpl = "ACGTACGTACGT".getBytes(StandardCharsets.US_ASCII);
        for (int i = 0; i < expectedSeqs.length; i++) expectedSeqs[i] = tmpl[i % tmpl.length];
        assertArrayEquals(expectedSeqs, plain.get("genomic_0001").channels().get("sequences"));
    }

    // ================================ M90.9 ================================

    /** Build a 4-read genomic fixture with distinct per-read compound
     *  values so a mixup is detectable. */
    private static WrittenGenomicRun buildCompoundFieldGenomicRun(int n, int L) {
        byte[] template = "ACGTACGT".getBytes(StandardCharsets.US_ASCII);
        byte[] sequences = new byte[n * L];
        byte[] qualities = new byte[n * L];
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        for (int i = 0; i < n; i++) {
            for (int k = 0; k < L; k++) sequences[i * L + k] = template[k % template.length];
            offsets[i] = (long) i * L;
            lengths[i] = L;
        }
        Arrays.fill(qualities, (byte) 30);
        long[] positions = {100L, 200L, 300L, 400L};
        byte[] mqs = new byte[n];
        Arrays.fill(mqs, (byte) 60);
        int[] flags = {0x0003, 0x0083, 0x0003, 0x0083};
        List<String> chroms = List.of("chr1", "chr1", "chr2", "chr2");
        // Distinct per-read compound values:
        List<String> cigars = List.of("8M", "4M2I2M", "5M3D", "2S6M");
        List<String> readNames = List.of("read_aaaa", "read_bbbb", "read_cccc", "read_dddd");
        List<String> mateChroms = List.of("chr1", "chr1", "=", "");
        long[] mateP = {350L, 200L, 0L, -1L};
        int[] tlens = {250, 0, -300, 0};
        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS,
            "GRCh38.p14", "ILLUMINA", "NA12878",
            positions, mqs, flags, sequences, qualities,
            offsets, lengths, cigars, readNames, mateChroms,
            mateP, tlens, chroms, Compression.ZLIB);
    }

    @Test
    void m909_auWithMatePositionAndTemplateLengthRoundTrips() {
        AccessUnit au = new AccessUnit(
            5, 7, 0, 2,
            0.0, 0.0, 0,
            0.0, 0.0,
            List.of(),
            0L, 0L, 0L,
            "chr1", 100L, 60, 0x0003,
            350L, 250);
        AccessUnit dec = AccessUnit.decode(au.encode());
        assertEquals("chr1", dec.chromosome);
        assertEquals(100L, dec.position);
        assertEquals(350L, dec.matePosition);
        assertEquals(250, dec.templateLength);
    }

    @Test
    void m909_backwardCompatM891OnlySuffixDecodesWithDefaults() {
        // Manually craft an AU with only the M89.1 fixed suffix (no mate ext).
        // Decoder MUST default mate_position=-1 + tlen=0.
        java.nio.ByteBuffer bb = java.nio.ByteBuffer.allocate(64).order(java.nio.ByteOrder.LITTLE_ENDIAN);
        bb.put((byte) 5);   // spectrum_class
        bb.put((byte) 7);   // acquisition_mode
        bb.put((byte) 0);   // ms_level
        bb.put((byte) 2);   // polarity
        bb.putDouble(0.0);  // rt
        bb.putDouble(0.0);  // pmz
        bb.put((byte) 0);   // pc
        bb.putDouble(0.0);  // ion_mob
        bb.putDouble(0.0);  // bpi
        bb.put((byte) 0);   // n_channels
        byte[] chrom = "chr1".getBytes(StandardCharsets.US_ASCII);
        bb.putShort((short) chrom.length);
        bb.put(chrom);
        bb.putLong(100L);    // position
        bb.put((byte) 60);   // mapq
        bb.putShort((short) 0x0003);  // flags
        // No mate extension - M89.1-only payload.
        byte[] payload = Arrays.copyOf(bb.array(), bb.position());
        AccessUnit dec = AccessUnit.decode(payload);
        assertEquals("chr1", dec.chromosome);
        assertEquals(100L, dec.position);
        assertEquals(-1L, dec.matePosition);
        assertEquals(0, dec.templateLength);
    }

    @Test
    void m909_roundTripPreservesAllCompoundFields() throws Exception {
        WrittenGenomicRun run = buildCompoundFieldGenomicRun(4, 8);
        Path src = tmp.resolve("m909.tio");
        writeGenomicFixture(src, run);

        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        try (SpectralDataset ds = SpectralDataset.open(src.toString());
             TransportWriter writer = new TransportWriter(bos)) {
            writer.writeDataset(ds);
        }
        Path dst = tmp.resolve("m909_rt.tio");
        try (TransportReader reader = new TransportReader(bos.toByteArray());
             SpectralDataset rt = reader.materializeTo(dst.toString())) {
            GenomicRun gr = rt.genomicRuns().get("genomic_0001");
            assertNotNull(gr);
            assertEquals(4, gr.readCount());
            String[] expectedCigars = {"8M", "4M2I2M", "5M3D", "2S6M"};
            String[] expectedNames = {"read_aaaa", "read_bbbb", "read_cccc", "read_dddd"};
            // v1.7 mate_info v2 normalizes mate_chromosome on encode:
            //   "=" → own chrom id (resolves to RNAME on decode)
            //   ""  → id -1 → decodes as "*" (SAM no-mate sentinel)
            // chroms = {"chr1", "chr1", "chr2", "chr2"}, so input
            // mateChroms = {"chr1", "chr1", "=", ""} normalises to:
            String[] expectedMateChroms = {"chr1", "chr1", "chr2", "*"};
            long[] expectedMateP = {350L, 200L, 0L, -1L};
            int[] expectedTlens = {250, 0, -300, 0};
            for (int i = 0; i < 4; i++) {
                AlignedRead r = gr.readAt(i);
                assertEquals(expectedCigars[i], r.cigar(), "cigar mismatch at " + i);
                assertEquals(expectedNames[i], r.readName(), "readName mismatch at " + i);
                assertEquals(expectedMateChroms[i], r.mateChromosome(), "mateChrom mismatch at " + i);
                assertEquals(expectedMateP[i], r.matePosition(), "matePos mismatch at " + i);
                assertEquals(expectedTlens[i], r.templateLength(), "tlen mismatch at " + i);
            }
        }
    }

    @Test
    void m909_sequencesAndQualitiesStillRoundTrip() throws Exception {
        WrittenGenomicRun run = buildCompoundFieldGenomicRun(4, 8);
        Path src = tmp.resolve("m909_sq.tio");
        writeGenomicFixture(src, run);

        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        try (SpectralDataset ds = SpectralDataset.open(src.toString());
             TransportWriter writer = new TransportWriter(bos)) {
            writer.writeDataset(ds);
        }
        Path dst = tmp.resolve("m909_sq_rt.tio");
        try (TransportReader reader = new TransportReader(bos.toByteArray());
             SpectralDataset rt = reader.materializeTo(dst.toString())) {
            GenomicRun gr = rt.genomicRuns().get("genomic_0001");
            byte[] expectedQ = new byte[8];
            Arrays.fill(expectedQ, (byte) 30);
            for (int i = 0; i < 4; i++) {
                AlignedRead r = gr.readAt(i);
                assertEquals("ACGTACGT", r.sequence(), "seq mismatch at " + i);
                assertArrayEquals(expectedQ, r.qualities(), "quals mismatch at " + i);
            }
        }
    }

    // ================================ M90.10 ================================

    private static Map<String, List<Integer>> auCompressionsPerChannel(byte[] stream) throws Exception {
        Map<String, List<Integer>> out = new LinkedHashMap<>();
        try (TransportReader reader = new TransportReader(stream)) {
            for (TransportReader.PacketRecord rec : reader.readAllPackets()) {
                if (rec.header.packetType != PacketType.ACCESS_UNIT) continue;
                AccessUnit au = AccessUnit.decode(rec.payload);
                for (ChannelData ch : au.channels) {
                    out.computeIfAbsent(ch.name, k -> new ArrayList<>()).add(ch.compression);
                }
            }
        }
        return out;
    }

    private static WrittenGenomicRun buildPureAcgtGenomicRun(int n, int L,
                                                              Map<String, Compression> overrides) {
        byte[] template = "ACGTACGT".getBytes(StandardCharsets.US_ASCII);
        byte[] sequences = new byte[n * L];
        byte[] qualities = new byte[n * L];
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        for (int i = 0; i < n; i++) {
            for (int k = 0; k < L; k++) sequences[i * L + k] = template[k % template.length];
            offsets[i] = (long) i * L;
            lengths[i] = L;
        }
        Arrays.fill(qualities, (byte) 30);
        long[] positions = new long[n];
        for (int i = 0; i < n; i++) positions[i] = 100L + i * 100L;
        byte[] mqs = new byte[n];
        Arrays.fill(mqs, (byte) 60);
        int[] flags = new int[n];
        Arrays.fill(flags, 0x0003);
        List<String> chroms = new ArrayList<>();
        for (int i = 0; i < n; i++) chroms.add(i < n / 2 ? "chr1" : "chr2");
        List<String> cigars = new ArrayList<>();
        List<String> readNames = new ArrayList<>();
        List<String> mateChroms = new ArrayList<>();
        long[] mateP = new long[n];
        int[] tlens = new int[n];
        for (int i = 0; i < n; i++) {
            cigars.add(L + "M");
            readNames.add("read_" + i);
            mateChroms.add("");
            mateP[i] = -1L;
            tlens[i] = 0;
        }
        Map<String, Compression> ovr = overrides == null ? Map.of() : overrides;
        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS,
            "GRCh38.p14", "ILLUMINA", "NA12878",
            positions, mqs, flags, sequences, qualities,
            offsets, lengths, cigars, readNames, mateChroms,
            mateP, tlens, chroms, Compression.ZLIB, ovr);
    }

    @Test
    void m9010_noCodecSourceEmitsUncompressedWire() throws Exception {
        WrittenGenomicRun run = buildPureAcgtGenomicRun(4, 8, null);
        Path src = tmp.resolve("m1010_none.tio");
        writeGenomicFixture(src, run);
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        try (SpectralDataset ds = SpectralDataset.open(src.toString());
             TransportWriter writer = new TransportWriter(bos)) {
            writer.writeDataset(ds);
        }
        Map<String, List<Integer>> codecs = auCompressionsPerChannel(bos.toByteArray());
        assertEquals(List.of(0, 0, 0, 0), codecs.get("sequences"));
        assertEquals(List.of(0, 0, 0, 0), codecs.get("qualities"));
    }

    @Test
    void m9010_basePackSourceEmitsBasePackWire() throws Exception {
        WrittenGenomicRun run = buildPureAcgtGenomicRun(4, 8,
            Map.of("sequences", Compression.BASE_PACK));
        Path src = tmp.resolve("m1010_bp.tio");
        writeGenomicFixture(src, run);
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        try (SpectralDataset ds = SpectralDataset.open(src.toString());
             TransportWriter writer = new TransportWriter(bos)) {
            writer.writeDataset(ds);
        }
        Map<String, List<Integer>> codecs = auCompressionsPerChannel(bos.toByteArray());
        int bp = Compression.BASE_PACK.ordinal();
        assertEquals(List.of(bp, bp, bp, bp), codecs.get("sequences"));
        assertEquals(List.of(0, 0, 0, 0), codecs.get("qualities"));
    }

    @Test
    void m9010_ransOrder0SourceEmitsRansWire() throws Exception {
        WrittenGenomicRun run = buildPureAcgtGenomicRun(4, 8,
            Map.of("qualities", Compression.RANS_ORDER0));
        Path src = tmp.resolve("m1010_r0.tio");
        writeGenomicFixture(src, run);
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        try (SpectralDataset ds = SpectralDataset.open(src.toString());
             TransportWriter writer = new TransportWriter(bos)) {
            writer.writeDataset(ds);
        }
        Map<String, List<Integer>> codecs = auCompressionsPerChannel(bos.toByteArray());
        int r0 = Compression.RANS_ORDER0.ordinal();
        assertEquals(List.of(r0, r0, r0, r0), codecs.get("qualities"));
    }

    /** Round-trip through every supported wire codec. */
    private void roundTripAcrossCodec(Compression codec) throws Exception {
        WrittenGenomicRun run = buildPureAcgtGenomicRun(4, 8,
            Map.of("sequences", codec));
        Path src = tmp.resolve("m1010_rt_" + codec.name() + ".tio");
        writeGenomicFixture(src, run);
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        try (SpectralDataset ds = SpectralDataset.open(src.toString());
             TransportWriter writer = new TransportWriter(bos)) {
            writer.writeDataset(ds);
        }
        Path dst = tmp.resolve("m1010_rtout_" + codec.name() + ".tio");
        try (TransportReader reader = new TransportReader(bos.toByteArray());
             SpectralDataset rt = reader.materializeTo(dst.toString())) {
            GenomicRun gr = rt.genomicRuns().get("genomic_0001");
            byte[] expectedQ = new byte[8];
            Arrays.fill(expectedQ, (byte) 30);
            for (int i = 0; i < 4; i++) {
                AlignedRead r = gr.readAt(i);
                assertEquals("ACGTACGT", r.sequence(),
                    "codec=" + codec + " read " + i + " sequence mismatch");
                assertArrayEquals(expectedQ, r.qualities(),
                    "codec=" + codec + " read " + i + " qualities mismatch");
            }
        }
    }

    @Test
    void m9010_roundTripBasePack() throws Exception { roundTripAcrossCodec(Compression.BASE_PACK); }

    @Test
    void m9010_roundTripRansOrder0() throws Exception { roundTripAcrossCodec(Compression.RANS_ORDER0); }

    @Test
    void m9010_roundTripRansOrder1() throws Exception { roundTripAcrossCodec(Compression.RANS_ORDER1); }
}

