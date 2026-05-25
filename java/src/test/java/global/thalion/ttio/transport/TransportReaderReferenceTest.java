/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.genomics.ReferenceImport;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Stage 1 / Task 1.3 (transport-spec v0.11): exercise
 * {@link TransportReader#materializeTo(String)} on a stream that
 * contains only REFERENCE_GROUP_HEADER (0x10) + REFERENCE_CHROMOSOME
 * (0x11) + END_OF_REFERENCE_GROUP (0x12) packets and verify the
 * decoded {@link ReferenceImport} round-trips byte-for-byte through
 * the materialised {@link SpectralDataset}.
 */
class TransportReaderReferenceTest {

    @Test
    void referenceGroup_round_trips_through_writer_and_reader(@TempDir Path tmp) throws Exception {
        // FixtureBuilder.buildReferenceOnly produces a .tio carrying a
        // single ReferenceImport with three contigs (chr_long / chr_medium
        // / chr_short). No MS / genomic runs, no identifications, no
        // quants, no provenance — perfect for an isolated references
        // round-trip.
        Path src = FixtureBuilder.buildReferenceOnly(tmp.resolve("src.tio"));
        Path tis = tmp.resolve("src.tis");
        Path rt  = tmp.resolve("rt.tio");

        // Encode: .tio → .tis (only the reference group; no MS / genomic AUs).
        try (SpectralDataset ds = SpectralDataset.open(src.toString());
             OutputStream out = Files.newOutputStream(tis);
             TransportWriter w = new TransportWriter(out)) {
            w.writeStreamHeader("1.2", ds.title(), ds.isaInvestigationId(),
                List.of(), 0);
            for (ReferenceImport ref : ds.references().values()) {
                w.writeReferenceGroup(ref);
            }
            w.writeEndOfStream();
        }

        // Decode: .tis → .tio.
        try (TransportReader r = new TransportReader(Files.readAllBytes(tis));
             SpectralDataset materialised = r.materializeTo(rt.toString())) {
            // Close immediately so the file is flushed to disk.
        }

        // Re-open both and compare via the accessor's matcher.
        try (SpectralDataset a = SpectralDataset.open(src.toString());
             SpectralDataset b = SpectralDataset.open(rt.toString())) {
            AccessorSpec.REFERENCES.assertContentEquals(a, b);
        }
    }
}
