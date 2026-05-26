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
 * Stage B per-read {@link ProgressSink} wiring for {@link SamReader}.
 *
 * <p>{@link SamReader} extends {@link BamReader} and inherits the new
 * {@code toGenomicRun(name, region, sample, sink)} overload. This test
 * confirms inheritance fires the sink on SAM text input the same way
 * the parent does on BAM.</p>
 */
class SamReaderProgressTest {

    private static final Path FIXTURE_DIR =
        Paths.get("src", "test", "resources", "ttio", "fixtures", "genomic");
    private static final Path SAM_PATH = FIXTURE_DIR.resolve("m87_test.sam");

    @BeforeAll
    static void verifyFixture() {
        assumeTrue(Files.isRegularFile(SAM_PATH),
            "fixture missing: " + SAM_PATH.toAbsolutePath());
    }

    @Test
    void samReader_emits_final_progress_callback() throws Exception {
        AtomicLong lastDone = new AtomicLong(-1L);
        AtomicLong lastTotal = new AtomicLong(-1L);
        AtomicInteger callbackCount = new AtomicInteger();
        ProgressSink sink = (done, total) -> {
            callbackCount.incrementAndGet();
            lastDone.set(done);
            lastTotal.set(total);
        };

        SamReader r = new SamReader(SAM_PATH);
        WrittenGenomicRun run =
            r.toGenomicRun("genomic_0001", null, null, sink);

        assertTrue(callbackCount.get() >= 1,
            "expected at least one final progress callback");
        assertEquals(run.readNames().size(), lastDone.get(),
            "final done must equal parsed record count");
        assertEquals(run.readNames().size(), lastTotal.get(),
            "final total must equal final done");
    }
}
