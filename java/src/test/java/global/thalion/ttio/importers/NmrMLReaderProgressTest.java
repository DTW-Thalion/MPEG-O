/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.importers;

import global.thalion.ttio.io.ProgressSink;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

/**
 * Stage C per-spectrum {@link ProgressSink} wiring for {@link NmrMLReader}.
 *
 * <p>Uses the in-tree bmse000325 fixture. nmrML files canonically carry
 * one 1-D spectrum, so the sink fires exactly once with {@code (1, 1)}
 * after a successful parse.</p>
 */
class NmrMLReaderProgressTest {

    private static final Path FIXTURE =
        Paths.get("src", "test", "resources", "bmse000325.nmrML");

    @BeforeAll
    static void verifyFixture() {
        assumeTrue(Files.isRegularFile(FIXTURE),
            "fixture missing: " + FIXTURE.toAbsolutePath());
    }

    @Test
    void nmrmlReader_emits_single_final_callback() throws Exception {
        AtomicLong lastDone = new AtomicLong(-1L);
        AtomicLong lastTotal = new AtomicLong(-1L);
        AtomicInteger callbackCount = new AtomicInteger();
        ProgressSink sink = (done, total) -> {
            callbackCount.incrementAndGet();
            lastDone.set(done);
            lastTotal.set(total);
        };

        NmrMLReader.read(FIXTURE.toString(), sink);

        assertEquals(1, callbackCount.get(),
            "nmrML produces a single spectrum, sink fires once");
        assertEquals(1L, lastDone.get(), "final done == 1");
        assertEquals(1L, lastTotal.get(), "final total == done");
    }

    @Test
    void nmrmlReader_no_sink_overload_still_works() throws Exception {
        // Backwards-compat: existing String-path callers must keep working.
        NmrMLReader.NmrMLResult result =
            NmrMLReader.read(FIXTURE.toString());
        org.junit.jupiter.api.Assertions.assertTrue(
            result.run().spectrumIndex().count() >= 1,
            "no-sink overload should parse spectrum as before");
    }
}
