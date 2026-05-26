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
 * Stage B per-read {@link ProgressSink} wiring for {@link FastqReader}.
 *
 * <p>Asserts that the new sink overload fires periodic mid-parse
 * callbacks and a final {@code done==total} callback, without changing
 * the parsed-record contents.</p>
 */
class FastqReaderProgressTest {

    /** Synthesise a FASTQ file with {@code n} four-line records. */
    private static Path writeSyntheticFastq(Path tmp, String name, int n)
            throws Exception {
        Path fq = tmp.resolve(name);
        try (BufferedWriter w = Files.newBufferedWriter(fq)) {
            for (int i = 0; i < n; i++) {
                w.write("@read" + i); w.newLine();
                w.write("ACGTACGTAC");  w.newLine();
                w.write("+");           w.newLine();
                w.write("IIIIIIIIII");  w.newLine();
            }
        }
        return fq;
    }

    @Test
    void fastqReader_emits_progress_per_thousand_reads(@TempDir Path tmp)
            throws Exception {
        Path fq = writeSyntheticFastq(tmp, "5k.fq", 5000);

        AtomicLong lastDone = new AtomicLong(-1L);
        AtomicLong lastTotal = new AtomicLong(-1L);
        AtomicInteger callbackCount = new AtomicInteger();
        ProgressSink sink = (done, total) -> {
            callbackCount.incrementAndGet();
            lastDone.set(done);
            lastTotal.set(total);
        };

        FastqReader r = new FastqReader(fq);
        r.read("sample", sink);

        // 5000 reads / 1000-cadence = 5 mid-parse fires + 1 final fire.
        assertTrue(callbackCount.get() >= 5,
            "expected at least 5 callbacks for 5000 reads, got "
                + callbackCount.get());
        assertEquals(5000L, lastDone.get(),
            "final callback should report exact read count");
        assertEquals(5000L, lastTotal.get(),
            "final callback should set total == done");
    }

    @Test
    void fastqReader_emits_final_callback_for_small_inputs(@TempDir Path tmp)
            throws Exception {
        Path fq = writeSyntheticFastq(tmp, "small.fq", 5);

        AtomicLong lastDone = new AtomicLong(-1L);
        AtomicLong lastTotal = new AtomicLong(-1L);
        AtomicInteger callbackCount = new AtomicInteger();
        ProgressSink sink = (done, total) -> {
            callbackCount.incrementAndGet();
            lastDone.set(done);
            lastTotal.set(total);
        };

        FastqReader r = new FastqReader(fq);
        r.read("sample", sink);

        // 5 records → 0 mid-parse fires + 1 final fire.
        assertTrue(callbackCount.get() >= 1,
            "final callback must always fire even for small inputs");
        assertEquals(5L, lastDone.get(), "final done == record count");
        assertEquals(5L, lastTotal.get(), "final total == done for known-total");
    }

    @Test
    void fastqReader_default_overload_uses_discard_sink(@TempDir Path tmp)
            throws Exception {
        Path fq = writeSyntheticFastq(tmp, "tiny.fq", 3);
        // No sink → must not throw (uses ProgressSink.discard()).
        FastqReader r = new FastqReader(fq);
        var run = r.read("sample");
        assertEquals(3, run.readNames().size());
    }
}
