/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.exporters;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
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
 * Stage D per-read {@link ProgressSink} wiring for {@link FastqWriter}.
 */
class FastqWriterProgressTest {

    private static WrittenGenomicRun synthRun(int n) {
        byte[] oneSeq = new byte[10];
        byte[] oneQual = new byte[10];
        byte[] acgt = "ACGT".getBytes(StandardCharsets.US_ASCII);
        for (int i = 0; i < 10; i++) {
            oneSeq[i] = acgt[i % 4];
            oneQual[i] = (byte) 'I';
        }
        byte[] sequences = new byte[10 * n];
        byte[] qualities = new byte[10 * n];
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
            System.arraycopy(oneSeq, 0, sequences, i * 10, 10);
            System.arraycopy(oneQual, 0, qualities, i * 10, 10);
            positions[i] = 0L;
            offsets[i] = i * 10L;
            lengths[i] = 10;
            mapqs[i] = 0;
            flags[i] = 4;
            matePos[i] = 0L;
            tlens[i] = 0;
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
    void fastqWriter_emits_progress_per_thousand_reads(@TempDir Path tmp) throws Exception {
        WrittenGenomicRun run = synthRun(2500);
        Path out = tmp.resolve("synth.fq");

        AtomicInteger count = new AtomicInteger();
        AtomicLong lastDone = new AtomicLong(-1);
        AtomicLong lastTotal = new AtomicLong(-1);
        ProgressSink sink = (done, total) -> {
            count.incrementAndGet();
            lastDone.set(done);
            lastTotal.set(total);
        };

        FastqWriter.write(run, out, /*gzip=*/false, 33, sink);

        // 2500 / 1000 = 2 mid-write fires + 1 final.
        assertTrue(count.get() >= 2,
            "expected >=2 callbacks for 2500 reads, got " + count.get());
        assertEquals(2500L, lastDone.get());
        assertEquals(2500L, lastTotal.get());
    }

    @Test
    void fastqWriter_emits_final_callback_for_small_inputs(@TempDir Path tmp) throws Exception {
        WrittenGenomicRun run = synthRun(5);
        Path out = tmp.resolve("small.fq");
        AtomicInteger count = new AtomicInteger();
        AtomicLong lastDone = new AtomicLong(-1);
        ProgressSink sink = (done, total) -> {
            count.incrementAndGet();
            lastDone.set(done);
        };
        FastqWriter.write(run, out, /*gzip=*/false, 33, sink);
        assertTrue(count.get() >= 1, "final callback must always fire");
        assertEquals(5L, lastDone.get());
    }

    @Test
    void fastqWriter_default_overload_uses_discard_sink(@TempDir Path tmp) throws Exception {
        WrittenGenomicRun run = synthRun(3);
        Path out = tmp.resolve("tiny.fq");
        FastqWriter.write(run, out);
    }
}
