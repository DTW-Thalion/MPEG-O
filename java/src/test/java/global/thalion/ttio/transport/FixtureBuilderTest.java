/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.SpectralDataset;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Self-test for {@link FixtureBuilder}.
 *
 * <p>This is intentionally minimal — the real coverage of the
 * fixtures lives in the per-accessor conformance tests that consume
 * them. This class only confirms each {@code build...} method
 * produces a re-openable {@code .tio} whose top-level shape matches
 * what the builder advertises.</p>
 */
class FixtureBuilderTest {

    @Test
    void buildReferenceOnly_has_single_ref_with_three_contigs(@TempDir Path tmp)
            throws Exception {
        Path out = FixtureBuilder.buildReferenceOnly(tmp.resolve("ref.tio"));
        try (SpectralDataset ds = SpectralDataset.open(out.toString())) {
            assertEquals(1, ds.references().size(),
                "fixture must hold exactly one embedded reference");
            assertEquals(3, ds.references().values().iterator().next()
                .chromosomes().size(),
                "the reference must hold exactly three contigs");
            assertTrue(ds.msRuns().isEmpty(),
                "reference-only fixture must carry no MS runs");
            assertTrue(ds.genomicRuns().isEmpty(),
                "reference-only fixture must carry no genomic runs");
        }
    }
}
