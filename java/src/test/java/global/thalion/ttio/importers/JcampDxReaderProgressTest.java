/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.importers;

import global.thalion.ttio.Spectrum;
import global.thalion.ttio.io.ProgressSink;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;

/**
 * Stage C per-spectrum {@link ProgressSink} wiring for
 * {@link JcampDxReader}.
 *
 * <p>JCAMP-DX files canonically carry one spectrum (the multi-block
 * link block dialect is not yet supported by this reader), so the sink
 * fires exactly once with {@code (1, 1)} after a successful parse.</p>
 */
class JcampDxReaderProgressTest {

    /** Synthesise a minimal valid JCAMP-DX 5.01 IR-absorbance file with
     *  three AFFN data points. */
    private static Path writeSyntheticJcamp(Path tmp, String name)
            throws IOException {
        Path out = tmp.resolve(name);
        String body = "##TITLE=synthetic\n"
            + "##JCAMP-DX=5.01\n"
            + "##DATA TYPE=INFRARED ABSORBANCE\n"
            + "##XUNITS=1/CM\n"
            + "##YUNITS=ABSORBANCE\n"
            + "##NPOINTS=3\n"
            + "##FIRSTX=1000\n"
            + "##LASTX=1002\n"
            + "##XFACTOR=1\n"
            + "##YFACTOR=1\n"
            + "##XYDATA=(X++(Y..Y))\n"
            + "1000 0.10\n"
            + "1001 0.20\n"
            + "1002 0.30\n"
            + "##END=\n";
        Files.writeString(out, body);
        return out;
    }

    @Test
    void jcampReader_emits_single_final_callback(@TempDir Path tmp)
            throws Exception {
        Path fix = writeSyntheticJcamp(tmp, "synth.jdx");

        AtomicLong lastDone = new AtomicLong(-1L);
        AtomicLong lastTotal = new AtomicLong(-1L);
        AtomicInteger callbackCount = new AtomicInteger();
        ProgressSink sink = (done, total) -> {
            callbackCount.incrementAndGet();
            lastDone.set(done);
            lastTotal.set(total);
        };

        Spectrum sp = JcampDxReader.readSpectrum(fix, sink);

        assertNotNull(sp);
        assertEquals(1, callbackCount.get(),
            "JCAMP-DX produces a single spectrum, sink fires once");
        assertEquals(1L, lastDone.get(), "final done == 1");
        assertEquals(1L, lastTotal.get(), "final total == done");
    }

    @Test
    void jcampReader_no_sink_overload_still_works(@TempDir Path tmp)
            throws Exception {
        Path fix = writeSyntheticJcamp(tmp, "synth.jdx");
        Spectrum sp = JcampDxReader.readSpectrum(fix);
        assertNotNull(sp, "no-sink overload should parse spectrum as before");
    }
}
