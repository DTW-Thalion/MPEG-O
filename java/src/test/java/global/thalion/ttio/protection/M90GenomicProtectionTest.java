/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.protection;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums;
import global.thalion.ttio.FeatureFlags;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.SpectrumIndex;
import global.thalion.ttio.genomics.GenomicRun;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.providers.ProviderRegistry;
import global.thalion.ttio.providers.StorageDataset;
import global.thalion.ttio.providers.StorageGroup;
import global.thalion.ttio.providers.StorageProvider;

import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

/**
 * M90 acceptance suite — genomic per-AU encryption (M90.1), genomic
 * dataset signatures (M90.2), genomic anonymisation (M90.3), and
 * region-keyed encryption (M90.4).
 *
 * <p>Mirrors the four Python test files
 * {@code python/tests/test_m90_*}. Python is the authority for the
 * on-disk format; Java tests assert the same observable behaviour
 * after round-tripping through the same providers.</p>
 */
class M90GenomicProtectionTest {

    @TempDir
    Path tempDir;

    private static byte[] key32(int fill) {
        byte[] k = new byte[32];
        Arrays.fill(k, (byte) fill);
        return k;
    }

    /** Build a small genomic-only fixture with {@code n} reads each
     *  of length {@code readLen}. */
    private static WrittenGenomicRun buildGenomicRun(int n, int readLen,
            byte[] sequencesConcat, byte[] qualitiesConcat,
            List<String> chromosomes, long[] positions) {
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        for (int i = 0; i < n; i++) {
            offsets[i] = (long) i * readLen;
            lengths[i] = readLen;
        }
        List<String> cigars = new ArrayList<>(n);
        List<String> readNames = new ArrayList<>(n);
        List<String> mateChromosomes = new ArrayList<>(n);
        long[] matePositions = new long[n];
        int[] templateLengths = new int[n];
        byte[] mappingQualities = new byte[n];
        int[] flags = new int[n];
        for (int i = 0; i < n; i++) {
            cigars.add(readLen + "M");
            readNames.add(String.format("read_%03d", i));
            mateChromosomes.add("");
            matePositions[i] = -1L;
            templateLengths[i] = 0;
            mappingQualities[i] = (byte) 60;
            flags[i] = 0x0003;
        }
        return new WrittenGenomicRun(
            Enums.AcquisitionMode.GENOMIC_WGS,
            "GRCh38.p14", "ILLUMINA", "NA12878",
            positions, mappingQualities, flags,
            sequencesConcat, qualitiesConcat,
            offsets, lengths, cigars, readNames, mateChromosomes,
            matePositions, templateLengths, chromosomes,
            Enums.Compression.ZLIB);
    }

    /** Build an "ACGTACGT" sequences + all-30 qualities fixture. */
    private String makeUniformGenomicFixture(String name, int n, int readLen) {
        byte[] seqUnit = "ACGTACGT".getBytes(StandardCharsets.US_ASCII);
        byte[] sequences = new byte[n * readLen];
        for (int i = 0; i < n * readLen; i++) {
            sequences[i] = seqUnit[i % seqUnit.length];
        }
        byte[] qualities = new byte[n * readLen];
        Arrays.fill(qualities, (byte) 30);
        long[] positions = new long[n];
        List<String> chroms = new ArrayList<>(n);
        for (int i = 0; i < n; i++) {
            positions[i] = 100L + i * 100L;
            chroms.add(i < n / 2 ? "chr1" : "chr2");
        }
        WrittenGenomicRun run = buildGenomicRun(
            n, readLen, sequences, qualities, chroms, positions);
        String path = tempDir.resolve(name).toString();
        SpectralDataset.create(path, "M90 fixture", "ISA-M90",
            List.of(), List.of(run),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        return path;
    }

    // ════════════════════════════════════════════════════════ M90.1 ══

    @Test
    void m901_encryptStripsPlaintextSignalChannels() {
        String path = makeUniformGenomicFixture("m901_strip.tio", 4, 8);
        PerAUFile.encryptFile(path, key32(0x42), false, "hdf5");

        try (StorageProvider sp = ProviderRegistry.open(path,
                StorageProvider.Mode.READ);
             StorageGroup root = sp.rootGroup();
             StorageGroup study = root.openGroup("study");
             StorageGroup gRuns = study.openGroup("genomic_runs");
             StorageGroup run = gRuns.openGroup("genomic_0001");
             StorageGroup sig = run.openGroup("signal_channels")) {
            for (String c : new String[]{"sequences", "qualities"}) {
                assertFalse(sig.hasChild(c),
                    "plaintext " + c + " should be stripped after encrypt");
                assertTrue(sig.hasChild(c + "_segments"),
                    c + "_segments compound should be present");
                Object algo = sig.getAttribute(c + "_algorithm");
                String algoStr = algo == null ? null
                    : (algo instanceof byte[] b
                        ? new String(b, StandardCharsets.UTF_8)
                        : algo.toString());
                assertEquals("aes-256-gcm", algoStr,
                    c + "_algorithm should be aes-256-gcm");
            }
        }
    }

    @Test
    void m901_roundTripRecoversByteExactPlaintext() {
        int n = 4, L = 8;
        String path = makeUniformGenomicFixture("m901_rt.tio", n, L);
        PerAUFile.encryptFile(path, key32(0x42), false, "hdf5");
        Map<String, PerAUFile.DecryptedRun> plain =
            PerAUFile.decryptFile(path, key32(0x42), "hdf5");

        assertTrue(plain.containsKey("genomic_0001"),
            "genomic_0001 missing; got: " + plain.keySet());
        PerAUFile.DecryptedRun run = plain.get("genomic_0001");
        byte[] expectedSeqs = new byte[n * L];
        byte[] seqUnit = "ACGTACGT".getBytes(StandardCharsets.US_ASCII);
        for (int i = 0; i < expectedSeqs.length; i++) {
            expectedSeqs[i] = seqUnit[i % seqUnit.length];
        }
        assertArrayEquals(expectedSeqs, run.channels().get("sequences"));
        byte[] expectedQuals = new byte[n * L];
        Arrays.fill(expectedQuals, (byte) 30);
        assertArrayEquals(expectedQuals, run.channels().get("qualities"));
    }

    @Test
    void m901_wrongKeyFails() {
        String path = makeUniformGenomicFixture("m901_wk.tio", 4, 8);
        PerAUFile.encryptFile(path, key32(0x42), false, "hdf5");
        assertThrows(RuntimeException.class, () ->
            PerAUFile.decryptFile(path, key32(0xFF), "hdf5"));
    }

    @Test
    void m901_mixedMsAndGenomicRoundTrip() {
        // 1 MS run + 1 genomic run. Ensures dataset_id_counter starts
        // at 1 for MS, advances to 2 for genomic — AAD reconstruction
        // depends on it.
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
            Enums.AcquisitionMode.MS1_DDA, idx,
            new InstrumentConfig("", "", "", "", "", ""),
            chans, List.of(), List.of(), null, 0.0);

        int gN = 2, gL = 4;
        byte[] gSeqs = ("ACGT" + "ACGT").getBytes(StandardCharsets.US_ASCII);
        byte[] gQuals = new byte[gN * gL];
        Arrays.fill(gQuals, (byte) 30);
        WrittenGenomicRun gRun = buildGenomicRun(gN, gL, gSeqs, gQuals,
            List.of("chr1", "chr2"),
            new long[]{100L, 200L});

        String path = tempDir.resolve("m901_mux.tio").toString();
        SpectralDataset.create(path, "mux", "ISA-MUX",
            List.of(msRun), List.of(gRun),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();

        PerAUFile.encryptFile(path, key32(0x42), false, "hdf5");
        Map<String, PerAUFile.DecryptedRun> plain =
            PerAUFile.decryptFile(path, key32(0x42), "hdf5");
        assertTrue(plain.containsKey("run_0001"));
        assertTrue(plain.containsKey("genomic_0001"));
        assertArrayEquals(gSeqs, plain.get("genomic_0001").channels().get("sequences"));
    }

    // ════════════════════════════════════════════════════════ M90.2 ══

    @Test
    void m902_hmacSignSequencesRoundTrip() {
        String path = makeUniformGenomicFixture("m902_seq.tio", 4, 8);
        byte[] key = SignatureManager.testKey();
        try (StorageProvider sp = ProviderRegistry.open(path,
                StorageProvider.Mode.READ_WRITE);
             StorageGroup root = sp.rootGroup();
             StorageGroup study = root.openGroup("study");
             StorageGroup gRuns = study.openGroup("genomic_runs");
             StorageGroup run = gRuns.openGroup("genomic_0001");
             StorageGroup sig = run.openGroup("signal_channels");
             StorageDataset ds = sig.openDataset("sequences")) {
            byte[] canonical = ds.readCanonicalBytes();
            String s = SignatureManager.sign(canonical, key);
            ds.setAttribute("ttio_signature", s);
            assertTrue(s.startsWith("v2:"));
            byte[] canonical2 = ds.readCanonicalBytes();
            assertTrue(SignatureManager.verify(canonical2, s, key));
        }
    }

    @Test
    void m902_wrongKeyRejected() {
        String path = makeUniformGenomicFixture("m902_wk.tio", 4, 8);
        byte[] key = SignatureManager.testKey();
        try (StorageProvider sp = ProviderRegistry.open(path,
                StorageProvider.Mode.READ_WRITE);
             StorageGroup root = sp.rootGroup();
             StorageGroup study = root.openGroup("study");
             StorageGroup gRuns = study.openGroup("genomic_runs");
             StorageGroup run = gRuns.openGroup("genomic_0001");
             StorageGroup sig = run.openGroup("signal_channels");
             StorageDataset ds = sig.openDataset("sequences")) {
            byte[] canonical = ds.readCanonicalBytes();
            String s = SignatureManager.sign(canonical, key);
            assertFalse(SignatureManager.verify(canonical, s, key32(0x00)));
        }
    }

    @Test
    void m902_runLevelSignAllChannelsAndIndex() {
        String path = makeUniformGenomicFixture("m902_run.tio", 4, 8);
        byte[] key = SignatureManager.testKey();
        Map<String, String> sigs;
        try (StorageProvider sp = ProviderRegistry.open(path,
                StorageProvider.Mode.READ_WRITE);
             StorageGroup root = sp.rootGroup();
             StorageGroup study = root.openGroup("study");
             StorageGroup gRuns = study.openGroup("genomic_runs");
             StorageGroup run = gRuns.openGroup("genomic_0001")) {
            sigs = SignatureManager.signGenomicRun(run, key);
        }
        assertTrue(sigs.containsKey("signal_channels/sequences"));
        assertTrue(sigs.containsKey("signal_channels/qualities"));
        assertTrue(sigs.containsKey("genomic_index/positions"));
        assertTrue(sigs.containsKey("genomic_index/mapping_qualities"));
        assertTrue(sigs.containsKey("genomic_index/flags"));
        // v1.10 #10: offsets no longer written on disk → not signed.
        assertFalse(sigs.containsKey("genomic_index/offsets"));
        assertTrue(sigs.containsKey("genomic_index/lengths"));
    }

    @Test
    void m902_verifyReturnsTrueOnCleanRun() {
        String path = makeUniformGenomicFixture("m902_v.tio", 4, 8);
        byte[] key = SignatureManager.testKey();
        try (StorageProvider sp = ProviderRegistry.open(path,
                StorageProvider.Mode.READ_WRITE);
             StorageGroup root = sp.rootGroup();
             StorageGroup study = root.openGroup("study");
             StorageGroup gRuns = study.openGroup("genomic_runs");
             StorageGroup run = gRuns.openGroup("genomic_0001")) {
            SignatureManager.signGenomicRun(run, key);
            assertTrue(SignatureManager.verifyGenomicRun(run, key));
        }
    }

    @Test
    void m902_verifyDetectsTamperedSignalChannel() {
        String path = makeUniformGenomicFixture("m902_t.tio", 4, 8);
        byte[] key = SignatureManager.testKey();
        try (StorageProvider sp = ProviderRegistry.open(path,
                StorageProvider.Mode.READ_WRITE);
             StorageGroup root = sp.rootGroup();
             StorageGroup study = root.openGroup("study");
             StorageGroup gRuns = study.openGroup("genomic_runs");
             StorageGroup run = gRuns.openGroup("genomic_0001")) {
            SignatureManager.signGenomicRun(run, key);
            try (StorageGroup sig = run.openGroup("signal_channels");
                 StorageDataset ds = sig.openDataset("sequences")) {
                byte[] data = (byte[]) ds.readAll();
                data[0] ^= 0x01;
                ds.writeAll(data);
            }
            assertFalse(SignatureManager.verifyGenomicRun(run, key));
        }
    }

    @Test
    void m902_mlDsa87RoundTrip() {
        // Skip if PQC isn't available in this build.
        PostQuantumCrypto.KeyPair kp;
        try {
            kp = PostQuantumCrypto.sigKeygen();
        } catch (Throwable t) {
            return;  // PQC not available — skip
        }
        String path = makeUniformGenomicFixture("m902_pqc.tio", 4, 8);
        try (StorageProvider sp = ProviderRegistry.open(path,
                StorageProvider.Mode.READ_WRITE);
             StorageGroup root = sp.rootGroup();
             StorageGroup study = root.openGroup("study");
             StorageGroup gRuns = study.openGroup("genomic_runs");
             StorageGroup run = gRuns.openGroup("genomic_0001");
             StorageGroup sig = run.openGroup("signal_channels");
             StorageDataset ds = sig.openDataset("sequences")) {
            byte[] canonical = ds.readCanonicalBytes();
            String s = SignatureManager.sign(canonical, kp.privateKey(), "ml-dsa-87");
            assertTrue(s.startsWith("v3:"));
            ds.setAttribute("ttio_signature", s);
            byte[] canonical2 = ds.readCanonicalBytes();
            assertTrue(SignatureManager.verify(canonical2, s,
                kp.publicKey(), "ml-dsa-87"));
        }
    }

    // ════════════════════════════════════════════════════════ M90.3 ══

    /** Build a 6-read fixture with read names, distinct qualities, and
     *  reads on chr1, chr1, chr2, chr3, chr3, chr3. */
    private String makeAnonFixture(String name) {
        int n = 6, L = 8;
        byte[] seqUnit = "ACGTACGT".getBytes(StandardCharsets.US_ASCII);
        byte[] sequences = new byte[n * L];
        for (int i = 0; i < sequences.length; i++) {
            sequences[i] = seqUnit[i % seqUnit.length];
        }
        byte[] qualities = new byte[n * L];
        for (int i = 0; i < n; i++) {
            Arrays.fill(qualities, i * L, (i + 1) * L, (byte) (10 + i));
        }
        List<String> chroms = List.of(
            "chr1", "chr1", "chr2", "chr3", "chr3", "chr3");
        long[] positions = {100L, 200L, 50L, 1000L, 2000L, 3000L};
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        for (int i = 0; i < n; i++) {
            offsets[i] = (long) i * L;
            lengths[i] = L;
        }
        List<String> cigars = new ArrayList<>(n);
        List<String> readNames = new ArrayList<>(n);
        List<String> mateChromosomes = new ArrayList<>(n);
        long[] matePositions = new long[n];
        int[] templateLengths = new int[n];
        byte[] mappingQualities = new byte[n];
        int[] flags = new int[n];
        for (int i = 0; i < n; i++) {
            cigars.add(L + "M");
            readNames.add(String.format("sensitive_id_%04d", i));
            mateChromosomes.add("");
            matePositions[i] = -1L;
            templateLengths[i] = 0;
            mappingQualities[i] = (byte) 60;
            flags[i] = 0x0003;
        }
        WrittenGenomicRun run = new WrittenGenomicRun(
            Enums.AcquisitionMode.GENOMIC_WGS,
            "GRCh38.p14", "ILLUMINA", "NA12878",
            positions, mappingQualities, flags,
            sequences, qualities,
            offsets, lengths, cigars, readNames, mateChromosomes,
            matePositions, templateLengths, chroms,
            Enums.Compression.ZLIB);
        String path = tempDir.resolve(name).toString();
        SpectralDataset.create(path, "M90.3 anon", "ISA-M90-3",
            List.of(), List.of(run),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        return path;
    }

    @Test
    void m903_stripReadNamesReplacesAllWithEmpty() {
        String src = makeAnonFixture("m903_strip_src.tio");
        String out = tempDir.resolve("m903_strip_out.tio").toString();
        Anonymizer.AnonymizationPolicy policy =
            new Anonymizer.AnonymizationPolicy(
                false, 0.0, false, 0.05, -1, -1, false,
                /* stripReadNames */ true,
                /* randomiseQualities */ false,
                30, null);
        Anonymizer.AnonymizationResult res;
        try (SpectralDataset ds = SpectralDataset.open(src)) {
            res = Anonymizer.anonymize(ds, out, policy);
        }
        assertEquals(6, res.readNamesStripped());
        try (SpectralDataset ds = SpectralDataset.open(out)) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertNotNull(gr);
            for (int i = 0; i < gr.readCount(); i++) {
                assertEquals("", gr.readAt(i).readName(),
                    "read " + i + " name should be stripped");
            }
        }
    }

    @Test
    void m903_stripReadNamesPreservesOtherFields() {
        String src = makeAnonFixture("m903_pres_src.tio");
        String out = tempDir.resolve("m903_pres_out.tio").toString();
        Anonymizer.AnonymizationPolicy policy =
            new Anonymizer.AnonymizationPolicy(
                false, 0.0, false, 0.05, -1, -1, false,
                true, false, 30, null);
        try (SpectralDataset ds = SpectralDataset.open(src)) {
            Anonymizer.anonymize(ds, out, policy);
        }
        try (SpectralDataset ds = SpectralDataset.open(out)) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertEquals(6, gr.readCount());
            assertEquals("chr1", gr.readAt(0).chromosome());
            assertEquals("chr2", gr.readAt(2).chromosome());
            assertEquals(100L, gr.readAt(0).position());
            assertEquals("ACGTACGT", gr.readAt(0).sequence());
        }
    }

    @Test
    void m903_randomiseQualitiesReplacesWithConstant() {
        String src = makeAnonFixture("m903_rand_src.tio");
        String out = tempDir.resolve("m903_rand_out.tio").toString();
        Anonymizer.AnonymizationPolicy policy =
            new Anonymizer.AnonymizationPolicy(
                false, 0.0, false, 0.05, -1, -1, false,
                false, /* randomiseQualities */ true,
                /* constant */ 30, null);
        Anonymizer.AnonymizationResult res;
        try (SpectralDataset ds = SpectralDataset.open(src)) {
            res = Anonymizer.anonymize(ds, out, policy);
        }
        assertEquals(6, res.qualitiesRandomised());
        try (SpectralDataset ds = SpectralDataset.open(out)) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            for (int i = 0; i < gr.readCount(); i++) {
                byte[] q = gr.readAt(i).qualities();
                for (byte b : q) {
                    assertEquals((byte) 30, b,
                        "read " + i + " quality should be 30");
                }
            }
        }
    }

    @Test
    void m903_randomiseQualitiesDefaultConstantIs30() {
        String src = makeAnonFixture("m903_def_src.tio");
        String out = tempDir.resolve("m903_def_out.tio").toString();
        Anonymizer.AnonymizationPolicy policy =
            new Anonymizer.AnonymizationPolicy(
                false, 0.0, false, 0.05, -1, -1, false,
                false, true, 30, null);
        try (SpectralDataset ds = SpectralDataset.open(src)) {
            Anonymizer.anonymize(ds, out, policy);
        }
        try (SpectralDataset ds = SpectralDataset.open(out)) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            for (byte b : gr.readAt(0).qualities()) {
                assertEquals((byte) 30, b);
            }
        }
    }

    @Test
    void m903_maskRegionsZerosSequencesInRegion() {
        String src = makeAnonFixture("m903_mask_src.tio");
        String out = tempDir.resolve("m903_mask_out.tio").toString();
        Anonymizer.AnonymizationPolicy policy =
            new Anonymizer.AnonymizationPolicy(
                false, 0.0, false, 0.05, -1, -1, false,
                false, false, 30,
                List.of(new Anonymizer.MaskRegion("chr1", 0, 1000)));
        Anonymizer.AnonymizationResult res;
        try (SpectralDataset ds = SpectralDataset.open(src)) {
            res = Anonymizer.anonymize(ds, out, policy);
        }
        // 2 reads on chr1 (positions 100, 200) match.
        assertEquals(2, res.readsInMaskedRegion());
        try (SpectralDataset ds = SpectralDataset.open(out)) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            String zeros = new String(new byte[8],
                StandardCharsets.US_ASCII);
            assertEquals(zeros, gr.readAt(0).sequence());
            assertEquals(zeros, gr.readAt(1).sequence());
            assertEquals("ACGTACGT", gr.readAt(2).sequence());
            assertEquals("ACGTACGT", gr.readAt(3).sequence());
        }
    }

    @Test
    void m903_maskRegionsPreservesReadCount() {
        String src = makeAnonFixture("m903_count_src.tio");
        String out = tempDir.resolve("m903_count_out.tio").toString();
        Anonymizer.AnonymizationPolicy policy =
            new Anonymizer.AnonymizationPolicy(
                false, 0.0, false, 0.05, -1, -1, false,
                false, false, 30,
                List.of(new Anonymizer.MaskRegion("chr1", 0, 1000)));
        try (SpectralDataset ds = SpectralDataset.open(src)) {
            Anonymizer.anonymize(ds, out, policy);
        }
        try (SpectralDataset ds = SpectralDataset.open(out)) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertEquals(6, gr.readCount());
            assertEquals("chr1", gr.readAt(0).chromosome());
            assertEquals("chr2", gr.readAt(2).chromosome());
            assertEquals("chr3", gr.readAt(5).chromosome());
        }
    }

    @Test
    void m903_multipleMaskRegions() {
        String src = makeAnonFixture("m903_multi_src.tio");
        String out = tempDir.resolve("m903_multi_out.tio").toString();
        // chr1 [0, 1000] hits 2 reads; chr3 [1500, 2500] hits position
        // 2000 (1 read). Total = 3.
        Anonymizer.AnonymizationPolicy policy =
            new Anonymizer.AnonymizationPolicy(
                false, 0.0, false, 0.05, -1, -1, false,
                false, false, 30,
                List.of(
                    new Anonymizer.MaskRegion("chr1", 0, 1000),
                    new Anonymizer.MaskRegion("chr3", 1500, 2500)));
        Anonymizer.AnonymizationResult res;
        try (SpectralDataset ds = SpectralDataset.open(src)) {
            res = Anonymizer.anonymize(ds, out, policy);
        }
        assertEquals(3, res.readsInMaskedRegion());
    }

    @Test
    void m903_combinedStripNamesAndMaskChr1() {
        String src = makeAnonFixture("m903_comb_src.tio");
        String out = tempDir.resolve("m903_comb_out.tio").toString();
        Anonymizer.AnonymizationPolicy policy =
            new Anonymizer.AnonymizationPolicy(
                false, 0.0, false, 0.05, -1, -1, false,
                true, false, 30,
                List.of(new Anonymizer.MaskRegion("chr1", 0, 1000)));
        Anonymizer.AnonymizationResult res;
        try (SpectralDataset ds = SpectralDataset.open(src)) {
            res = Anonymizer.anonymize(ds, out, policy);
        }
        assertEquals(6, res.readNamesStripped());
        assertEquals(2, res.readsInMaskedRegion());
        try (SpectralDataset ds = SpectralDataset.open(out)) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertEquals("", gr.readAt(0).readName());
            String zeros = new String(new byte[8], StandardCharsets.US_ASCII);
            assertEquals(zeros, gr.readAt(0).sequence());
            assertEquals("ACGTACGT", gr.readAt(2).sequence());  // chr2
        }
    }

    @Test
    void m903_noOpPolicyPreservesGenomicRun() {
        String src = makeAnonFixture("m903_noop_src.tio");
        String out = tempDir.resolve("m903_noop_out.tio").toString();
        // 7-arg policy (legacy MS-only). Genomic should still be
        // copied verbatim because the source carries genomic content.
        Anonymizer.AnonymizationPolicy policy =
            new Anonymizer.AnonymizationPolicy(
                false, 0.0, false, 0.05, -1, -1, false);
        try (SpectralDataset ds = SpectralDataset.open(src)) {
            Anonymizer.anonymize(ds, out, policy);
        }
        try (SpectralDataset ds = SpectralDataset.open(out)) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertEquals(6, gr.readCount());
            assertEquals("sensitive_id_0000", gr.readAt(0).readName());
            assertEquals("ACGTACGT", gr.readAt(0).sequence());
        }
    }

    // ════════════════════════════════════════════════════════ M90.4 ══

    /** Build a 6-read region-encryption fixture. 2 chr1, 2 chr6, 2
     *  chrX. Each read has a distinct base composition for unique
     *  identification on round-trip. */
    private String makeRegionFixture(String name) {
        int n = 6, L = 8;
        String seqStr =
            "AAAAAAAA"   // chr1 read 0
          + "TTTTTTTT"   // chr1 read 1
          + "GGGGGGGG"   // chr6 read 0
          + "CCCCCCCC"   // chr6 read 1
          + "NNNNNNNN"   // chrX read 0
          + "ACGTACGT";  // chrX read 1
        byte[] sequences = seqStr.getBytes(StandardCharsets.US_ASCII);
        byte[] qualities = new byte[n * L];
        for (int i = 0; i < n; i++) {
            Arrays.fill(qualities, i * L, (i + 1) * L, (byte) (20 + i));
        }
        List<String> chroms = List.of(
            "chr1", "chr1", "chr6", "chr6", "chrX", "chrX");
        long[] positions = {100L, 200L, 1000L, 1100L, 5000L, 5100L};
        WrittenGenomicRun run = buildGenomicRun(
            n, L, sequences, qualities, chroms, positions);
        String path = tempDir.resolve(name).toString();
        SpectralDataset.create(path, "M90.4 region", "ISA-M90-4",
            List.of(), List.of(run),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        return path;
    }

    @Test
    void m904_clearChromosomesHaveEmptyIv() {
        String path = makeRegionFixture("m904_iv.tio");
        Map<String, byte[]> keyMap = new LinkedHashMap<>();
        keyMap.put("chr6", key32(0x42));
        PerAUFile.encryptByRegion(path, keyMap, "hdf5");

        try (StorageProvider sp = ProviderRegistry.open(path,
                StorageProvider.Mode.READ);
             StorageGroup root = sp.rootGroup();
             StorageGroup study = root.openGroup("study");
             StorageGroup gRuns = study.openGroup("genomic_runs");
             StorageGroup run = gRuns.openGroup("genomic_0001");
             StorageGroup sig = run.openGroup("signal_channels")) {
            List<PerAUEncryption.ChannelSegment> segs =
                PerAUFile.readChannelSegments(sig, "sequences_segments");
            assertEquals(0, segs.get(0).iv().length, "chr1 read 0 clear");
            assertEquals(0, segs.get(1).iv().length, "chr1 read 1 clear");
            assertEquals(12, segs.get(2).iv().length, "chr6 read 0 enc");
            assertEquals(12, segs.get(3).iv().length, "chr6 read 1 enc");
            assertEquals(0, segs.get(4).iv().length, "chrX read 0 clear");
            assertEquals(0, segs.get(5).iv().length, "chrX read 1 clear");
        }
    }

    @Test
    void m904_decryptWithOnlyChr6KeyReturnsPlaintextForClear() {
        String path = makeRegionFixture("m904_rt.tio");
        Map<String, byte[]> keyMap = new LinkedHashMap<>();
        keyMap.put("chr6", key32(0x42));
        PerAUFile.encryptByRegion(path, keyMap, "hdf5");

        Map<String, PerAUFile.DecryptedRun> result =
            PerAUFile.decryptByRegion(path, keyMap, "hdf5");
        byte[] seqs = result.get("genomic_0001").channels().get("sequences");
        assertEquals(48, seqs.length);
        assertArrayEquals("AAAAAAAA".getBytes(StandardCharsets.US_ASCII),
            Arrays.copyOfRange(seqs, 0, 8));
        assertArrayEquals("GGGGGGGG".getBytes(StandardCharsets.US_ASCII),
            Arrays.copyOfRange(seqs, 16, 24));
        assertArrayEquals("ACGTACGT".getBytes(StandardCharsets.US_ASCII),
            Arrays.copyOfRange(seqs, 40, 48));
    }

    @Test
    void m904_twoKeysChr6AndChrX() {
        String path = makeRegionFixture("m904_two.tio");
        Map<String, byte[]> keyMap = new LinkedHashMap<>();
        keyMap.put("chr6", key32(0x42));
        keyMap.put("chrX", key32(0x77));
        PerAUFile.encryptByRegion(path, keyMap, "hdf5");

        Map<String, PerAUFile.DecryptedRun> result =
            PerAUFile.decryptByRegion(path, keyMap, "hdf5");
        byte[] seqs = result.get("genomic_0001").channels().get("sequences");
        assertArrayEquals("AAAAAAAA".getBytes(StandardCharsets.US_ASCII),
            Arrays.copyOfRange(seqs, 0, 8));
        assertArrayEquals("GGGGGGGG".getBytes(StandardCharsets.US_ASCII),
            Arrays.copyOfRange(seqs, 16, 24));
        assertArrayEquals("NNNNNNNN".getBytes(StandardCharsets.US_ASCII),
            Arrays.copyOfRange(seqs, 32, 40));
    }

    @Test
    void m904_missingKeyForEncryptedRegionFails() {
        String path = makeRegionFixture("m904_miss.tio");
        Map<String, byte[]> encMap = new LinkedHashMap<>();
        encMap.put("chr6", key32(0x42));
        PerAUFile.encryptByRegion(path, encMap, "hdf5");
        assertThrows(RuntimeException.class, () ->
            PerAUFile.decryptByRegion(path, Map.of(), "hdf5"));
    }

    @Test
    void m904_wrongKeyFails() {
        String path = makeRegionFixture("m904_wk.tio");
        Map<String, byte[]> encMap = new LinkedHashMap<>();
        encMap.put("chr6", key32(0x42));
        PerAUFile.encryptByRegion(path, encMap, "hdf5");
        Map<String, byte[]> wrongMap = new LinkedHashMap<>();
        wrongMap.put("chr6", key32(0xFF));
        assertThrows(RuntimeException.class, () ->
            PerAUFile.decryptByRegion(path, wrongMap, "hdf5"));
    }

    @Test
    void m904_qualitiesDispatchSameWay() {
        String path = makeRegionFixture("m904_q.tio");
        Map<String, byte[]> keyMap = new LinkedHashMap<>();
        keyMap.put("chr6", key32(0x42));
        PerAUFile.encryptByRegion(path, keyMap, "hdf5");
        Map<String, PerAUFile.DecryptedRun> result =
            PerAUFile.decryptByRegion(path, keyMap, "hdf5");
        byte[] quals = result.get("genomic_0001").channels().get("qualities");
        // Per-read distinct: read i has Phred (20+i) repeated.
        byte[] expected20 = new byte[8];
        Arrays.fill(expected20, (byte) 20);
        assertArrayEquals(expected20, Arrays.copyOfRange(quals, 0, 8));
        byte[] expected22 = new byte[8];
        Arrays.fill(expected22, (byte) 22);
        assertArrayEquals(expected22, Arrays.copyOfRange(quals, 16, 24));
        byte[] expected25 = new byte[8];
        Arrays.fill(expected25, (byte) 25);
        assertArrayEquals(expected25, Arrays.copyOfRange(quals, 40, 48));
    }

    @Test
    void m904_emptyKeyMapLeavesEverythingClear() {
        String path = makeRegionFixture("m904_noop.tio");
        PerAUFile.encryptByRegion(path, Map.of(), "hdf5");
        Map<String, PerAUFile.DecryptedRun> result =
            PerAUFile.decryptByRegion(path, Map.of(), "hdf5");
        byte[] seqs = result.get("genomic_0001").channels().get("sequences");
        String expected = "AAAAAAAA" + "TTTTTTTT" + "GGGGGGGG"
                        + "CCCCCCCC" + "NNNNNNNN" + "ACGTACGT";
        assertEquals(expected, new String(seqs, StandardCharsets.US_ASCII));
    }
}
