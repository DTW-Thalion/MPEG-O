/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.exporters;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.ProvenanceRecord;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.importers.BamReader;
import global.thalion.ttio.importers.CramReader;

import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

/**
 * M88 CRAM importer + BAM/CRAM exporter acceptance tests — Java
 * parity with Python's {@code test_m88_cram_bam_round_trip.py}.
 *
 * <p>Each test is gated by
 * {@link org.junit.jupiter.api.Assumptions#assumeTrue} on
 * {@link BamReader#isSamtoolsAvailable()} so the suite stays green
 * on CI runners without samtools (HANDOFF Gotcha §158).</p>
 */
public class CramBamRoundTripTest {

    private static final Path FIXTURE_DIR =
        Paths.get("src", "test", "resources", "ttio", "fixtures", "genomic");
    private static final Path SAM_PATH = FIXTURE_DIR.resolve("m88_test.sam");
    private static final Path BAM_PATH = FIXTURE_DIR.resolve("m88_test.bam");
    private static final Path CRAM_PATH = FIXTURE_DIR.resolve("m88_test.cram");
    private static final Path REFERENCE_PATH =
        FIXTURE_DIR.resolve("m88_test_reference.fa");

    private static final List<String> EXPECTED_READ_NAMES = List.of(
        "m88r001", "m88r002", "m88r003", "m88r004", "m88r005");
    private static final long[] EXPECTED_POSITIONS = {101, 201, 301, 401, 201};
    private static final List<String> EXPECTED_CHROMOSOMES = List.of(
        "chr1", "chr1", "chr1", "chr1", "chr2");
    private static final int[] EXPECTED_FLAGS = {0, 0, 0, 0, 0};
    private static final int[] EXPECTED_MAPQ = {60, 60, 60, 60, 60};
    private static final List<String> EXPECTED_CIGARS = List.of(
        "100M", "100M", "100M", "100M", "100M");

    @BeforeAll
    static void verifyFixturesExist() {
        assumeTrue(Files.isRegularFile(BAM_PATH),
            "fixture missing: " + BAM_PATH.toAbsolutePath());
        assumeTrue(Files.isRegularFile(CRAM_PATH),
            "fixture missing: " + CRAM_PATH.toAbsolutePath());
        assumeTrue(Files.isRegularFile(REFERENCE_PATH),
            "fixture missing: " + REFERENCE_PATH.toAbsolutePath());
    }

    /**
     * Build a small synthetic {@link WrittenGenomicRun} for writer
     * tests. Topology dead-simple: 3 reads on chr1 against the M88
     * synthetic reference.
     */
    private static WrittenGenomicRun buildSyntheticRun(boolean mateChromSame,
                                                       boolean matePosNegOne) {
        // 100-base "ACGT"x25 sequence, "I"-quality (Phred 73 ASCII).
        byte[] oneSeq = new byte[100];
        byte[] oneQual = new byte[100];
        byte[] acgt = "ACGT".getBytes(StandardCharsets.US_ASCII);
        for (int i = 0; i < 100; i++) {
            oneSeq[i] = acgt[i % 4];
            oneQual[i] = (byte) 'I';
        }
        byte[] sequences = new byte[300];
        byte[] qualities = new byte[300];
        for (int i = 0; i < 3; i++) {
            System.arraycopy(oneSeq, 0, sequences, i * 100, 100);
            System.arraycopy(oneQual, 0, qualities, i * 100, 100);
        }
        long[] offsets = {0L, 100L, 200L};
        int[] lengths = {100, 100, 100};

        List<String> mateChroms = mateChromSame
            ? List.of("chr1", "chr1", "chr1")
            : List.of("*", "*", "*");
        long[] matePositions = matePosNegOne
            ? new long[]{-1L, -1L, -1L}
            : new long[]{0L, 0L, 0L};

        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS,
            "chr1",
            "ILLUMINA",
            "M88_SYNTH",
            new long[]{101L, 201L, 301L},
            new byte[]{60, 60, 60},
            new int[]{0, 0, 0},
            sequences,
            qualities,
            offsets,
            lengths,
            List.of("100M", "100M", "100M"),
            List.of("s001", "s002", "s003"),
            mateChroms,
            matePositions,
            new int[]{0, 0, 0},
            List.of("chr1", "chr1", "chr1"),
            Compression.ZLIB
        );
    }

    private static WrittenGenomicRun buildSyntheticRun() {
        return buildSyntheticRun(false, false);
    }

    private static <V> Map<String, V> indexBy(List<String> keys, List<V> values) {
        Map<String, V> m = new HashMap<>();
        for (int i = 0; i < keys.size(); i++) m.put(keys.get(i), values.get(i));
        return m;
    }

    private static Map<String, Long> indexByLong(List<String> keys, long[] values) {
        Map<String, Long> m = new HashMap<>();
        for (int i = 0; i < keys.size(); i++) m.put(keys.get(i), values[i]);
        return m;
    }

    private static Map<String, Integer> indexByInt(List<String> keys, int[] values) {
        Map<String, Integer> m = new HashMap<>();
        for (int i = 0; i < keys.size(); i++) m.put(keys.get(i), values[i]);
        return m;
    }

    private static Map<String, Integer> indexByByte(List<String> keys, byte[] values) {
        Map<String, Integer> m = new HashMap<>();
        for (int i = 0; i < keys.size(); i++) m.put(keys.get(i), values[i] & 0xFF);
        return m;
    }

    // ------------------------------------------------------------------
    // 1: CRAM read full
    // ------------------------------------------------------------------
    @Test
    void test01_cramReadFull() throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable());
        WrittenGenomicRun run = new CramReader(CRAM_PATH, REFERENCE_PATH)
            .toGenomicRun("genomic_0001");
        assertEquals(5, run.readNames().size());
        assertEquals(EXPECTED_READ_NAMES, run.readNames());
        assertArrayEquals(EXPECTED_POSITIONS, run.positions());
        assertEquals(EXPECTED_CHROMOSOMES, run.chromosomes());
        assertArrayEquals(EXPECTED_FLAGS, run.flags());
        byte[] mapq = run.mappingQualities();
        int[] mapqInts = new int[mapq.length];
        for (int i = 0; i < mapq.length; i++) mapqInts[i] = mapq[i] & 0xFF;
        assertArrayEquals(EXPECTED_MAPQ, mapqInts);
        assertEquals(EXPECTED_CIGARS, run.cigars());
        assertEquals("M88_TEST_SAMPLE", run.sampleName());
        assertEquals("ILLUMINA", run.platform());
    }

    // ------------------------------------------------------------------
    // 2: CRAM region filter
    // ------------------------------------------------------------------
    @Test
    void test02_cramReadRegion() throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable());
        WrittenGenomicRun run = new CramReader(CRAM_PATH, REFERENCE_PATH)
            .toGenomicRun("genomic_0001", "chr1:100-500");
        assertEquals(List.of("m88r001", "m88r002", "m88r003", "m88r004"),
            run.readNames());
        for (String c : run.chromosomes()) assertEquals("chr1", c);
    }

    // ------------------------------------------------------------------
    // 3: BAM write basic round-trip
    // ------------------------------------------------------------------
    @Test
    void test03_bamWriteBasic(@TempDir Path tmp) throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable());
        WrittenGenomicRun src = new BamReader(BAM_PATH).toGenomicRun("g0");
        Path out = tmp.resolve("round_trip.bam");
        new BamWriter(out).write(src, List.of(), true);

        WrittenGenomicRun back = new BamReader(out).toGenomicRun("g0");
        List<String> srcSorted = new ArrayList<>(src.readNames());
        List<String> backSorted = new ArrayList<>(back.readNames());
        java.util.Collections.sort(srcSorted);
        java.util.Collections.sort(backSorted);
        assertEquals(srcSorted, backSorted);
        assertEquals(src.readNames().size(), back.readNames().size());

        Map<String, Long> srcPos = indexByLong(src.readNames(), src.positions());
        Map<String, Long> backPos = indexByLong(back.readNames(), back.positions());
        for (String name : src.readNames()) {
            assertEquals(srcPos.get(name), backPos.get(name), name);
        }
    }

    // ------------------------------------------------------------------
    // 4: BAM write unsorted preserves input order
    // ------------------------------------------------------------------
    @Test
    void test04_bamWriteUnsorted(@TempDir Path tmp) throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable());
        WrittenGenomicRun src = buildSyntheticRun();
        Path out = tmp.resolve("unsorted.bam");
        new BamWriter(out).write(src, List.of(), false);

        WrittenGenomicRun back = new BamReader(out).toGenomicRun("g0");
        assertEquals(src.readNames(), back.readNames());
    }

    // ------------------------------------------------------------------
    // 5: BAM write with explicit provenance
    // ------------------------------------------------------------------
    @Test
    void test05_bamWriteWithProvenance(@TempDir Path tmp) throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable());
        WrittenGenomicRun src = buildSyntheticRun();
        Map<String, String> params = new HashMap<>();
        params.put("CL", "my_tool --opt foo input.fq");
        ProvenanceRecord pr = new ProvenanceRecord(
            0L, "my_tool", params, List.of(), List.of());
        Path out = tmp.resolve("with_prov.bam");
        new BamWriter(out).write(src, List.of(pr), true);

        BamReader reader = new BamReader(out);
        reader.toGenomicRun("g0");
        List<ProvenanceRecord> prov = reader.lastProvenance();
        boolean foundMyTool = false;
        for (ProvenanceRecord p : prov) {
            if ("my_tool".equals(p.software())) {
                foundMyTool = true;
                String cl = p.parameters().getOrDefault("CL", "");
                assertTrue(cl.contains("my_tool --opt foo input.fq"),
                    "CL contains command line, got: " + cl);
            }
        }
        assertTrue(foundMyTool, "@PG entry for my_tool present");
    }

    // ------------------------------------------------------------------
    // 6: CRAM write basic round-trip
    // ------------------------------------------------------------------
    @Test
    void test06_cramWriteBasic(@TempDir Path tmp) throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable());
        WrittenGenomicRun src = buildSyntheticRun();
        Path out = tmp.resolve("round_trip.cram");
        new CramWriter(out, REFERENCE_PATH).write(src, List.of(), true);

        WrittenGenomicRun back = new CramReader(out, REFERENCE_PATH)
            .toGenomicRun("g0");
        List<String> srcSorted = new ArrayList<>(src.readNames());
        List<String> backSorted = new ArrayList<>(back.readNames());
        java.util.Collections.sort(srcSorted);
        java.util.Collections.sort(backSorted);
        assertEquals(srcSorted, backSorted);
        assertEquals(src.readNames().size(), back.readNames().size());

        // All reads have the same sequence/quality buffer here (3
        // identical 100-base "ACGT"x25 reads), so total bytes should
        // match exactly even after coordinate-sort permutation.
        assertArrayEquals(src.sequences(), back.sequences());
        assertArrayEquals(src.qualities(), back.qualities());
    }

    // ------------------------------------------------------------------
    // 7: CRAM write requires reference to read back
    // ------------------------------------------------------------------
    @Test
    void test07_cramWriteWithReference(@TempDir Path tmp) throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable());
        WrittenGenomicRun src = buildSyntheticRun();
        Path refDir = tmp.resolve("refs");
        Files.createDirectories(refDir);
        Path refCopy = refDir.resolve("ref.fa");
        Files.copy(REFERENCE_PATH, refCopy, StandardCopyOption.REPLACE_EXISTING);

        Path out = tmp.resolve("needs_ref.cram");
        new CramWriter(out, refCopy).write(src, List.of(), true);

        // Yank the reference out from under samtools.
        Files.deleteIfExists(refCopy);
        Path fai = refCopy.resolveSibling("ref.fa.fai");
        Files.deleteIfExists(fai);

        // Try to read CRAM without --reference; samtools should fail.
        // Disable EBI MD5 fallback so the test is deterministic on a
        // network-connected runner.
        ProcessBuilder pb = new ProcessBuilder(
            "samtools", "view", "-h", out.toAbsolutePath().toString());
        pb.environment().put("REF_PATH", ":");
        pb.environment().put("REF_CACHE", ":");
        pb.redirectErrorStream(false);
        Process proc = pb.start();
        proc.getInputStream().readAllBytes();
        byte[] errBytes = proc.getErrorStream().readAllBytes();
        int exit;
        try {
            exit = proc.waitFor();
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
            throw new IOException("interrupted", ie);
        }
        assertNotEquals(0, exit,
            "samtools should have failed to read CRAM without reference; stderr="
            + new String(errBytes, StandardCharsets.UTF_8));
    }

    // ------------------------------------------------------------------
    // 8: BAM -> GenomicRun -> BAM round trip
    // ------------------------------------------------------------------
    @Test
    void test08_roundTripBamToBam(@TempDir Path tmp) throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable());
        WrittenGenomicRun src = new BamReader(BAM_PATH).toGenomicRun("g0");
        Path out = tmp.resolve("rt.bam");
        new BamWriter(out).write(src, List.of(), true);

        WrittenGenomicRun back = new BamReader(out).toGenomicRun("g0");
        assertEquals(src.readNames().size(), back.readNames().size());
        List<String> srcSorted = new ArrayList<>(src.readNames());
        List<String> backSorted = new ArrayList<>(back.readNames());
        java.util.Collections.sort(srcSorted);
        java.util.Collections.sort(backSorted);
        assertEquals(srcSorted, backSorted);

        Map<String, Long> srcPos  = indexByLong(src.readNames(), src.positions());
        Map<String, Long> backPos = indexByLong(back.readNames(), back.positions());
        Map<String, Integer> srcFlags  = indexByInt(src.readNames(), src.flags());
        Map<String, Integer> backFlags = indexByInt(back.readNames(), back.flags());
        Map<String, Integer> srcMapq   = indexByByte(src.readNames(), src.mappingQualities());
        Map<String, Integer> backMapq  = indexByByte(back.readNames(), back.mappingQualities());
        Map<String, Long> srcMatePos   = indexByLong(src.readNames(), src.matePositions());
        Map<String, Long> backMatePos  = indexByLong(back.readNames(), back.matePositions());
        Map<String, Integer> srcTLen   = indexByInt(src.readNames(), src.templateLengths());
        Map<String, Integer> backTLen  = indexByInt(back.readNames(), back.templateLengths());
        Map<String, String> srcCig     = indexBy(src.readNames(), src.cigars());
        Map<String, String> backCig    = indexBy(back.readNames(), back.cigars());
        Map<String, String> srcChrom   = indexBy(src.readNames(), src.chromosomes());
        Map<String, String> backChrom  = indexBy(back.readNames(), back.chromosomes());
        Map<String, String> srcMate    = indexBy(src.readNames(), src.mateChromosomes());
        Map<String, String> backMate   = indexBy(back.readNames(), back.mateChromosomes());
        for (String name : src.readNames()) {
            assertEquals(srcPos.get(name),     backPos.get(name),     "pos " + name);
            assertEquals(srcFlags.get(name),   backFlags.get(name),   "flag " + name);
            assertEquals(srcMapq.get(name),    backMapq.get(name),    "mapq " + name);
            assertEquals(srcMatePos.get(name), backMatePos.get(name), "matepos " + name);
            assertEquals(srcTLen.get(name),    backTLen.get(name),    "tlen " + name);
            assertEquals(srcCig.get(name),     backCig.get(name),     "cigar " + name);
            assertEquals(srcChrom.get(name),   backChrom.get(name),   "chrom " + name);
            assertEquals(srcMate.get(name),    backMate.get(name),    "mateChrom " + name);
        }
    }

    // ------------------------------------------------------------------
    // 9: CRAM -> GenomicRun -> CRAM round trip
    // ------------------------------------------------------------------
    @Test
    void test09_roundTripCramToCram(@TempDir Path tmp) throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable());
        WrittenGenomicRun src = new CramReader(CRAM_PATH, REFERENCE_PATH)
            .toGenomicRun("g0");
        Path out = tmp.resolve("rt.cram");
        new CramWriter(out, REFERENCE_PATH).write(src, List.of(), true);

        WrittenGenomicRun back = new CramReader(out, REFERENCE_PATH)
            .toGenomicRun("g0");
        List<String> srcSorted = new ArrayList<>(src.readNames());
        List<String> backSorted = new ArrayList<>(back.readNames());
        java.util.Collections.sort(srcSorted);
        java.util.Collections.sort(backSorted);
        assertEquals(srcSorted, backSorted);
        assertEquals(src.readNames().size(), back.readNames().size());
    }

    // ------------------------------------------------------------------
    // 10: cross-format BAM <-> CRAM round trip
    // ------------------------------------------------------------------
    @Test
    void test10_roundTripCrossFormat(@TempDir Path tmp) throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable());
        WrittenGenomicRun src = new BamReader(BAM_PATH).toGenomicRun("g0");
        Path cramOut = tmp.resolve("from_bam.cram");
        new CramWriter(cramOut, REFERENCE_PATH).write(src, List.of(), true);

        WrittenGenomicRun viaCram = new CramReader(cramOut, REFERENCE_PATH)
            .toGenomicRun("g0");
        Path bamOut = tmp.resolve("back_to.bam");
        new BamWriter(bamOut).write(viaCram, List.of(), true);
        WrittenGenomicRun finalRun = new BamReader(bamOut).toGenomicRun("g0");

        List<String> srcSorted = new ArrayList<>(src.readNames());
        List<String> finalSorted = new ArrayList<>(finalRun.readNames());
        java.util.Collections.sort(srcSorted);
        java.util.Collections.sort(finalSorted);
        assertEquals(srcSorted, finalSorted);
        assertEquals(src.readNames().size(), finalRun.readNames().size());
    }

    // ------------------------------------------------------------------
    // 11: mate-chromosome collapse to '=' on write
    // ------------------------------------------------------------------
    @Test
    void test11_mateCollapseToEquals(@TempDir Path tmp) {
        // Pure SAM-text inspection; doesn't actually invoke samtools
        // beyond the BamWriter constructor's lazy probe (which we
        // skip via assumeTrue to keep the test green when samtools is
        // missing — buildSamText itself doesn't shell out).
        assumeTrue(BamReader.isSamtoolsAvailable());
        WrittenGenomicRun src = buildSyntheticRun(true, false);
        BamWriter writer = new BamWriter(tmp.resolve("unused.bam"));
        String samText = writer.buildSamText(src, List.of(), false);

        List<String> alignments = new ArrayList<>();
        for (String line : samText.split("\n")) {
            if (line.isEmpty() || line.startsWith("@")) continue;
            alignments.add(line);
        }
        assertFalse(alignments.isEmpty(), "at least one alignment line emitted");
        for (String line : alignments) {
            String[] cols = line.split("\t");
            // Column 7 (0-indexed: 6) is RNEXT.
            assertEquals("=", cols[6],
                "Expected RNEXT='=' (collapse), got '" + cols[6] + "' in " + line);
        }
    }

    // ------------------------------------------------------------------
    // 12: mate position -1 mapped to 0 on write
    // ------------------------------------------------------------------
    @Test
    void test12_matePositionNegativeOneToZero(@TempDir Path tmp) throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable());
        WrittenGenomicRun src = buildSyntheticRun(false, true);
        Path out = tmp.resolve("pneg1.bam");
        new BamWriter(out).write(src, List.of(), false);

        ProcessBuilder pb = new ProcessBuilder(
            "samtools", "view", out.toAbsolutePath().toString());
        pb.redirectErrorStream(false);
        Process proc = pb.start();
        byte[] outBytes = proc.getInputStream().readAllBytes();
        proc.getErrorStream().readAllBytes();
        int exit;
        try {
            exit = proc.waitFor();
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
            throw new IOException("interrupted", ie);
        }
        assertEquals(0, exit, "samtools view succeeds");
        String stdout = new String(outBytes, StandardCharsets.UTF_8);
        for (String line : stdout.split("\n")) {
            if (line.isEmpty()) continue;
            String[] cols = line.split("\t");
            // Column 8 (0-indexed: 7) is PNEXT.
            assertEquals("0", cols[7],
                "Expected PNEXT='0' (from -1 mapping), got '" + cols[7] + "'");
        }
    }

    // ------------------------------------------------------------------
    // 13: CramReader requires a reference path at construction
    // ------------------------------------------------------------------
    @Test
    void test13_cramReaderMissingReference() {
        // Java's type system enforces this at compile time — the
        // single-arg constructor inherited from BamReader doesn't
        // accept a Path-only call into CramReader, so we exercise
        // the runtime null-rejection of the two-arg ctor.
        assertThrows(NullPointerException.class,
            () -> new CramReader(CRAM_PATH, null));
    }

    // ------------------------------------------------------------------
    // 14: writer output is valid SAM that samtools can re-parse
    // ------------------------------------------------------------------
    @Test
    void test14_writerProducesValidSam(@TempDir Path tmp) throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable());
        WrittenGenomicRun src = new BamReader(BAM_PATH).toGenomicRun("g0");
        Path out = tmp.resolve("valid.bam");
        new BamWriter(out).write(src, List.of(), true);

        ProcessBuilder pb = new ProcessBuilder(
            "samtools", "view", "-h", out.toAbsolutePath().toString());
        pb.redirectErrorStream(false);
        Process proc = pb.start();
        byte[] outBytes = proc.getInputStream().readAllBytes();
        proc.getErrorStream().readAllBytes();
        int exit;
        try {
            exit = proc.waitFor();
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
            throw new IOException("interrupted", ie);
        }
        assertEquals(0, exit, "samtools view -h succeeds on writer output");

        String[] lines = new String(outBytes, StandardCharsets.UTF_8).split("\n");
        List<String> headerLines = new ArrayList<>();
        List<String> alignLines = new ArrayList<>();
        for (String line : lines) {
            if (line.isEmpty()) continue;
            if (line.startsWith("@")) headerLines.add(line);
            else alignLines.add(line);
        }
        assertTrue(headerLines.stream().anyMatch(l -> l.startsWith("@HD")),
            "@HD line present");
        assertTrue(headerLines.stream().anyMatch(l -> l.startsWith("@SQ")),
            "@SQ line present");
        assertEquals(src.readNames().size(), alignLines.size(),
            "alignment line count matches source read count");
        for (String line : alignLines) {
            assertTrue(line.split("\t").length >= 11,
                "at least 11 tab-separated columns: " + line);
        }
    }
}
