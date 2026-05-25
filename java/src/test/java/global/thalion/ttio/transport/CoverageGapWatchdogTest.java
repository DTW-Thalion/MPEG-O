package global.thalion.ttio.transport;

import global.thalion.ttio.SpectralDataset;
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
 *  <p>Wired against the {@code everything.tio} fixture (Task 1.11)
 *  that exercises every first-class v0.11 accessor at once (except
 *  SUBJECTS + SAMPLES, which are deferred). A second test method
 *  additionally asserts the {@code .tis} round-trips back to a
 *  {@code .tio} whose contents match the source across every
 *  {@link AccessorSpec} — the strongest coverage guarantee
 *  Task 1.11 can express.</p>
 */
class CoverageGapWatchdogTest {

    @Test
    void tisSizeIsAtLeastOnePercentOfTio_onEverythingFixture(@TempDir Path tmp)
            throws Exception {
        Path src = FixtureBuilder.buildEverything(tmp.resolve("everything.tio"));
        Path tis = tmp.resolve("everything.tis");

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

    @Test
    void everythingFixture_round_trips_every_accessor(@TempDir Path tmp) throws Exception {
        Path src = FixtureBuilder.buildEverything(tmp.resolve("everything.tio"));
        Path tis = tmp.resolve("everything.tis");
        Path rt  = tmp.resolve("rt.tio");

        try (SpectralDataset ds = SpectralDataset.open(src.toString());
             OutputStream out = Files.newOutputStream(tis);
             TransportWriter w = new TransportWriter(out)) {
            w.writeDataset(ds);
        }

        try (TransportReader r = new TransportReader(Files.readAllBytes(tis));
             SpectralDataset materialised = r.materializeTo(rt.toString())) {
            // close immediately so we can re-open via the canonical reader
        }

        try (SpectralDataset a = SpectralDataset.open(src.toString());
             SpectralDataset b = SpectralDataset.open(rt.toString())) {
            for (AccessorSpec spec : AccessorSpec.values()) {
                spec.assertContentEquals(a, b);
            }
        }
    }
}
