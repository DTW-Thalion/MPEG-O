/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.exporters;

import global.thalion.ttio.RamanSpectrum;
import global.thalion.ttio.io.ProgressSink;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Stage D progress wiring for {@link JcampDxWriter}.
 *
 * <p>Each {@code writeXxxSpectrum} call produces a single 1-D
 * spectrum file, so the per-spectrum cadence collapses to one final
 * {@code onProgress(1, 1)} fire.</p>
 */
class JcampDxWriterProgressTest {

    private static RamanSpectrum synthRaman(int n) {
        double[] xs = new double[n];
        double[] ys = new double[n];
        for (int i = 0; i < n; i++) {
            xs[i] = 500.0 + i;
            ys[i] = 1000.0;
        }
        return new RamanSpectrum(xs, ys, 0, 0.0, 532.0, 50.0, 1.0);
    }

    @Test
    void jcampDxWriter_emits_final_callback(@TempDir Path tmp) throws Exception {
        RamanSpectrum s = synthRaman(50);
        Path out = tmp.resolve("synth.jdx");
        AtomicInteger count = new AtomicInteger();
        AtomicLong lastDone = new AtomicLong(-1);
        AtomicLong lastTotal = new AtomicLong(-1);
        ProgressSink sink = (done, total) -> {
            count.incrementAndGet();
            lastDone.set(done);
            lastTotal.set(total);
        };
        JcampDxWriter.writeRamanSpectrum(s, out, "synth", JcampDxEncoding.AFFN, sink);
        assertTrue(count.get() >= 1);
        assertEquals(1L, lastDone.get());
        assertEquals(1L, lastTotal.get());
    }

    @Test
    void jcampDxWriter_default_overload_uses_discard_sink(@TempDir Path tmp) throws Exception {
        RamanSpectrum s = synthRaman(10);
        Path out = tmp.resolve("tiny.jdx");
        JcampDxWriter.writeRamanSpectrum(s, out, "tiny");  // no sink
    }
}
