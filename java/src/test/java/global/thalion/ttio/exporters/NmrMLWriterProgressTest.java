/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.exporters;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.SpectrumIndex;
import global.thalion.ttio.io.ProgressSink;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Stage D progress wiring for {@link NmrMLWriter}.
 *
 * <p>nmrML stores a single 1-D spectrum per file, so the per-spectrum
 * cadence collapses to one final {@code onProgress(1, 1)} fire.</p>
 */
class NmrMLWriterProgressTest {

    private static AcquisitionRun synthRun(int nPoints) {
        SpectrumIndex idx = new SpectrumIndex(
            1, new long[]{0L}, new int[]{nPoints},
            new double[]{0.0}, new int[]{1}, new int[]{0},
            new double[]{0.0}, new int[]{0}, new double[]{0.0});
        Map<String, double[]> channels = new LinkedHashMap<>();
        double[] cs = new double[nPoints];
        double[] intensity = new double[nPoints];
        for (int i = 0; i < nPoints; i++) {
            cs[i] = i * 0.01;
            intensity[i] = 1000.0;
        }
        channels.put("chemical_shift", cs);
        channels.put("intensity", intensity);
        InstrumentConfig cfg = new InstrumentConfig("v", "m", "sn", "RF", "FT", "RF");
        return new AcquisitionRun(
            "run", AcquisitionMode.NMR_1D, idx, cfg, channels,
            List.of(), List.of(), "1H", 400.0);
    }

    @Test
    void nmrMLWriter_emits_final_callback(@TempDir Path tmp) {
        AcquisitionRun run = synthRun(100);
        Path out = tmp.resolve("synth.nmrml");
        AtomicInteger count = new AtomicInteger();
        AtomicLong lastDone = new AtomicLong(-1);
        AtomicLong lastTotal = new AtomicLong(-1);
        ProgressSink sink = (done, total) -> {
            count.incrementAndGet();
            lastDone.set(done);
            lastTotal.set(total);
        };
        NmrMLWriter.write(run, out.toString(), sink);
        assertTrue(count.get() >= 1, "final callback must fire");
        assertEquals(1L, lastDone.get());
        assertEquals(1L, lastTotal.get());
    }

    @Test
    void nmrMLWriter_default_overload_uses_discard_sink(@TempDir Path tmp) {
        AcquisitionRun run = synthRun(10);
        Path out = tmp.resolve("tiny.nmrml");
        NmrMLWriter.write(run, out.toString());  // no sink, must not throw
    }
}
