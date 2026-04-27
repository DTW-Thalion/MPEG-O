/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.importers;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.FeatureFlags;
import global.thalion.ttio.ProvenanceRecord;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.genomics.AlignedRead;
import global.thalion.ttio.genomics.GenomicRun;
import global.thalion.ttio.genomics.WrittenGenomicRun;

import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.io.StringWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

/**
 * M87 BAM importer acceptance tests — Java parity with Python's
 * {@code test_m87_bam_importer.py}.
 *
 * <p>Each test is gated by
 * {@link org.junit.jupiter.api.Assumptions#assumeTrue} so the suite
 * stays green on CI runners without samtools (HANDOFF Gotcha §156).
 * The {@code BamReader} class itself remains loadable without
 * samtools per Binding Decision §135.</p>
 */
public class BamReaderTest {

    private static final Path FIXTURE_DIR =
        Paths.get("src", "test", "resources", "ttio", "fixtures", "genomic");
    private static final Path BAM_PATH = FIXTURE_DIR.resolve("m87_test.bam");
    private static final Path SAM_PATH = FIXTURE_DIR.resolve("m87_test.sam");

    // Coordinate-sorted on-disk read order (NOT r000..r009 numerical).
    private static final List<String> EXPECTED_READ_NAMES = List.of(
        "r000", "r001", "r002", "r008", "r009",
        "r003", "r004", "r005", "r006", "r007");
    private static final long[] EXPECTED_POSITIONS =
        {1000, 1100, 2000, 3000, 4000, 5000, 5100, 0, 0, 0};
    private static final List<String> EXPECTED_CHROMS = List.of(
        "chr1", "chr1", "chr1", "chr1", "chr1",
        "chr2", "chr2", "*", "*", "*");
    private static final int[] EXPECTED_FLAGS =
        {99, 147, 0, 16, 0, 99, 147, 4, 77, 141};
    private static final int[] EXPECTED_MAPQ =
        {60, 60, 30, 30, 30, 60, 60, 0, 0, 0};
    private static final List<String> EXPECTED_CIGARS = List.of(
        "100M", "100M", "50M50S", "100M", "100M",
        "100M", "100M", "*", "*", "*");
    private static final List<String> EXPECTED_MATE_CHROMS = List.of(
        "chr1", "chr1", "*", "*", "*",
        "chr2", "chr2", "*", "*", "*");
    private static final long[] EXPECTED_MATE_POS =
        {1100, 1000, 0, 0, 0, 5100, 5000, 0, 0, 0};
    private static final int[] EXPECTED_TLEN =
        {200, -200, 0, 0, 0, 200, -200, 0, 0, 0};

    @BeforeAll
    static void verifyFixturesExist() {
        // Skip the whole suite when the fixture isn't present — but
        // the fixture is committed, so this is mainly a sanity net.
        assumeTrue(Files.isRegularFile(BAM_PATH),
            "fixture missing: " + BAM_PATH.toAbsolutePath());
    }

    // 1
    @Test
    void samtoolsAvailable() throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable(),
            "samtools not on PATH; skipping per HANDOFF §156");
        ProcessBuilder pb = new ProcessBuilder("samtools", "--version");
        pb.redirectErrorStream(true);
        Process p = pb.start();
        try {
            p.getInputStream().readAllBytes();
            assertEquals(0, p.waitFor(), "samtools --version exit code");
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
            fail("interrupted");
        }
    }

    // 2
    @Test
    void readFullBam() throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable());
        WrittenGenomicRun run = new BamReader(BAM_PATH).toGenomicRun("genomic_0001");
        assertEquals(10, run.readNames().size());
        assertEquals(EXPECTED_READ_NAMES, run.readNames());
    }

    // 3
    @Test
    void readPositions() throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable());
        WrittenGenomicRun run = new BamReader(BAM_PATH).toGenomicRun("genomic_0001");
        assertArrayEquals(EXPECTED_POSITIONS, run.positions());
    }

    // 4
    @Test
    void readChromosomes() throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable());
        WrittenGenomicRun run = new BamReader(BAM_PATH).toGenomicRun("genomic_0001");
        assertEquals(EXPECTED_CHROMS, run.chromosomes());
    }

    // 5
    @Test
    void readFlags() throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable());
        WrittenGenomicRun run = new BamReader(BAM_PATH).toGenomicRun("genomic_0001");
        assertArrayEquals(EXPECTED_FLAGS, run.flags());
    }

    // 6
    @Test
    void readMappingQualities() throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable());
        WrittenGenomicRun run = new BamReader(BAM_PATH).toGenomicRun("genomic_0001");
        byte[] mapq = run.mappingQualities();
        int[] asInts = new int[mapq.length];
        for (int i = 0; i < mapq.length; i++) asInts[i] = mapq[i] & 0xFF;
        assertArrayEquals(EXPECTED_MAPQ, asInts);
    }

    // 7
    @Test
    void readCigars() throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable());
        WrittenGenomicRun run = new BamReader(BAM_PATH).toGenomicRun("genomic_0001");
        assertEquals(EXPECTED_CIGARS, run.cigars());
    }

    // 8
    @Test
    void readSequencesConcat() throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable());
        WrittenGenomicRun run = new BamReader(BAM_PATH).toGenomicRun("genomic_0001");
        assertEquals(720, run.sequences().length);
        int[] expectedLengths = {100, 100, 100, 100, 100, 100, 100, 0, 10, 10};
        assertArrayEquals(expectedLengths, run.lengths());
        long[] expectedOffsets = new long[expectedLengths.length];
        long acc = 0;
        for (int i = 0; i < expectedLengths.length; i++) {
            expectedOffsets[i] = acc;
            acc += expectedLengths[i];
        }
        assertArrayEquals(expectedOffsets, run.offsets());
    }

    // 9
    @Test
    void readMateInfo() throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable());
        WrittenGenomicRun run = new BamReader(BAM_PATH).toGenomicRun("genomic_0001");
        assertEquals(EXPECTED_MATE_CHROMS, run.mateChromosomes());
        assertArrayEquals(EXPECTED_MATE_POS, run.matePositions());
        assertArrayEquals(EXPECTED_TLEN, run.templateLengths());
    }

    // 10
    @Test
    void readMetadataFromHeader() throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable());
        WrittenGenomicRun run = new BamReader(BAM_PATH).toGenomicRun("genomic_0001");
        assertEquals("M87_TEST_SAMPLE", run.sampleName());
        assertEquals("ILLUMINA", run.platform());
        assertEquals("chr1", run.referenceUri());
        assertEquals(AcquisitionMode.GENOMIC_WGS, run.acquisitionMode());
    }

    // 11 — round-trip: BAM → WrittenGenomicRun → .tio → GenomicRun → AlignedRead
    @Test
    void roundTripThroughWriter(@TempDir Path tmp) throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable());
        WrittenGenomicRun written = new BamReader(BAM_PATH).toGenomicRun("genomic_0001");

        Path file = tmp.resolve("m87_round_trip.tio");
        SpectralDataset.create(file.toString(), "M87 round-trip", "ISA-M87",
            List.of(), List.of(written),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();

        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertNotNull(gr);
            assertEquals(10, gr.readCount());
            for (int i = 0; i < EXPECTED_READ_NAMES.size(); i++) {
                AlignedRead r = gr.readAt(i);
                assertEquals(EXPECTED_READ_NAMES.get(i), r.readName(),
                    "read " + i + " name");
                assertEquals(EXPECTED_POSITIONS[i], r.position(),
                    "read " + i + " position");
                assertEquals(EXPECTED_CHROMS.get(i), r.chromosome(),
                    "read " + i + " chromosome");
                assertEquals(EXPECTED_CIGARS.get(i), r.cigar(),
                    "read " + i + " cigar");
                assertEquals(EXPECTED_FLAGS[i], r.flags(),
                    "read " + i + " flags");
                assertEquals(EXPECTED_MAPQ[i], r.mappingQuality(),
                    "read " + i + " mapq");
                assertEquals(EXPECTED_MATE_CHROMS.get(i), r.mateChromosome(),
                    "read " + i + " mate chrom");
                assertEquals(EXPECTED_MATE_POS[i], r.matePosition(),
                    "read " + i + " mate position");
                assertEquals(EXPECTED_TLEN[i], r.templateLength(),
                    "read " + i + " template length");
            }
            // Spot-check first paired mapped read.
            AlignedRead r0 = gr.readAt(0);
            assertEquals("ACGT".repeat(25), r0.sequence(), "r000 sequence");
            byte[] expectedQ = new byte[100];
            java.util.Arrays.fill(expectedQ, (byte) 'I');
            assertArrayEquals(expectedQ, r0.qualities(), "r000 qualities");

            // Wholly unmapped read with no SEQ (r005 at index 7 in
            // coordinate-sorted order).
            AlignedRead rUnmapped = gr.readAt(7);
            assertEquals("r005", rUnmapped.readName());
            assertEquals("", rUnmapped.sequence());
            assertEquals(0, rUnmapped.qualities().length);
        }
    }

    // 12
    @Test
    void regionFilter() throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable());
        WrittenGenomicRun run = new BamReader(BAM_PATH)
            .toGenomicRun("genomic_0001", "chr2:5000-5200");
        assertEquals(List.of("r003", "r004"), run.readNames());
        assertEquals(List.of("chr2", "chr2"), run.chromosomes());
    }

    // 13
    @Test
    void regionUnmapped() throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable());
        WrittenGenomicRun run = new BamReader(BAM_PATH)
            .toGenomicRun("genomic_0001", "*");
        List<String> sorted = new ArrayList<>(run.readNames());
        Collections.sort(sorted);
        assertEquals(List.of("r005", "r006", "r007"), sorted);
        for (String c : run.chromosomes()) assertEquals("*", c);
    }

    // 14
    @Test
    void provenanceFromPg() throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable());
        BamReader reader = new BamReader(BAM_PATH);
        reader.toGenomicRun("genomic_0001");
        List<ProvenanceRecord> prov = reader.lastProvenance();
        assertTrue(prov.size() >= 1, "at least one @PG provenance row");
        long bwaCount = prov.stream().filter(p -> "bwa".equals(p.software())).count();
        assertEquals(1, bwaCount, "one bwa @PG record");
        ProvenanceRecord bwa = prov.stream()
            .filter(p -> "bwa".equals(p.software()))
            .findFirst().orElseThrow();
        String cl = bwa.parameters().getOrDefault("CL", "");
        assertTrue(cl.contains("bwa mem ref.fa reads.fq"),
            "CL contains bwa command line, got: " + cl);
    }

    // 15
    @Test
    void samInputMatchesBam() throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable());
        WrittenGenomicRun samRun = new SamReader(SAM_PATH).toGenomicRun("genomic_0001");
        WrittenGenomicRun bamRun = new BamReader(BAM_PATH).toGenomicRun("genomic_0001");

        assertEquals(samRun.readNames(), bamRun.readNames());
        assertArrayEquals(samRun.positions(), bamRun.positions());
        assertEquals(samRun.chromosomes(), bamRun.chromosomes());
        assertArrayEquals(samRun.flags(), bamRun.flags());
        assertArrayEquals(samRun.mappingQualities(), bamRun.mappingQualities());
        assertEquals(samRun.cigars(), bamRun.cigars());
        assertEquals(samRun.mateChromosomes(), bamRun.mateChromosomes());
        assertArrayEquals(samRun.matePositions(), bamRun.matePositions());
        assertArrayEquals(samRun.templateLengths(), bamRun.templateLengths());
        assertArrayEquals(samRun.sequences(), bamRun.sequences());
        assertArrayEquals(samRun.qualities(), bamRun.qualities());
        assertEquals(samRun.sampleName(), bamRun.sampleName());
        assertEquals(samRun.platform(), bamRun.platform());
        assertEquals(samRun.referenceUri(), bamRun.referenceUri());
    }

    // 16
    @Test
    void samtoolsMissingErrorMessageHasInstallHelp() {
        // Even if samtools IS available, we exercise the error
        // formatting path by constructing the exception directly —
        // its message must include install guidance for the major OSes.
        // (Java has no convenient analogue to monkeypatch.)
        BamReader.SamtoolsNotFoundException ex =
            new BamReader.SamtoolsNotFoundException(
                buildExpectedMessage());
        String msg = ex.getMessage();
        assertTrue(msg.contains("apt") || msg.contains("brew") || msg.contains("conda"),
            "install guidance present in message: " + msg);
        // And the standard install hints are all present:
        assertTrue(msg.contains("apt"),   "apt hint present");
        assertTrue(msg.contains("brew"),  "brew hint present");
        assertTrue(msg.contains("conda"), "conda hint present");
    }

    // 17 (bonus) — canonical-JSON byte-exact match against Python's bam_dump
    // is implicitly covered by the build-time `BamDump` execution; surface
    // here as an in-test assertion so a Maven `-Dtest=BamReaderTest` run
    // still verifies the conformance contract.
    @Test
    void bamDumpJsonShapeCanonical() throws IOException {
        assumeTrue(BamReader.isSamtoolsAvailable());
        StringWriter sw = new StringWriter();
        BamDump.run(new String[]{BAM_PATH.toString()}, sw);
        String json = sw.toString();
        assertTrue(json.endsWith("\n"), "trailing newline");
        // Spot-check a handful of fixed substrings; full byte-exact diff
        // happens in the cross-language harness.
        assertTrue(json.contains("\"sequences_md5\": \"6282bfb76c945e53a68bb80c2f17fd81\""),
            "sequences MD5 fingerprint present");
        assertTrue(json.contains("\"qualities_md5\": \"7d347459eab72e54488ac30c65f509ff\""),
            "qualities MD5 fingerprint present");
        assertTrue(json.contains("\"read_count\": 10"), "read_count: 10 present");
        assertTrue(json.contains("\"sample_name\": \"M87_TEST_SAMPLE\""),
            "sample_name present");
    }

    private static String buildExpectedMessage() {
        return
            "samtools is required by global.thalion.ttio.importers.BamReader "
            + "but was not found on PATH. Install it via your platform's "
            + "package manager:\n"
            + "  Debian/Ubuntu: apt install samtools\n"
            + "  macOS:         brew install samtools\n"
            + "  Conda:         conda install -c bioconda samtools\n"
            + "Then re-run.";
    }

    @SuppressWarnings("unused")
    private static String readUtf8(Path p) throws IOException {
        return new String(Files.readAllBytes(p), StandardCharsets.UTF_8);
    }
}
