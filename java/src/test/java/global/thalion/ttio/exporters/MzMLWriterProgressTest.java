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
 * Stage D per-spectrum {@link ProgressSink} wiring for {@link MzMLWriter}.
 *
 * <p>Cadence: {@code PROGRESS_INTERVAL_SPECTRA = 100} (mirrors
 * {@link global.thalion.ttio.importers.MzMLReader}).</p>
 */
class MzMLWriterProgressTest {

    private static AcquisitionRun synthRun(int nSpectra) {
        // Single peak per spectrum -> 1 sample of mz + intensity.
        long[] offsets = new long[nSpectra];
        int[] lengths = new int[nSpectra];
        double[] rts = new double[nSpectra];
        int[] msLevels = new int[nSpectra];
        int[] polarities = new int[nSpectra];
        double[] precMz = new double[nSpectra];
        int[] precCharge = new int[nSpectra];
        double[] basePeak = new double[nSpectra];
        for (int i = 0; i < nSpectra; i++) {
            offsets[i] = i;
            lengths[i] = 1;
            rts[i] = i * 0.1;
            msLevels[i] = 1;
            polarities[i] = 1;
        }
        SpectrumIndex idx = new SpectrumIndex(
            nSpectra, offsets, lengths, rts, msLevels, polarities,
            precMz, precCharge, basePeak);

        Map<String, double[]> channels = new LinkedHashMap<>();
        double[] mz = new double[nSpectra];
        double[] intensity = new double[nSpectra];
        for (int i = 0; i < nSpectra; i++) {
            mz[i] = 100.0 + i;
            intensity[i] = 1000.0;
        }
        channels.put("mz", mz);
        channels.put("intensity", intensity);

        InstrumentConfig cfg = new InstrumentConfig("vendor", "model", "sn",
            "ESI", "QTOF", "MCP");
        return new AcquisitionRun(
            "synthRun", AcquisitionMode.MS1_DDA, idx, cfg, channels,
            List.of(), List.of(), null, 0.0);
    }

    @Test
    void mzMLWriter_emits_progress_per_hundred_spectra(@TempDir Path tmp) {
        AcquisitionRun run = synthRun(350);
        Path out = tmp.resolve("synth.mzml");

        AtomicInteger count = new AtomicInteger();
        AtomicLong lastDone = new AtomicLong(-1);
        AtomicLong lastTotal = new AtomicLong(-1);
        ProgressSink sink = (done, total) -> {
            count.incrementAndGet();
            lastDone.set(done);
            lastTotal.set(total);
        };
        MzMLWriter.write(run, out.toString(), /*zlib=*/false, sink);
        // 350 / 100 = 3 mid-write fires + 1 final.
        assertTrue(count.get() >= 3, "expected >=3 callbacks, got " + count.get());
        assertEquals(350L, lastDone.get());
        assertEquals(350L, lastTotal.get());
    }

    @Test
    void mzMLWriter_emits_final_callback_for_small_inputs(@TempDir Path tmp) {
        AcquisitionRun run = synthRun(5);
        Path out = tmp.resolve("small.mzml");
        AtomicInteger count = new AtomicInteger();
        AtomicLong lastDone = new AtomicLong(-1);
        ProgressSink sink = (done, total) -> {
            count.incrementAndGet();
            lastDone.set(done);
        };
        MzMLWriter.write(run, out.toString(), /*zlib=*/false, sink);
        assertTrue(count.get() >= 1, "final callback must always fire");
        assertEquals(5L, lastDone.get());
    }

    @Test
    void mzMLWriter_default_overload_uses_discard_sink(@TempDir Path tmp) {
        AcquisitionRun run = synthRun(3);
        Path out = tmp.resolve("tiny.mzml");
        MzMLWriter.write(run, out.toString());  // no sink, must not throw
    }
}
