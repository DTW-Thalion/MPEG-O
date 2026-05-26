/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.exporters;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.genomics.ReferenceImport;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.io.ProgressSink;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Stage D progress wiring for {@link FastaWriter}. Reads-side uses the
 * 1000-cadence; reference-side fires once per chromosome.
 */
class FastaWriterProgressTest {

    private static WrittenGenomicRun synthRun(int n) {
        byte[] acgt = "ACGT".getBytes(StandardCharsets.US_ASCII);
        byte[] sequences = new byte[10 * n];
        byte[] qualities = new byte[10 * n];
        for (int i = 0; i < 10 * n; i++) sequences[i] = acgt[i % 4];
        long[] positions = new long[n];
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        byte[] mapqs = new byte[n];
        int[] flags = new int[n];
        long[] matePos = new long[n];
        int[] tlens = new int[n];
        List<String> readNames = new ArrayList<>(n);
        List<String> chromosomes = new ArrayList<>(n);
        List<String> cigars = new ArrayList<>(n);
        List<String> mateChroms = new ArrayList<>(n);
        for (int i = 0; i < n; i++) {
            positions[i] = 0L;
            offsets[i] = i * 10L;
            lengths[i] = 10;
            flags[i] = 4;
            matePos[i] = 0L;
            readNames.add("r" + i);
            chromosomes.add("*");
            cigars.add("*");
            mateChroms.add("*");
        }
        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS, "", "ILLUMINA", "sample",
            positions, mapqs, flags,
            sequences, qualities, offsets, lengths,
            cigars, readNames, mateChroms, matePos, tlens, chromosomes,
            Compression.ZLIB);
    }

    @Test
    void fastaWriter_writeRun_emits_progress_per_thousand_reads(@TempDir Path tmp) throws Exception {
        WrittenGenomicRun run = synthRun(2500);
        Path out = tmp.resolve("reads.fa");

        AtomicInteger count = new AtomicInteger();
        AtomicLong lastDone = new AtomicLong(-1);
        AtomicLong lastTotal = new AtomicLong(-1);
        ProgressSink sink = (done, total) -> {
            count.incrementAndGet();
            lastDone.set(done);
            lastTotal.set(total);
        };
        FastaWriter.writeRun(run, out, 60, /*gzip=*/false, false, sink);
        assertTrue(count.get() >= 2);
        assertEquals(2500L, lastDone.get());
        assertEquals(2500L, lastTotal.get());
    }

    @Test
    void fastaWriter_writeReference_fires_per_chromosome(@TempDir Path tmp) throws Exception {
        // 4-chromosome synthetic reference, ~50 bp each.
        List<String> chroms = List.of("chr1", "chr2", "chr3", "chr4");
        List<byte[]> seqs = new ArrayList<>();
        byte[] acgt = "ACGT".getBytes(StandardCharsets.US_ASCII);
        for (int i = 0; i < 4; i++) {
            byte[] s = new byte[50];
            for (int j = 0; j < 50; j++) s[j] = acgt[(i + j) % 4];
            seqs.add(s);
        }
        ReferenceImport ref = new ReferenceImport("synthetic_ref", chroms, seqs);
        Path out = tmp.resolve("ref.fa");

        AtomicInteger count = new AtomicInteger();
        AtomicLong lastDone = new AtomicLong(-1);
        AtomicLong lastTotal = new AtomicLong(-1);
        ProgressSink sink = (done, total) -> {
            count.incrementAndGet();
            lastDone.set(done);
            lastTotal.set(total);
        };
        FastaWriter.writeReference(ref, out, 60, /*gzip=*/false, false, sink);
        // 4 chroms -> 3 mid-write + 1 final fire = 4 callbacks total.
        assertTrue(count.get() >= 4,
            "expected >=4 callbacks for 4 chromosomes, got " + count.get());
        assertEquals(4L, lastDone.get());
        assertEquals(4L, lastTotal.get());
    }

    @Test
    void fastaWriter_default_overloads_use_discard_sink(@TempDir Path tmp) throws Exception {
        WrittenGenomicRun run = synthRun(3);
        Path out1 = tmp.resolve("tiny.fa");
        FastaWriter.writeRun(run, out1);  // no sink, must not throw

        ReferenceImport ref = new ReferenceImport(
            "r", List.of("chr1"),
            List.of("ACGT".getBytes(StandardCharsets.US_ASCII)));
        Path out2 = tmp.resolve("tinyref.fa");
        FastaWriter.writeReference(ref, out2);  // no sink, must not throw
    }
}
