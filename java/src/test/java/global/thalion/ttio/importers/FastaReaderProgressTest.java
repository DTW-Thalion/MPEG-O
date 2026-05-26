/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.importers;

import global.thalion.ttio.io.ProgressSink;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.BufferedWriter;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Stage B per-read {@link ProgressSink} wiring for
 * {@link FastaReader#readUnaligned(String, ProgressSink)} and friends.
 *
 * <p>Stage A already covered {@code readReference} via the
 * {@code ReferenceImport.writeToDataset(..., sink)} path. This test
 * exercises the new sink on the unaligned-reads code path.</p>
 */
class FastaReaderProgressTest {

    /** Synthesise a FASTA file with {@code n} records, each a short
     *  ACGT body. */
    private static Path writeSyntheticFasta(Path tmp, String name, int n)
            throws Exception {
        Path fa = tmp.resolve(name);
        try (BufferedWriter w = Files.newBufferedWriter(fa)) {
            for (int i = 0; i < n; i++) {
                w.write(">read" + i); w.newLine();
                w.write("ACGTACGTAC");  w.newLine();
            }
        }
        return fa;
    }

    @Test
    void fastaReader_unaligned_emits_progress_per_thousand_reads(
            @TempDir Path tmp) throws Exception {
        Path fa = writeSyntheticFasta(tmp, "5k.fa", 5000);

        AtomicLong lastDone = new AtomicLong(-1L);
        AtomicLong lastTotal = new AtomicLong(-1L);
        AtomicInteger callbackCount = new AtomicInteger();
        ProgressSink sink = (done, total) -> {
            callbackCount.incrementAndGet();
            lastDone.set(done);
            lastTotal.set(total);
        };

        FastaReader r = new FastaReader(fa);
        r.readUnaligned("panel", sink);

        // 5000 reads / 1000-cadence = 5 mid-parse fires + 1 final fire.
        assertTrue(callbackCount.get() >= 5,
            "expected at least 5 callbacks for 5000 records, got "
                + callbackCount.get());
        assertEquals(5000L, lastDone.get(),
            "final callback should report exact record count");
        assertEquals(5000L, lastTotal.get(),
            "final callback should set total == done");
    }

    @Test
    void fastaReader_unaligned_emits_final_callback_for_small_inputs(
            @TempDir Path tmp) throws Exception {
        Path fa = writeSyntheticFasta(tmp, "small.fa", 5);

        AtomicLong lastDone = new AtomicLong(-1L);
        AtomicInteger callbackCount = new AtomicInteger();
        ProgressSink sink = (done, total) -> {
            callbackCount.incrementAndGet();
            lastDone.set(done);
        };

        FastaReader r = new FastaReader(fa);
        r.readUnaligned("panel", sink);

        assertTrue(callbackCount.get() >= 1,
            "final callback must always fire even for small inputs");
        assertEquals(5L, lastDone.get(), "final done == record count");
    }

    @Test
    void fastaReader_unaligned_default_overload_unchanged(@TempDir Path tmp)
            throws Exception {
        Path fa = writeSyntheticFasta(tmp, "tiny.fa", 3);
        // No-sink overload must still parse exactly as before.
        FastaReader r = new FastaReader(fa);
        var run = r.readUnaligned("panel");
        assertEquals(3, run.readNames().size());
    }
}
