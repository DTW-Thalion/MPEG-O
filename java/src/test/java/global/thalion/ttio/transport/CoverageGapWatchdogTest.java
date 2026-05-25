package global.thalion.ttio.transport;

import global.thalion.ttio.SpectralDataset;
import org.junit.jupiter.api.Disabled;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.*;

/** Crude-but-effective floor: the .tis byte size MUST be at least
 *  1% of the source .tio byte size. If a writer silently drops a
 *  content type, this test fires immediately.
 *
 *  Stage 0 wires this against the reference_only fixture only.
 *  Stage 1 introduces an `everything.tio` fixture that exercises the
 *  watchdog against every accessor at once. */
@Disabled("v0.11 — pending Stage 1 writer/reader implementation")
class CoverageGapWatchdogTest {

    @Test
    void tisSizeIsAtLeastOnePercentOfTio(@TempDir Path tmp) throws Exception {
        Path src = FixtureBuilder.buildReferenceOnly(tmp.resolve("src.tio"));
        Path tis = tmp.resolve("src.tis");

        try (SpectralDataset ds = SpectralDataset.open(src.toString());
             OutputStream out = Files.newOutputStream(tis);
             TransportWriter w = new TransportWriter(out)) {
            w.writeDataset(ds);
        }

        long srcSize = Files.size(src);
        long tisSize = Files.size(tis);
        assertTrue(tisSize > srcSize / 100,
            "Coverage gap watchdog: .tis " + tisSize + " bytes < 1% of "
            + ".tio " + srcSize + " bytes — likely a writer is silently "
            + "dropping a content type.");
    }
}
