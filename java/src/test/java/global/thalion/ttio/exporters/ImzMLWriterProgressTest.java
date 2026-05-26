/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.exporters;

import global.thalion.ttio.importers.ImzMLReader.PixelSpectrum;
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
 * Stage D per-pixel {@link ProgressSink} wiring for {@link ImzMLWriter}.
 */
class ImzMLWriterProgressTest {

    private static List<PixelSpectrum> synthPixels(int n) {
        double[] mz = new double[]{100.0, 200.0, 300.0};
        List<PixelSpectrum> pixels = new ArrayList<>(n);
        // Lay pixels out in a 1xn row.
        for (int i = 0; i < n; i++) {
            pixels.add(new PixelSpectrum(
                i + 1, 1, 1,
                mz,
                new double[]{1.0, 2.0, 3.0}));
        }
        return pixels;
    }

    @Test
    void imzMLWriter_emits_progress_per_hundred_pixels(@TempDir Path tmp) {
        List<PixelSpectrum> pixels = synthPixels(350);
        Path imzml = tmp.resolve("synth.imzML");

        AtomicInteger count = new AtomicInteger();
        AtomicLong lastDone = new AtomicLong(-1);
        AtomicLong lastTotal = new AtomicLong(-1);
        ProgressSink sink = (done, total) -> {
            count.incrementAndGet();
            lastDone.set(done);
            lastTotal.set(total);
        };
        ImzMLWriter.write(
            pixels, imzml, /*ibdPath*/ null,
            "continuous",
            350, 1, 1,
            10.0, 10.0,
            "flyback",
            "00112233445566778899AABBCCDDEEFF",
            sink);
        // 350 / 100 = 3 mid-write + 1 final = >=3 callbacks.
        assertTrue(count.get() >= 3, "expected >=3 callbacks, got " + count.get());
        assertEquals(350L, lastDone.get());
        assertEquals(350L, lastTotal.get());
    }

    @Test
    void imzMLWriter_emits_final_callback_for_small_inputs(@TempDir Path tmp) {
        List<PixelSpectrum> pixels = synthPixels(5);
        Path imzml = tmp.resolve("small.imzML");
        AtomicInteger count = new AtomicInteger();
        AtomicLong lastDone = new AtomicLong(-1);
        ProgressSink sink = (done, total) -> {
            count.incrementAndGet();
            lastDone.set(done);
        };
        ImzMLWriter.write(
            pixels, imzml, /*ibdPath*/ null,
            "continuous",
            5, 1, 1, 10.0, 10.0,
            "flyback", "00112233445566778899AABBCCDDEEFF",
            sink);
        assertTrue(count.get() >= 1);
        assertEquals(5L, lastDone.get());
    }

    @Test
    void imzMLWriter_default_overload_uses_discard_sink(@TempDir Path tmp) {
        List<PixelSpectrum> pixels = synthPixels(3);
        Path imzml = tmp.resolve("tiny.imzML");
        // No sink overload, must not throw.
        ImzMLWriter.write(
            pixels, imzml, /*ibdPath*/ null,
            "continuous", 3, 1, 1, 10.0, 10.0,
            "flyback", "00112233445566778899AABBCCDDEEFF");
    }
}
