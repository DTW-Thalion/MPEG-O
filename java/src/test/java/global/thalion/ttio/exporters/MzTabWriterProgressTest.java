/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.exporters;

import global.thalion.ttio.Feature;
import global.thalion.ttio.Identification;
import global.thalion.ttio.Quantification;
import global.thalion.ttio.io.ProgressSink;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Stage D per-row {@link ProgressSink} wiring for {@link MzTabWriter}.
 *
 * <p>Cadence: {@code PROGRESS_INTERVAL_ROWS = 500}, mirroring the
 * MzTabReader side. Total is reported as -1 mid-emit because rows
 * are accumulated across multiple sections; the final fire stamps
 * both done and total with the actual row count.</p>
 */
class MzTabWriterProgressTest {

    private static List<Identification> idents(int n) {
        List<Identification> result = new ArrayList<>(n);
        for (int i = 0; i < n; i++) {
            result.add(new Identification(
                "run1", i,
                "sp|P" + i + "|TEST",
                0.95,
                List.of()));
        }
        return result;
    }

    private static List<Quantification> quants(int n) {
        List<Quantification> result = new ArrayList<>(n);
        for (int i = 0; i < n; i++) {
            // Distinct chemical_entity per row so PRT grouping doesn't
            // collapse them.
            result.add(new Quantification(
                "sp|P" + i + "|TEST", "sample_A", 100.0 + i, ""));
        }
        return result;
    }

    @Test
    void mzTabWriter_emits_progress_every_500_rows(@TempDir Path tmp) {
        // 1200 idents + 1200 quants -> 1200 PSM + 1200 PRT = 2400 rows.
        Path out = tmp.resolve("synth.mztab");
        AtomicInteger count = new AtomicInteger();
        AtomicLong lastDone = new AtomicLong(-1);
        AtomicLong lastTotal = new AtomicLong(-1);
        ProgressSink sink = (done, total) -> {
            count.incrementAndGet();
            lastDone.set(done);
            lastTotal.set(total);
        };
        MzTabWriter.write(
            out,
            idents(1200),
            quants(1200),
            List.<Feature>of(),
            "1.0",
            "test", "",
            sink);
        // 2400 / 500 = 4 mid-emit fires + 1 final fire.
        assertTrue(count.get() >= 4, "expected >=4 callbacks, got " + count.get());
        assertEquals(2400L, lastDone.get());
        assertEquals(2400L, lastTotal.get(),
            "final callback should stamp total == done");
    }

    @Test
    void mzTabWriter_emits_final_callback_for_small_inputs(@TempDir Path tmp) {
        Path out = tmp.resolve("small.mztab");
        AtomicInteger count = new AtomicInteger();
        AtomicLong lastDone = new AtomicLong(-1);
        AtomicLong lastTotal = new AtomicLong(-1);
        ProgressSink sink = (done, total) -> {
            count.incrementAndGet();
            lastDone.set(done);
            lastTotal.set(total);
        };
        MzTabWriter.write(
            out,
            idents(3), quants(3), List.<Feature>of(),
            "1.0", "small", "",
            sink);
        assertTrue(count.get() >= 1, "final callback must always fire");
        // 3 PSM + 3 PRT = 6 rows.
        assertEquals(6L, lastDone.get());
        assertEquals(6L, lastTotal.get());
    }

    @Test
    void mzTabWriter_default_overload_uses_discard_sink(@TempDir Path tmp) {
        Path out = tmp.resolve("tiny.mztab");
        // No-sink overload, must not throw.
        MzTabWriter.write(
            out, idents(2), quants(2), "1.0", "tiny", "");
    }
}
