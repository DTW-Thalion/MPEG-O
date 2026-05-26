/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.importers;

import global.thalion.ttio.io.ProgressSink;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.BufferedWriter;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Stage C per-row {@link ProgressSink} wiring for {@link MzTabReader}.
 *
 * <p>mzTab is tab-separated; this reader counts data rows (PRT / PEP /
 * PSM / SML / SMF / SME) for the progress cadence. The default
 * {@link MzTabReader#PROGRESS_INTERVAL_ROWS} is 500.</p>
 */
class MzTabReaderProgressTest {

    /** Synthesise a minimal proteomics mzTab 1.0 file with {@code n}
     *  PSM data rows; one ms_run, single search engine, fixed accession
     *  so row-handler invariants don't reject the rows. */
    private static Path writeSyntheticMzTab(Path tmp, String name, int n)
            throws IOException {
        Path out = tmp.resolve(name);
        try (BufferedWriter w = Files.newBufferedWriter(out)) {
            w.write("MTD\tmzTab-version\t1.0\n");
            w.write("MTD\tdescription\tStage C progress synthetic\n");
            w.write("MTD\tms_run[1]-location\tfile:///tmp/run.mzML\n");
            w.write("MTD\tsoftware[1]\t[MS, MS:1001456, X!Tandem, v2.4.0]\n");
            w.write("MTD\tpsm_search_engine_score[1]\t[MS, MS:1001330, X!Tandem expect, ]\n");
            w.write("\n");
            w.write("PSH\tsequence\tPSM_ID\taccession\tunique\tdatabase\tdatabase_version"
                + "\tsearch_engine\tsearch_engine_score[1]\tmodifications\tretention_time"
                + "\tcharge\texp_mass_to_charge\tcalc_mass_to_charge\tpre\tpost"
                + "\tstart\tend\tspectra_ref\n");
            for (int i = 0; i < n; i++) {
                w.write("PSM\tSEQUENCE" + i + "\t" + (i + 1) + "\tP02769\t1\tUniProtKB"
                    + "\t2024_04\t[MS, MS:1001456, X!Tandem, v2.4.0]\t0.9\tnull\t120.0\t2"
                    + "\t413.7\t413.69\tK\tI\t1\t10\tms_run[1]:scan=" + i + "\n");
            }
        }
        return out;
    }

    @Test
    void mztabReader_emits_progress_per_five_hundred_rows(@TempDir Path tmp)
            throws Exception {
        // 1200 PSM rows → 2 mid-fires (500, 1000) + 1 final fire.
        Path mt = writeSyntheticMzTab(tmp, "progress.mztab", 1200);

        AtomicLong lastDone = new AtomicLong(-1L);
        AtomicLong lastTotal = new AtomicLong(-1L);
        AtomicInteger callbackCount = new AtomicInteger();
        ProgressSink sink = (done, total) -> {
            callbackCount.incrementAndGet();
            lastDone.set(done);
            lastTotal.set(total);
        };

        MzTabReader.read(mt, sink);

        assertTrue(callbackCount.get() >= 2,
            "expected at least 2 callbacks for 1200 rows, got "
                + callbackCount.get());
        assertEquals(1200L, lastDone.get(),
            "final callback should report exact row count");
        assertEquals(1200L, lastTotal.get(),
            "final callback should set total == done");
    }

    @Test
    void mztabReader_emits_final_callback_for_small_inputs(@TempDir Path tmp)
            throws Exception {
        // 5 rows → 0 mid-fires + 1 final fire.
        Path mt = writeSyntheticMzTab(tmp, "small.mztab", 5);

        AtomicLong lastDone = new AtomicLong(-1L);
        AtomicLong lastTotal = new AtomicLong(-1L);
        AtomicInteger callbackCount = new AtomicInteger();
        ProgressSink sink = (done, total) -> {
            callbackCount.incrementAndGet();
            lastDone.set(done);
            lastTotal.set(total);
        };

        MzTabReader.read(mt, sink);

        assertTrue(callbackCount.get() >= 1,
            "final callback must always fire even for small inputs");
        assertEquals(5L, lastDone.get(), "final done == row count");
        assertEquals(5L, lastTotal.get(), "final total == done");
    }

    @Test
    void mztabReader_no_sink_overload_still_works(@TempDir Path tmp)
            throws Exception {
        Path mt = writeSyntheticMzTab(tmp, "tiny.mztab", 2);
        MzTabReader.MzTabImport im = MzTabReader.read(mt);
        assertEquals(2, im.identifications().size(),
            "no-sink overload should parse rows as before");
    }
}
