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
 * M90.11–M90.15 acceptance tests — closes gaps #5–#9 from the
 * post-M90 analysis. Each milestone mirrors a Python test file:
 *
 * <ul>
 *   <li>M90.11: encrypted genomic AU headers with per-region key map.</li>
 *   <li>M90.12: uint8-aware MPAD (CLI cross-language conformance).</li>
 *   <li>M90.13: SAM-overlap region masking (CIGAR-walked end coord).</li>
 *   <li>M90.14: seeded-RNG random Phred qualities.</li>
 *   <li>M90.15: signed chromosomes VL compound.</li>
 * </ul>
 */
class M90FinalTest {

    @TempDir
    Path tempDir;

    private static byte[] key32(int fill) {
        byte[] k = new byte[32];
        Arrays.fill(k, (byte) fill);
        return k;
    }

    /** Build a small genomic-only fixture. */
    private static WrittenGenomicRun buildGenomicRun(int n, int readLen,
            byte[] sequencesConcat, byte[] qualitiesConcat,
            List<String> chromosomes, long[] positions, List<String> cigars) {
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        for (int i = 0; i < n; i++) {
            offsets[i] = (long) i * readLen;
            lengths[i] = readLen;
        }
        List<String> readNames = new ArrayList<>(n);
        List<String> mateChromosomes = new ArrayList<>(n);
        long[] matePositions = new long[n];
        int[] templateLengths = new int[n];
        byte[] mappingQualities = new byte[n];
        int[] flags = new int[n];
        for (int i = 0; i < n; i++) {
            readNames.add(String.format("r%03d", i));
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

    /** 4 reads: 2 chr1, 2 chr6 — matches the Python M90.11 fixture. */
    private String makeM9011Fixture(String name) {
        int n = 4, L = 8;
        byte[] sequences = ("AAAAAAAA" + "TTTTTTTT" + "GGGGGGGG" + "CCCCCCCC")
            .getBytes(StandardCharsets.US_ASCII);
        byte[] qualities = new byte[n * L];
        Arrays.fill(qualities, (byte) 20);
        // Override the helper's defaults: distinct positions, custom mapqs/flags.
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        for (int i = 0; i < n; i++) {
            offsets[i] = (long) i * L;
            lengths[i] = L;
        }
        long[] positions = {100L, 200L, 1000L, 1100L};
        int[] flags = {0x0003, 0x0083, 0x0003, 0x0083};
        byte[] mapqs = {60, 55, 40, 50};
        List<String> chroms = List.of("chr1", "chr1", "chr6", "chr6");
        List<String> cigars = new ArrayList<>(n);
        List<String> readNames = new ArrayList<>(n);
        List<String> mateChromosomes = new ArrayList<>(n);
        long[] matePositions = new long[n];
        int[] templateLengths = new int[n];
        for (int i = 0; i < n; i++) {
            cigars.add(L + "M");
            readNames.add(String.format("r%03d", i));
            mateChromosomes.add("");
            matePositions[i] = -1L;
            templateLengths[i] = 0;
        }
        WrittenGenomicRun run = new WrittenGenomicRun(
            Enums.AcquisitionMode.GENOMIC_WGS,
            "GRCh38.p14", "ILLUMINA", "NA12878",
            positions, mapqs, flags, sequences, qualities,
            offsets, lengths, cigars, readNames, mateChromosomes,
            matePositions, templateLengths, chroms,
            Enums.Compression.ZLIB);
        String path = tempDir.resolve(name).toString();
        SpectralDataset.create(path, "M90.11 fixture", "ISA-M90-11",
            List.of(), List.of(run),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        return path;
    }

    // ════════════════════════════════════════════════════════ M90.11 ═

    @Test
    void m9011_headersKeyStripsPlaintextIndexColumns() {
        String path = makeM9011Fixture("m9011_strip.tio");
        Map<String, byte[]> keyMap = new LinkedHashMap<>();
        keyMap.put(PerAUFile.HEADERS_KEY_NAME, key32(0x11));
        PerAUFile.encryptByRegion(path, keyMap, "hdf5");

        try (StorageProvider sp = ProviderRegistry.open(path,
                StorageProvider.Mode.READ);
             StorageGroup root = sp.rootGroup();
             StorageGroup study = root.openGroup("study");
             StorageGroup gRuns = study.openGroup("genomic_runs");
             StorageGroup run = gRuns.openGroup("genomic_0001");
             StorageGroup idx = run.openGroup("genomic_index")) {
            // Plaintext columns should be gone.
            assertFalse(idx.hasChild("positions"),
                "positions should be encrypted");
            assertFalse(idx.hasChild("mapping_qualities"));
            assertFalse(idx.hasChild("flags"));
            // L1 (Task #82 Phase B.1): chromosomes are stored as
            // chromosome_ids + chromosome_names; encrypting wipes
            // both.
            assertFalse(idx.hasChild("chromosomes"));
            assertFalse(idx.hasChild("chromosome_ids"));
            assertFalse(idx.hasChild("chromosome_names"));
            // Encrypted blobs should be present.
            assertTrue(idx.hasChild("positions_encrypted"));
            assertTrue(idx.hasChild("mapping_qualities_encrypted"));
            assertTrue(idx.hasChild("flags_encrypted"));
            assertTrue(idx.hasChild("chromosomes_encrypted"));
            // offsets/lengths stay plaintext (structural framing).
            assertTrue(idx.hasChild("offsets"));
            assertTrue(idx.hasChild("lengths"));
        }
        FeatureFlags flags;
        try (StorageProvider sp = ProviderRegistry.open(path,
                StorageProvider.Mode.READ);
             StorageGroup root = sp.rootGroup()) {
            flags = FeatureFlags.readFrom(root);
        }
        assertTrue(flags.has(FeatureFlags.OPT_ENCRYPTED_AU_HEADERS),
            "opt_encrypted_au_headers must be set");
        assertTrue(flags.has(FeatureFlags.OPT_PER_AU_ENCRYPTION),
            "opt_per_au_encryption must be set when headers are encrypted");
        // Headers-only path should NOT add region-keyed flag.
        assertFalse(flags.has(FeatureFlags.OPT_REGION_KEYED_ENCRYPTION),
            "opt_region_keyed_encryption must NOT be set for headers-only");
    }

    @Test
    void m9011_roundTripRecoversIndexColumns() {
        String path = makeM9011Fixture("m9011_rt.tio");
        Map<String, byte[]> keyMap = new LinkedHashMap<>();
        keyMap.put(PerAUFile.HEADERS_KEY_NAME, key32(0x11));
        PerAUFile.encryptByRegion(path, keyMap, "hdf5");
        Map<String, PerAUFile.DecryptedRun> plain =
            PerAUFile.decryptByRegion(path, keyMap, "hdf5");
        PerAUFile.DecryptedRun run = plain.get("genomic_0001");
        assertNotNull(run);
        PerAUFile.GenomicIndexPlain idx = run.indexPlain();
        assertNotNull(idx, "indexPlain must be populated when headers are encrypted");
        assertEquals(List.of("chr1", "chr1", "chr6", "chr6"), idx.chromosomes());
        assertArrayEquals(new long[]{100L, 200L, 1000L, 1100L}, idx.positions());
        assertArrayEquals(new byte[]{60, 55, 40, 50}, idx.mappingQualities());
        assertArrayEquals(new int[]{0x0003, 0x0083, 0x0003, 0x0083}, idx.flags());
    }

    @Test
    void m9011_decryptWithoutHeadersKeyFails() {
        String path = makeM9011Fixture("m9011_no.tio");
        Map<String, byte[]> keyMap = new LinkedHashMap<>();
        keyMap.put(PerAUFile.HEADERS_KEY_NAME, key32(0x11));
        PerAUFile.encryptByRegion(path, keyMap, "hdf5");
        IllegalStateException ex = assertThrows(IllegalStateException.class,
            () -> PerAUFile.decryptByRegion(path, Map.of(), "hdf5"));
        assertTrue(ex.getMessage().contains("_headers"),
            "Error must mention _headers: " + ex.getMessage());
    }

    @Test
    void m9011_decryptWithWrongHeadersKeyFails() {
        String path = makeM9011Fixture("m9011_wk.tio");
        Map<String, byte[]> keyMap = new LinkedHashMap<>();
        keyMap.put(PerAUFile.HEADERS_KEY_NAME, key32(0x11));
        PerAUFile.encryptByRegion(path, keyMap, "hdf5");
        Map<String, byte[]> wrong = new LinkedHashMap<>();
        wrong.put(PerAUFile.HEADERS_KEY_NAME, key32(0xFF));
        assertThrows(RuntimeException.class,
            () -> PerAUFile.decryptByRegion(path, wrong, "hdf5"));
    }

    @Test
    void m9011_combinedHeadersAndRegionEncryption() {
        String path = makeM9011Fixture("m9011_combo.tio");
        Map<String, byte[]> keyMap = new LinkedHashMap<>();
        keyMap.put(PerAUFile.HEADERS_KEY_NAME, key32(0x11));
        keyMap.put("chr6", key32(0x42));
        PerAUFile.encryptByRegion(path, keyMap, "hdf5");
        Map<String, PerAUFile.DecryptedRun> plain =
            PerAUFile.decryptByRegion(path, keyMap, "hdf5");
        PerAUFile.DecryptedRun run = plain.get("genomic_0001");
        assertNotNull(run);
        assertEquals(List.of("chr1", "chr1", "chr6", "chr6"),
            run.indexPlain().chromosomes());
        // Sequences for ALL reads come back: chr1 clear, chr6 decrypted.
        byte[] seqs = run.channels().get("sequences");
        assertEquals(32, seqs.length);
        assertArrayEquals("AAAAAAAA".getBytes(StandardCharsets.US_ASCII),
            Arrays.copyOfRange(seqs, 0, 8));
        assertArrayEquals("GGGGGGGG".getBytes(StandardCharsets.US_ASCII),
            Arrays.copyOfRange(seqs, 16, 24));
    }

    @Test
    void m9011_partialKeysCannotRecoverIndex() {
        String path = makeM9011Fixture("m9011_partial.tio");
        Map<String, byte[]> encMap = new LinkedHashMap<>();
        encMap.put(PerAUFile.HEADERS_KEY_NAME, key32(0x11));
        encMap.put("chr6", key32(0x42));
        PerAUFile.encryptByRegion(path, encMap, "hdf5");
        Map<String, byte[]> partial = new LinkedHashMap<>();
        partial.put("chr6", key32(0x42));
        IllegalStateException ex = assertThrows(IllegalStateException.class,
            () -> PerAUFile.decryptByRegion(path, partial, "hdf5"));
        assertTrue(ex.getMessage().contains("_headers"));
    }

    @Test
    void m9011_regionOnlyKeyMapPreservesPlaintextIndex() {
        // When key_map has region keys but no _headers, the index
        // columns must STAY plaintext (M90.4 backward compat).
        String path = makeM9011Fixture("m9011_noheaders.tio");
        Map<String, byte[]> keyMap = new LinkedHashMap<>();
        keyMap.put("chr6", key32(0x42));
        PerAUFile.encryptByRegion(path, keyMap, "hdf5");

        try (StorageProvider sp = ProviderRegistry.open(path,
                StorageProvider.Mode.READ);
             StorageGroup root = sp.rootGroup();
             StorageGroup study = root.openGroup("study");
             StorageGroup gRuns = study.openGroup("genomic_runs");
             StorageGroup run = gRuns.openGroup("genomic_0001");
             StorageGroup idx = run.openGroup("genomic_index")) {
            assertTrue(idx.hasChild("positions"));
            assertTrue(idx.hasChild("mapping_qualities"));
            assertTrue(idx.hasChild("flags"));
            // L1 (Task #82 Phase B.1): chromosomes are decomposed
            // into chromosome_ids + chromosome_names instead of a
            // single chromosomes compound.
            assertTrue(idx.hasChild("chromosome_ids"));
            assertTrue(idx.hasChild("chromosome_names"));
            assertFalse(idx.hasChild("positions_encrypted"));
        }
        FeatureFlags flags;
        try (StorageProvider sp = ProviderRegistry.open(path,
                StorageProvider.Mode.READ);
             StorageGroup root = sp.rootGroup()) {
            flags = FeatureFlags.readFrom(root);
        }
        assertFalse(flags.has(FeatureFlags.OPT_ENCRYPTED_AU_HEADERS));
    }

    // ════════════════════════════════════════════════════════ M90.12 ═

    /** MS run fixture for MPAD float64-channel parity. */
    private String makeMsFixture(String name) {
        int n = 3, perSpec = 4;
        int total = n * perSpec;
        double[] mz = new double[total];
        double[] intensity = new double[total];
        for (int i = 0; i < total; i++) {
            mz[i] = 100.0 + i;
            intensity[i] = (i + 1) * 10.0;
        }
        SpectrumIndex idx = new SpectrumIndex(n,
            new long[]{0, perSpec, perSpec * 2}, new int[]{perSpec, perSpec, perSpec},
            new double[]{1.0, 2.0, 3.0}, new int[]{1, 2, 1},
            new int[]{1, 1, 1},
            new double[]{0.0, 500.0, 0.0}, new int[]{0, 2, 0},
            new double[]{40.0, 80.0, 120.0});
        Map<String, double[]> chans = new LinkedHashMap<>();
        chans.put("mz", mz);
        chans.put("intensity", intensity);
        AcquisitionRun run = new AcquisitionRun("run_0001",
            Enums.AcquisitionMode.MS1_DDA, idx,
            new InstrumentConfig("", "", "", "", "", ""),
            chans, List.of(), List.of(), null, 0.0);
        String path = tempDir.resolve(name).toString();
        SpectralDataset.create(path, "ms-fix", "ISA-MS",
            List.of(run), List.of(), List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        return path;
    }

    /** Genomic-only fixture for MPAD uint8-channel parity. */
    private String makeGenomicFixture(String name) {
        int n = 4, L = 8;
        byte[] sequences = new byte[n * L];
        byte[] tile = "ACGTACGT".getBytes(StandardCharsets.US_ASCII);
        for (int i = 0; i < sequences.length; i++) sequences[i] = tile[i % tile.length];
        byte[] qualities = new byte[n * L];
        Arrays.fill(qualities, (byte) 30);
        long[] positions = {100L, 200L, 300L, 400L};
        List<String> chroms = List.of("chr1", "chr1", "chr2", "chr2");
        List<String> cigars = List.of(L + "M", L + "M", L + "M", L + "M");
        WrittenGenomicRun run = buildGenomicRun(n, L, sequences, qualities,
            chroms, positions, cigars);
        String path = tempDir.resolve(name).toString();
        SpectralDataset.create(path, "g-fix", "ISA-G",
            List.of(), List.of(run), List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        return path;
    }

    /** Run the PerAUCli decrypt subcommand by direct main() invocation
     *  (no subprocess — keeps the suite single-JVM and quick). */
    private void runCliDecrypt(String inPath, String outPath, String keyPath)
            throws Exception {
        global.thalion.ttio.tools.PerAUCli.main(
            new String[]{"decrypt", inPath, outPath, keyPath});
    }

    private Path writeKeyFile(byte[] key, String name) throws Exception {
        Path p = tempDir.resolve(name);
        java.nio.file.Files.write(p, key);
        return p;
    }

    /** Parse MPA1 binary dump → {key → (dtype_code, value_bytes)}. */
    private static Map<String, int[]> parseDtypes(byte[] raw) {
        // Returns dtype codes only — keeps the test focused.
        assertEquals('M', raw[0]);
        assertEquals('P', raw[1]);
        assertEquals('A', raw[2]);
        assertEquals('1', raw[3]);
        java.nio.ByteBuffer bb = java.nio.ByteBuffer.wrap(raw)
            .order(java.nio.ByteOrder.LITTLE_ENDIAN);
        bb.position(4);
        int n = bb.getInt();
        Map<String, int[]> out = new LinkedHashMap<>();
        for (int i = 0; i < n; i++) {
            int klen = bb.getShort() & 0xFFFF;
            byte[] kb = new byte[klen];
            bb.get(kb);
            String key = new String(kb, StandardCharsets.UTF_8);
            int dtype = bb.get() & 0xFF;
            int vlen = bb.getInt();
            byte[] val = new byte[vlen];
            bb.get(val);
            // Stash dtype + length so tests can assert both.
            out.put(key, new int[]{dtype, vlen});
        }
        return out;
    }

    /** Parse MPA1 dump and return key → raw value bytes (for value
     *  comparisons). */
    private static Map<String, byte[]> parseValues(byte[] raw) {
        java.nio.ByteBuffer bb = java.nio.ByteBuffer.wrap(raw)
            .order(java.nio.ByteOrder.LITTLE_ENDIAN);
        bb.position(4);
        int n = bb.getInt();
        Map<String, byte[]> out = new LinkedHashMap<>();
        for (int i = 0; i < n; i++) {
            int klen = bb.getShort() & 0xFFFF;
            byte[] kb = new byte[klen];
            bb.get(kb);
            String key = new String(kb, StandardCharsets.UTF_8);
            bb.get();  // dtype byte (ignored in this helper)
            int vlen = bb.getInt();
            byte[] val = new byte[vlen];
            bb.get(val);
            out.put(key, val);
        }
        return out;
    }

    @Test
    void m9012_msDecryptEmitsFloat64Dtype() throws Exception {
        String src = makeMsFixture("m9012_ms.tio");
        PerAUFile.encryptFile(src, key32(0x77), false, "hdf5");
        Path key = writeKeyFile(key32(0x77), "m9012_msk.bin");
        Path out = tempDir.resolve("m9012_ms.mpad");
        runCliDecrypt(src, out.toString(), key.toString());
        byte[] raw = java.nio.file.Files.readAllBytes(out);
        Map<String, int[]> entries = parseDtypes(raw);
        assertTrue(entries.containsKey("run_0001__mz"));
        assertTrue(entries.containsKey("run_0001__intensity"));
        for (Map.Entry<String, int[]> e : entries.entrySet()) {
            assertEquals(1, e.getValue()[0],
                "MS channel " + e.getKey() + " must be dtype 1 (float64)");
            assertEquals(0, e.getValue()[1] % 8,
                "MS channel " + e.getKey() + " bytes must be multiple of 8");
        }
    }

    @Test
    void m9012_genomicDecryptEmitsUint8Dtype() throws Exception {
        String src = makeGenomicFixture("m9012_g.tio");
        PerAUFile.encryptFile(src, key32(0x77), false, "hdf5");
        Path key = writeKeyFile(key32(0x77), "m9012_gk.bin");
        Path out = tempDir.resolve("m9012_g.mpad");
        runCliDecrypt(src, out.toString(), key.toString());
        byte[] raw = java.nio.file.Files.readAllBytes(out);
        Map<String, int[]> entries = parseDtypes(raw);
        int[] seqEntry = entries.get("genomic_0001__sequences");
        assertNotNull(seqEntry);
        assertEquals(6, seqEntry[0],
            "genomic sequences must be dtype 6 (uint8)");
        // 4 reads × 8 bases = 32 bytes; NOT 256 (the pre-M90.12 cast bug).
        assertEquals(32, seqEntry[1]);
        Map<String, byte[]> values = parseValues(raw);
        byte[] expected = new byte[32];
        byte[] tile = "ACGTACGT".getBytes(StandardCharsets.US_ASCII);
        for (int i = 0; i < 32; i++) expected[i] = tile[i % tile.length];
        assertArrayEquals(expected, values.get("genomic_0001__sequences"));
        int[] qEntry = entries.get("genomic_0001__qualities");
        assertNotNull(qEntry);
        assertEquals(6, qEntry[0]);
        assertEquals(32, qEntry[1]);
    }

    @Test
    void m9012_mixedDtypeCodes() throws Exception {
        // Mixed MS + genomic file. MS entries get dtype 1, genomic 6.
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
        byte[] gSeqs = "ACGTACGT".getBytes(StandardCharsets.US_ASCII);
        byte[] gQuals = new byte[gN * gL];
        Arrays.fill(gQuals, (byte) 30);
        WrittenGenomicRun gRun = buildGenomicRun(gN, gL, gSeqs, gQuals,
            List.of("chr1", "chr2"), new long[]{100L, 200L},
            List.of(gL + "M", gL + "M"));
        String path = tempDir.resolve("m9012_mix.tio").toString();
        SpectralDataset.create(path, "mix", "ISA-MIX",
            List.of(msRun), List.of(gRun),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        PerAUFile.encryptFile(path, key32(0x77), false, "hdf5");
        Path keyPath = writeKeyFile(key32(0x77), "m9012_mxk.bin");
        Path out = tempDir.resolve("m9012_mix.mpad");
        runCliDecrypt(path, out.toString(), keyPath.toString());
        Map<String, int[]> entries = parseDtypes(
            java.nio.file.Files.readAllBytes(out));
        assertEquals(1, entries.get("run_0001__mz")[0]);
        assertEquals(1, entries.get("run_0001__intensity")[0]);
        assertEquals(6, entries.get("genomic_0001__sequences")[0]);
        assertEquals(6, entries.get("genomic_0001__qualities")[0]);
    }

    // ════════════════════════════════════════════════════════ M90.13 ═

    /** Build the M90.13 overlap fixture: 6 reads on chr1 with chosen
     *  positions + cigars to exercise SAM-overlap semantics around
     *  the region [100, 200]. */
    private String makeM9013OverlapFixture(String name) {
        int n = 6, L = 8;
        byte[] sequences = new byte[n * L];
        byte[] tile = "ACGTACGT".getBytes(StandardCharsets.US_ASCII);
        for (int i = 0; i < sequences.length; i++) {
            sequences[i] = tile[i % tile.length];
        }
        byte[] qualities = new byte[n * L];
        Arrays.fill(qualities, (byte) 30);
        long[] positions = {50L, 95L, 100L, 150L, 200L, 250L};
        // read 0: pos=50  "8M"     -> ref [50, 58)   — entirely before
        // read 1: pos=95  "8M"     -> ref [95, 103)  — extends in
        // read 2: pos=100 "8M"     -> ref [100, 108) — starts in
        // read 3: pos=150 "4M2I2M" -> ref [150, 156) — entirely in
        // read 4: pos=200 "8M"     -> ref [200, 208) — boundary
        // read 5: pos=250 "8M"     -> ref [250, 258) — entirely after
        List<String> cigars = List.of("8M", "8M", "8M", "4M2I2M", "8M", "8M");
        List<String> chroms = List.of("chr1", "chr1", "chr1", "chr1", "chr1", "chr1");
        WrittenGenomicRun run = buildGenomicRun(n, L, sequences, qualities,
            chroms, positions, cigars);
        String path = tempDir.resolve(name).toString();
        SpectralDataset.create(path, "M90.13 overlap", "ISA-M90-13",
            List.of(), List.of(run), List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        return path;
    }

    @Test
    void m9013_readStartingBeforeExtendingIntoRegionIsMasked() {
        String src = makeM9013OverlapFixture("m9013_ov.tio");
        String out = tempDir.resolve("m9013_ov_out.tio").toString();
        Anonymizer.AnonymizationPolicy policy =
            new Anonymizer.AnonymizationPolicy(
                false, 0.0, false, 0.05, -1, -1, false,
                false, false, 30,
                List.of(new Anonymizer.MaskRegion("chr1", 100, 200)));
        Anonymizer.AnonymizationResult res;
        try (SpectralDataset ds = SpectralDataset.open(src)) {
            res = Anonymizer.anonymize(ds, out, policy);
        }
        try (SpectralDataset ds = SpectralDataset.open(out)) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            String zeros = new String(new byte[8], StandardCharsets.US_ASCII);
            // read 0 (pos=50, end=57): entirely before — NOT masked
            assertEquals("ACGTACGT", gr.readAt(0).sequence());
            // read 1 (pos=95, end=102): overlaps [100,200] — MASKED
            assertEquals(zeros, gr.readAt(1).sequence(),
                "M90.13: read at pos=95 + CIGAR 8M extends to ref 102");
            // read 2 (pos=100, end=107): in region — masked
            assertEquals(zeros, gr.readAt(2).sequence());
            // read 3 (pos=150, end=155): entirely in region — masked
            assertEquals(zeros, gr.readAt(3).sequence());
            // read 4 (pos=200, end=207): boundary inclusive — masked
            assertEquals(zeros, gr.readAt(4).sequence());
            // read 5 (pos=250, end=257): entirely after — NOT masked
            assertEquals("ACGTACGT", gr.readAt(5).sequence());
        }
        assertEquals(4, res.readsInMaskedRegion());
    }

    @Test
    void m9013_cigarWithInsertionDoesNotConsumeRef() {
        String src = makeM9013OverlapFixture("m9013_ins.tio");
        String out = tempDir.resolve("m9013_ins_out.tio").toString();
        // Region [157, 1000] — read 3's CIGAR 4M2I2M consumes 6 ref
        // bases ending at 155, just below 157. Must NOT be masked.
        Anonymizer.AnonymizationPolicy policy =
            new Anonymizer.AnonymizationPolicy(
                false, 0.0, false, 0.05, -1, -1, false,
                false, false, 30,
                List.of(new Anonymizer.MaskRegion("chr1", 157, 1000)));
        try (SpectralDataset ds = SpectralDataset.open(src)) {
            Anonymizer.anonymize(ds, out, policy);
        }
        try (SpectralDataset ds = SpectralDataset.open(out)) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertEquals("ACGTACGT", gr.readAt(3).sequence(),
                "M90.13 bug: CIGAR 4M2I2M end-coord must be 155, not 157+");
        }
    }

    @Test
    void m9013_cigarWithDeletionConsumesRef() {
        // Single read at pos=180 with CIGAR=2M3D5M. Consumes 10 ref
        // bases → end = 180 + 10 - 1 = 189. Region [185, 200] — must
        // overlap.
        int n = 1, L = 7;  // 2 + 5 = 7 query bases
        byte[] sequences = "ACGTACG".getBytes(StandardCharsets.US_ASCII);
        byte[] qualities = new byte[L];
        Arrays.fill(qualities, (byte) 30);
        long[] positions = {180L};
        List<String> cigars = List.of("2M3D5M");
        List<String> chroms = List.of("chr1");
        WrittenGenomicRun run = buildGenomicRun(n, L, sequences, qualities,
            chroms, positions, cigars);
        String path = tempDir.resolve("m9013_del.tio").toString();
        SpectralDataset.create(path, "x", "x",
            List.of(), List.of(run), List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        String out = tempDir.resolve("m9013_del_out.tio").toString();
        Anonymizer.AnonymizationPolicy policy =
            new Anonymizer.AnonymizationPolicy(
                false, 0.0, false, 0.05, -1, -1, false,
                false, false, 30,
                List.of(new Anonymizer.MaskRegion("chr1", 185, 200)));
        Anonymizer.AnonymizationResult res;
        try (SpectralDataset ds = SpectralDataset.open(path)) {
            res = Anonymizer.anonymize(ds, out, policy);
        }
        try (SpectralDataset ds = SpectralDataset.open(out)) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            String zeros = new String(new byte[L], StandardCharsets.US_ASCII);
            assertEquals(zeros, gr.readAt(0).sequence(),
                "M90.13: 3D consumes 3 ref bases → end overlaps region");
        }
        assertEquals(1, res.readsInMaskedRegion());
    }

    @Test
    void m9013_emptyCigarFallsBackToPosOnly() {
        // pos=95 + empty CIGAR → no span info; pos-only check is
        // 100 <= 95 <= 200 → false → NOT masked.
        int n = 1, L = 8;
        byte[] sequences = "ACGTACGT".getBytes(StandardCharsets.US_ASCII);
        byte[] qualities = new byte[L];
        Arrays.fill(qualities, (byte) 30);
        WrittenGenomicRun run = buildGenomicRun(n, L, sequences, qualities,
            List.of("chr1"), new long[]{95L}, List.of(""));
        String path = tempDir.resolve("m9013_empty.tio").toString();
        SpectralDataset.create(path, "x", "x",
            List.of(), List.of(run), List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        String out = tempDir.resolve("m9013_empty_out.tio").toString();
        Anonymizer.AnonymizationPolicy policy =
            new Anonymizer.AnonymizationPolicy(
                false, 0.0, false, 0.05, -1, -1, false,
                false, false, 30,
                List.of(new Anonymizer.MaskRegion("chr1", 100, 200)));
        try (SpectralDataset ds = SpectralDataset.open(path)) {
            Anonymizer.anonymize(ds, out, policy);
        }
        try (SpectralDataset ds = SpectralDataset.open(out)) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertEquals("ACGTACGT", gr.readAt(0).sequence(),
                "empty CIGAR + pos=95 < region_start=100 → not masked");
        }
    }

    // ════════════════════════════════════════════════════════ M90.14 ═

    /** Genomic fixture with distinct per-read qualities so unintended
     *  carry-through is detectable. */
    private String makeM9014Fixture(String name) {
        int n = 4, L = 8;
        byte[] sequences = new byte[n * L];
        byte[] tile = "ACGTACGT".getBytes(StandardCharsets.US_ASCII);
        for (int i = 0; i < sequences.length; i++) {
            sequences[i] = tile[i % tile.length];
        }
        byte[] qualities = new byte[n * L];
        for (int i = 0; i < n; i++) {
            Arrays.fill(qualities, i * L, (i + 1) * L, (byte) (10 + i));
        }
        long[] positions = {100L, 200L, 300L, 400L};
        List<String> chroms = List.of("chr1", "chr1", "chr1", "chr1");
        List<String> cigars = List.of(L + "M", L + "M", L + "M", L + "M");
        WrittenGenomicRun run = buildGenomicRun(n, L, sequences, qualities,
            chroms, positions, cigars);
        String path = tempDir.resolve(name).toString();
        SpectralDataset.create(path, "M90.14 fixture", "ISA-M90-14",
            List.of(), List.of(run), List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        return path;
    }

    @Test
    void m9014_seedProducesReproducibleQualities() {
        String src = makeM9014Fixture("m9014_rep.tio");
        String outA = tempDir.resolve("m9014_a.tio").toString();
        String outB = tempDir.resolve("m9014_b.tio").toString();
        Anonymizer.AnonymizationPolicy policy =
            new Anonymizer.AnonymizationPolicy(
                false, 0.0, false, 0.05, -1, -1, false,
                false, true, 30, null, 42L);
        try (SpectralDataset ds = SpectralDataset.open(src)) {
            Anonymizer.anonymize(ds, outA, policy);
        }
        try (SpectralDataset ds = SpectralDataset.open(src)) {
            Anonymizer.anonymize(ds, outB, policy);
        }
        try (SpectralDataset dsA = SpectralDataset.open(outA);
             SpectralDataset dsB = SpectralDataset.open(outB)) {
            GenomicRun ga = dsA.genomicRuns().get("genomic_0001");
            GenomicRun gb = dsB.genomicRuns().get("genomic_0001");
            for (int i = 0; i < ga.readCount(); i++) {
                assertArrayEquals(ga.readAt(i).qualities(),
                                    gb.readAt(i).qualities(),
                    "read " + i + ": same seed must produce same qualities");
            }
        }
    }

    @Test
    void m9014_differentSeedsProduceDifferentQualities() {
        String src = makeM9014Fixture("m9014_diff.tio");
        String outA = tempDir.resolve("m9014_da.tio").toString();
        String outB = tempDir.resolve("m9014_db.tio").toString();
        Anonymizer.AnonymizationPolicy pa =
            new Anonymizer.AnonymizationPolicy(
                false, 0.0, false, 0.05, -1, -1, false,
                false, true, 30, null, 42L);
        Anonymizer.AnonymizationPolicy pb =
            new Anonymizer.AnonymizationPolicy(
                false, 0.0, false, 0.05, -1, -1, false,
                false, true, 30, null, 99L);
        try (SpectralDataset ds = SpectralDataset.open(src)) {
            Anonymizer.anonymize(ds, outA, pa);
        }
        try (SpectralDataset ds = SpectralDataset.open(src)) {
            Anonymizer.anonymize(ds, outB, pb);
        }
        try (SpectralDataset dsA = SpectralDataset.open(outA);
             SpectralDataset dsB = SpectralDataset.open(outB)) {
            GenomicRun ga = dsA.genomicRuns().get("genomic_0001");
            GenomicRun gb = dsB.genomicRuns().get("genomic_0001");
            boolean differs = false;
            for (int i = 0; i < ga.readCount(); i++) {
                if (!Arrays.equals(ga.readAt(i).qualities(),
                                     gb.readAt(i).qualities())) {
                    differs = true;
                    break;
                }
            }
            assertTrue(differs, "different seeds must produce different qualities");
        }
    }

    @Test
    void m9014_seededQualitiesAreInPhredRange() {
        String src = makeM9014Fixture("m9014_range.tio");
        String out = tempDir.resolve("m9014_range_out.tio").toString();
        Anonymizer.AnonymizationPolicy policy =
            new Anonymizer.AnonymizationPolicy(
                false, 0.0, false, 0.05, -1, -1, false,
                false, true, 30, null, 42L);
        try (SpectralDataset ds = SpectralDataset.open(src)) {
            Anonymizer.anonymize(ds, out, policy);
        }
        try (SpectralDataset ds = SpectralDataset.open(out)) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            for (int i = 0; i < gr.readCount(); i++) {
                for (byte b : gr.readAt(i).qualities()) {
                    int v = b & 0xFF;
                    assertTrue(v >= 0 && v <= 93,
                        "read " + i + " byte " + v + ": Phred must be 0-93");
                }
            }
        }
    }

    @Test
    void m9014_seedOverridesConstant() {
        String src = makeM9014Fixture("m9014_ov.tio");
        String out = tempDir.resolve("m9014_ov_out.tio").toString();
        Anonymizer.AnonymizationPolicy policy =
            new Anonymizer.AnonymizationPolicy(
                false, 0.0, false, 0.05, -1, -1, false,
                false, true, /* constant ignored */ 30, null,
                /* seed wins */ 7L);
        try (SpectralDataset ds = SpectralDataset.open(src)) {
            Anonymizer.anonymize(ds, out, policy);
        }
        try (SpectralDataset ds = SpectralDataset.open(out)) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            byte[] q0 = gr.readAt(0).qualities();
            byte[] all30 = new byte[q0.length];
            Arrays.fill(all30, (byte) 30);
            assertFalse(Arrays.equals(q0, all30),
                "seed must override the constant");
        }
    }

    @Test
    void m9014_noSeedUsesConstant() {
        String src = makeM9014Fixture("m9014_noseed.tio");
        String out = tempDir.resolve("m9014_ns_out.tio").toString();
        Anonymizer.AnonymizationPolicy policy =
            new Anonymizer.AnonymizationPolicy(
                false, 0.0, false, 0.05, -1, -1, false,
                false, true, 30, null);  // 11-arg → seed defaults to null
        try (SpectralDataset ds = SpectralDataset.open(src)) {
            Anonymizer.anonymize(ds, out, policy);
        }
        try (SpectralDataset ds = SpectralDataset.open(out)) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            for (int i = 0; i < gr.readCount(); i++) {
                for (byte b : gr.readAt(i).qualities()) {
                    assertEquals((byte) 30, b,
                        "read " + i + ": no seed → all bytes equal constant 30");
                }
            }
        }
    }

    // ════════════════════════════════════════════════════════ M90.15 ═

    @Test
    void m9015_signGenomicRunIncludesChromosomes() {
        String path = makeGenomicFixture("m9015_chr.tio");
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
        // L1 (Task #82 Phase B.1, 2026-05-01): chromosomes column
        // is decomposed into chromosome_ids + chromosome_names; both
        // are signed.
        assertTrue(sigs.containsKey("genomic_index/chromosome_ids"),
            "L1: chromosome_ids must be signed");
        assertTrue(sigs.containsKey("genomic_index/chromosome_names"),
            "L1: chromosome_names must be signed");
        assertTrue(sigs.get("genomic_index/chromosome_ids").startsWith("v2:"));
        assertTrue(sigs.get("genomic_index/chromosome_names").startsWith("v2:"));
    }

    @Test
    void m9015_verifyPassesOnCleanRun() {
        String path = makeGenomicFixture("m9015_clean.tio");
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
    void m9015_verifyDetectsTamperedChromosomes() {
        String path = makeGenomicFixture("m9015_tamper.tio");
        byte[] key = SignatureManager.testKey();
        try (StorageProvider sp = ProviderRegistry.open(path,
                StorageProvider.Mode.READ_WRITE);
             StorageGroup root = sp.rootGroup();
             StorageGroup study = root.openGroup("study");
             StorageGroup gRuns = study.openGroup("genomic_runs");
             StorageGroup run = gRuns.openGroup("genomic_0001")) {
            SignatureManager.signGenomicRun(run, key);
            // L1: tamper with chromosome_ids — flip read 0's id
            // from 0 to 1 (changes canonical bytes; verify must fail).
            try (StorageGroup idx = run.openGroup("genomic_index")) {
                short[] ids;
                try (StorageDataset ds = idx.openDataset("chromosome_ids")) {
                    ids = (short[]) ds.readAll();
                }
                ids[0] = (short) ((ids[0] + 1) & 0xFFFF);
                idx.deleteChild("chromosome_ids");
                try (StorageDataset ds = idx.createDataset(
                        "chromosome_ids", Enums.Precision.UINT16, ids.length,
                        0, Enums.Compression.NONE, 0)) {
                    ds.writeAll(ids);
                }
            }
            assertFalse(SignatureManager.verifyGenomicRun(run, key),
                "M90.15: tampered chromosomes compound must verify=false");
        }
    }
}
