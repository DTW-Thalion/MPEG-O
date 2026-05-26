/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.importers;

import global.thalion.ttio.genomics.WrittenGenomicRun;
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
 * Stage B per-read {@link ProgressSink} wiring for {@link BamReader}.
 *
 * <p>Uses the M87 fixture (10 records). Exercises the new sink
 * overload to assert that the final callback fires with the exact
 * record count, regardless of mid-iteration cadence.</p>
 */
class BamReaderProgressTest {

    private static final Path FIXTURE_DIR =
        Paths.get("src", "test", "resources", "ttio", "fixtures", "genomic");
    private static final Path BAM_PATH = FIXTURE_DIR.resolve("m87_test.bam");

    @BeforeAll
    static void verifyFixture() {
        assumeTrue(Files.isRegularFile(BAM_PATH),
            "fixture missing: " + BAM_PATH.toAbsolutePath());
    }

    @Test
    void bamReader_emits_final_progress_callback() throws Exception {
        AtomicLong lastDone = new AtomicLong(-1L);
        AtomicLong lastTotal = new AtomicLong(-1L);
        AtomicInteger callbackCount = new AtomicInteger();
        ProgressSink sink = (done, total) -> {
            callbackCount.incrementAndGet();
            lastDone.set(done);
            lastTotal.set(total);
        };

        BamReader r = new BamReader(BAM_PATH);
        WrittenGenomicRun run =
            r.toGenomicRun("genomic_0001", null, null, sink);

        assertTrue(callbackCount.get() >= 1,
            "expected at least one final progress callback");
        assertEquals(run.readNames().size(), lastDone.get(),
            "final done must equal parsed record count");
        assertEquals(run.readNames().size(), lastTotal.get(),
            "final total must equal final done");
    }

    @Test
    void bamReader_no_sink_overload_still_works() throws Exception {
        // Backwards-compat: existing callers using the no-sink overload
        // must keep working (sink defaulted to ProgressSink.discard()).
        BamReader r = new BamReader(BAM_PATH);
        WrittenGenomicRun run = r.toGenomicRun("genomic_0001");
        assertTrue(run.readNames().size() > 0,
            "no-sink overload should parse records as before");
    }
}
