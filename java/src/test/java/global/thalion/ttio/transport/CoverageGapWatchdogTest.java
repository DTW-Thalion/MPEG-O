package global.thalion.ttio.transport;

import global.thalion.ttio.SpectralDataset;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.*;

/** Crude-but-effective floor: the {@code .tis} byte size MUST exceed
 *  an absolute minimum (2 KiB) when the writer is given a non-empty
 *  {@code everything.tio} fixture. If a writer silently drops content
 *  types — the original silent-drop bug produced a ~180-byte
 *  StreamHeader+EndOfStream-only output — this test fires.
 *
 *  <p>Wired against the {@code everything.tio} fixture that exercises
 *  every first-class v0.11 accessor at once. A second test method
 *  additionally asserts the {@code .tis} round-trips back to a
 *  {@code .tio} whose contents match the source across every
 *  {@link AccessorSpec} — the strongest coverage guarantee.</p>
 *
 *  <p><b>Absolute floor vs relative ratio:</b> earlier versions of
 *  this test used a {@code .tis > .tio / 100} ratio assertion. That
 *  was flaky across libhdf5 versions: CI's libhdf5 inflated
 *  {@code everything.tio} 75× vs the local build (8.4 MB vs 112 KB)
 *  via different metadata allocation, which dropped the ratio under
 *  the 1% floor even though the {@code .tis} content was correct.
 *  The 2 KiB absolute floor catches the silent-drop case (a stream
 *  carrying StreamHeader + EndOfStream is ~500 bytes, so 2 KiB is
 *  well above the empty-output baseline) without flaking on HDF5
 *  metadata weight.</p>
 */
class CoverageGapWatchdogTest {

    /** Empirical floor: a {@code .tis} carrying only StreamHeader +
     *  EndOfStream is ~500 bytes. The original silent-drop bug
     *  reported by users produced 180 bytes. 2 KiB sits well above
     *  the empty-output baseline while leaving headroom for HDF5
     *  metadata variation in the .tio size (which this test no
     *  longer compares against). */
    private static final long MIN_TIS_BYTES = 2_000L;

    @Test
    void tisIsAboveMinimumOnEverythingFixture(@TempDir Path tmp)
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
        assertTrue(tisSize > MIN_TIS_BYTES,
            "Coverage gap watchdog: .tis " + tisSize + " bytes <= "
            + MIN_TIS_BYTES + " byte floor (.tio = " + srcSize + " bytes) "
            + "— likely a writer is silently dropping a content type.");
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
                // Stage 5 (Task 5.6) accessors are intentionally not
                // populated by buildEverything: MS_IMAGE_PROCESSED is
                // a wire-mode override of the same MSImage already
                // covered by IMAGE; RAMAN_IMAGE / IR_IMAGE are
                // first-class siblings of MSImage on SpectralDataset
                // that the v0.11 everything fixture does not yet
                // include. The per-accessor conformance suite still
                // exercises all three.
                if (spec == AccessorSpec.MS_IMAGE_PROCESSED
                        || spec == AccessorSpec.RAMAN_IMAGE
                        || spec == AccessorSpec.IR_IMAGE) {
                    continue;
                }
                spec.assertContentEquals(a, b);
            }
        }
    }
}
