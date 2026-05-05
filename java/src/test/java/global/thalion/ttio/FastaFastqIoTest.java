/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio;

import global.thalion.ttio.exporters.FastaWriter;
import global.thalion.ttio.exporters.FastqWriter;
import global.thalion.ttio.genomics.ReferenceImport;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.importers.FastaParseException;
import global.thalion.ttio.importers.FastaReader;
import global.thalion.ttio.importers.FastqParseException;
import global.thalion.ttio.importers.FastqReader;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Round-trip + parser-correctness tests for the FASTA/FASTQ I/O
 * paths. Mirrors {@code python/tests/test_fasta_fastq_io.py}.
 */
class FastaFastqIoTest {

    private static Path write(Path p, String content) throws IOException {
        Files.writeString(p, content, StandardCharsets.UTF_8);
        return p;
    }

    private static Path writeBytes(Path p, byte[] content) throws IOException {
        Files.write(p, content);
        return p;
    }

    // ---------------------------------------------------------------- FASTA

    @Test
    void md5IsOrderInvariant() {
        byte[] a = ReferenceImport.computeMd5(
            List.of("chr1", "chr2"),
            List.of("AAA".getBytes(), "GGG".getBytes())
        );
        byte[] b = ReferenceImport.computeMd5(
            List.of("chr2", "chr1"),
            List.of("GGG".getBytes(), "AAA".getBytes())
        );
        assertArrayEquals(a, b);
        assertEquals(16, a.length);
    }

    @Test
    void referenceRoundTripPreservesBytes(@TempDir Path tmp) throws IOException {
        Path fa = write(
            tmp.resolve("ref.fa"),
            ">chr1\nACGTACGT\nACGT\n>chr2\nGGGggg\n"
        );

        ReferenceImport refIn = new FastaReader(fa).readReference();
        assertEquals("ref", refIn.uri());
        assertEquals(List.of("chr1", "chr2"), refIn.chromosomes());
        assertArrayEquals(
            "ACGTACGTACGT".getBytes(StandardCharsets.US_ASCII),
            refIn.sequences().get(0)
        );
        assertArrayEquals(
            "GGGggg".getBytes(StandardCharsets.US_ASCII),
            refIn.sequences().get(1)
        );

        Path out = tmp.resolve("out.fa");
        FastaWriter.writeReference(refIn, out, 4, null, true);
        ReferenceImport refOut = new FastaReader(out).readReference();
        assertEquals(refIn.chromosomes(), refOut.chromosomes());
        assertArrayEquals(refIn.md5(), refOut.md5());
        for (int i = 0; i < refIn.sequences().size(); i++) {
            assertArrayEquals(refIn.sequences().get(i), refOut.sequences().get(i));
        }
    }

    @Test
    void fastaWriterDefault60CharWrap(@TempDir Path tmp) throws IOException {
        byte[] seq = new byte[125];
        Arrays.fill(seq, (byte) 'A');
        ReferenceImport ref = new ReferenceImport(
            "x", List.of("chr1"), List.of(seq)
        );
        Path out = tmp.resolve("x.fa");
        FastaWriter.writeReference(ref, out);
        byte[] body = Files.readAllBytes(out);
        StringBuilder expected = new StringBuilder();
        expected.append(">chr1\n");
        for (int i = 0; i < 60; i++) expected.append('A');
        expected.append('\n');
        for (int i = 0; i < 60; i++) expected.append('A');
        expected.append('\n');
        for (int i = 0; i < 5; i++) expected.append('A');
        expected.append('\n');
        assertArrayEquals(
            expected.toString().getBytes(StandardCharsets.US_ASCII), body
        );
    }

    @Test
    void faiIndexByteLayout(@TempDir Path tmp) throws IOException {
        byte[] seq1 = new byte[100];
        Arrays.fill(seq1, (byte) 'A');
        byte[] seq2 = new byte[60];
        Arrays.fill(seq2, (byte) 'G');
        ReferenceImport ref = new ReferenceImport(
            "x", List.of("chr1", "chr2"), List.of(seq1, seq2)
        );
        Path out = tmp.resolve("x.fa");
        FastaWriter.writeReference(ref, out, 60, null, true);
        Path fai = tmp.resolve("x.fa.fai");
        List<String> lines = Files.readAllLines(fai, StandardCharsets.US_ASCII);
        // chr1: length=100, offset=6, linebases=60, linewidth=61
        assertEquals("chr1\t100\t6\t60\t61", lines.get(0));
        // chr2 offset = 6 + 100 + 2 LFs + ">chr2\n" header (6) = 114
        int expected = 6 + 100 + 2 + 6;
        assertEquals("chr2\t60\t" + expected + "\t60\t61", lines.get(1));
    }

    @Test
    void fastaUnalignedRoundTrip(@TempDir Path tmp) throws IOException {
        Path fa = write(tmp.resolve("reads.fa"),
            ">read_1\nACGTACGT\n>read_2\nGGGGAAAA\n");
        WrittenGenomicRun run = new FastaReader(fa).readUnaligned("NA12878");
        assertEquals("NA12878", run.sampleName());
        assertEquals(List.of("read_1", "read_2"), run.readNames());
        assertEquals(4, run.flags()[0]);
        for (byte b : run.qualities()) {
            assertEquals((byte) 0xFF, b);
        }
        Path out = tmp.resolve("back.fa");
        FastaWriter.writeRun(run, out, 4, null, true);
        byte[] body = Files.readAllBytes(out);
        byte[] expected = (
            ">read_1\nACGT\nACGT\n>read_2\nGGGG\nAAAA\n"
        ).getBytes(StandardCharsets.US_ASCII);
        assertArrayEquals(expected, body);
    }

    @Test
    void fastaParseErrorOnOrphanSequence(@TempDir Path tmp) throws IOException {
        Path fa = write(tmp.resolve("bad.fa"), "ACGT\n>c\nGGG\n");
        FastaParseException e = assertThrows(
            FastaParseException.class,
            () -> new FastaReader(fa).readReference()
        );
        assertTrue(e.getMessage().contains("before any header"));
    }

    // ---------------------------------------------------------------- FASTQ

    private static byte[] phred33(int seqLen, int score) {
        byte[] q = new byte[seqLen];
        Arrays.fill(q, (byte) (score + 33));
        return q;
    }

    @Test
    void fastqPhred33RoundTrip(@TempDir Path tmp) throws IOException {
        StringBuilder sb = new StringBuilder();
        sb.append("@r1\nACGT\n+\n");
        for (int i = 0; i < 4; i++) sb.append((char) (30 + 33));
        sb.append("\n@r2\nGGGG\n+\n");
        for (int i = 0; i < 4; i++) sb.append((char) (20 + 33));
        sb.append('\n');
        Path fq = write(tmp.resolve("reads.fq"), sb.toString());

        FastqReader reader = new FastqReader(fq);
        WrittenGenomicRun run = reader.read("S1");
        assertEquals(33, reader.detectedPhredOffset());
        assertEquals(List.of("r1", "r2"), run.readNames());
        for (int i = 0; i < 4; i++) {
            assertEquals((byte) (30 + 33), run.qualities()[i]);
        }

        Path out = tmp.resolve("back.fq");
        FastqWriter.write(run, out);
        // Round-trip via re-parse.
        WrittenGenomicRun run2 = new FastqReader(out).read("");
        assertEquals(run.readNames(), run2.readNames());
        assertArrayEquals(run.sequences(), run2.sequences());
        assertArrayEquals(run.qualities(), run2.qualities());
    }

    @Test
    void fastqAutoDetectLegacy64() {
        byte[] raw = new byte[41];
        for (int i = 0; i < 41; i++) raw[i] = (byte) (64 + i);
        assertEquals(64, FastqReader.detectPhredOffset(raw));
    }

    @Test
    void fastqAutoDetectModern33() {
        byte[] raw = { 33, 50, 70, (byte) 80 };
        assertEquals(33, FastqReader.detectPhredOffset(raw));
    }

    @Test
    void fastqAutoDetectEmptyDefaults33() {
        assertEquals(33, FastqReader.detectPhredOffset(new byte[0]));
    }

    @Test
    void fastqPhred64NormalisedTo33(@TempDir Path tmp) throws IOException {
        // Phred+64: 'h'=104=score 40
        byte[] qual = { (byte) 104, (byte) 100, (byte) 80 };
        StringBuilder sb = new StringBuilder("@r1\nACG\n+\n");
        for (byte b : qual) sb.append((char) (b & 0xFF));
        sb.append('\n');
        Path fq = write(tmp.resolve("p64.fq"), sb.toString());
        WrittenGenomicRun run = new FastqReader(fq).read("");
        assertEquals(73, run.qualities()[0] & 0xFF);  // 104 - 31
        assertEquals(69, run.qualities()[1] & 0xFF);  // 100 - 31
        assertEquals(49, run.qualities()[2] & 0xFF);  //  80 - 31
    }

    @Test
    void fastqForcePhred33PassesThrough(@TempDir Path tmp) throws IOException {
        byte[] qual = { (byte) 104, (byte) 100, (byte) 80 };
        StringBuilder sb = new StringBuilder("@r1\nACG\n+\n");
        for (byte b : qual) sb.append((char) (b & 0xFF));
        sb.append('\n');
        Path fq = write(tmp.resolve("force.fq"), sb.toString());
        WrittenGenomicRun run = new FastqReader(fq, 33).read("");
        assertArrayEquals(qual, run.qualities());
    }

    @Test
    void fastqExportPhred64(@TempDir Path tmp) throws IOException {
        StringBuilder sb = new StringBuilder("@r1\nACG\n+\n");
        for (int i = 0; i < 3; i++) sb.append((char) (20 + 33));
        sb.append('\n');
        Path fq = write(tmp.resolve("in.fq"), sb.toString());
        WrittenGenomicRun run = new FastqReader(fq).read("");
        Path out = tmp.resolve("out.fq");
        FastqWriter.write(run, out, null, 64);
        byte[] body = Files.readAllBytes(out);
        // Phred+33 byte 53 (= 20 + 33) -> Phred+64 byte 84 (= 20 + 64).
        String s = new String(body, StandardCharsets.US_ASCII);
        assertTrue(s.contains("\n+\nTTT\n"),  // (char) 84 == 'T'
            "expected Phred+64 'TTT' in: " + s);
    }

    @Test
    void fastqParseErrorMissingSeparator(@TempDir Path tmp) throws IOException {
        Path fq = write(tmp.resolve("bad.fq"),
            "@r1\nACGT\nNOT_A_PLUS\n!!!!\n");
        FastqParseException e = assertThrows(
            FastqParseException.class,
            () -> new FastqReader(fq).read("")
        );
        assertTrue(e.getMessage().contains("separator"));
    }

    @Test
    void fastqParseErrorSeqQualMismatch(@TempDir Path tmp) throws IOException {
        Path fq = write(tmp.resolve("bad.fq"), "@r1\nACGT\n+\n!!!\n");
        FastqParseException e = assertThrows(
            FastqParseException.class,
            () -> new FastqReader(fq).read("")
        );
        assertTrue(e.getMessage().contains("length mismatch"));
    }
}
