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
 * Stage D per-read {@link ProgressSink} wiring for {@link BamWriter}.
 *
 * <p>Asserts that the new sink overload fires periodic mid-write
 * callbacks at the {@code PROGRESS_INTERVAL_READS = 1000} cadence and
 * a final {@code done==total} callback, without breaking the existing
 * no-sink API.</p>
 */
class BamWriterProgressTest {

    /** Build a synthetic run with {@code n} simple reads on chr1. */
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
            positions[i] = 100L + i;
            offsets[i] = i * 10L;
            lengths[i] = 10;
            mapqs[i] = 60;
            flags[i] = 0;
            matePos[i] = 0L;
            tlens[i] = 0;
            readNames.add("r" + i);
            chromosomes.add("chr1");
            cigars.add("10M");
            mateChroms.add("*");
        }
        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS, "chr1", "ILLUMINA", "sample",
            positions, mapqs, flags,
            sequences, qualities, offsets, lengths,
            cigars, readNames, mateChroms, matePos, tlens, chromosomes,
            Compression.ZLIB);
    }

    @Test
    void bamWriter_emits_progress_per_thousand_reads(@TempDir Path tmp) throws Exception {
        WrittenGenomicRun run = synthRun(3500);
        Path out = tmp.resolve("synth.bam");

        AtomicInteger callbackCount = new AtomicInteger();
        AtomicLong lastDone = new AtomicLong(-1L);
        AtomicLong lastTotal = new AtomicLong(-1L);
        ProgressSink sink = (done, total) -> {
            callbackCount.incrementAndGet();
            lastDone.set(done);
            lastTotal.set(total);
        };

        new BamWriter(out).write(run, List.of(), /*sort=*/false, sink);

        // 3500 / 1000-cadence = 3 mid-write fires + 1 final fire.
        assertTrue(callbackCount.get() >= 3,
            "expected at least 3 callbacks for 3500 reads, got "
                + callbackCount.get());
        assertEquals(3500L, lastDone.get(),
            "final callback should report exact read count");
        assertEquals(3500L, lastTotal.get(),
            "final callback should set total == done");
    }

    @Test
    void bamWriter_emits_final_callback_for_small_inputs(@TempDir Path tmp) throws Exception {
        WrittenGenomicRun run = synthRun(5);
        Path out = tmp.resolve("small.bam");

        AtomicInteger callbackCount = new AtomicInteger();
        AtomicLong lastDone = new AtomicLong(-1L);
        AtomicLong lastTotal = new AtomicLong(-1L);
        ProgressSink sink = (done, total) -> {
            callbackCount.incrementAndGet();
            lastDone.set(done);
            lastTotal.set(total);
        };

        new BamWriter(out).write(run, List.of(), /*sort=*/false, sink);
        // 5 records -> 0 mid-write fires + 1 final fire.
        assertTrue(callbackCount.get() >= 1,
            "final callback must always fire even for small inputs");
        assertEquals(5L, lastDone.get(), "final done == record count");
        assertEquals(5L, lastTotal.get(), "final total == done");
    }

    @Test
    void bamWriter_default_overload_uses_discard_sink(@TempDir Path tmp) throws Exception {
        WrittenGenomicRun run = synthRun(3);
        Path out = tmp.resolve("tiny.bam");
        // No sink -> must not throw.
        new BamWriter(out).write(run, List.of(), /*sort=*/false);
    }
}
