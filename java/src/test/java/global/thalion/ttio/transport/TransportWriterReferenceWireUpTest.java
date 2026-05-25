package global.thalion.ttio.transport;

import global.thalion.ttio.SpectralDataset;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.*;

class TransportWriterReferenceWireUpTest {

    /** Regression for the silent-drop bug: writeDataset on a
     *  reference-only .tio must produce a .tis that ROUND-TRIPS
     *  back to a .tio with the same references. */
    @Test
    void writeDataset_round_trips_references_end_to_end(@TempDir Path tmp) throws Exception {
        Path src = FixtureBuilder.buildReferenceOnly(tmp.resolve("src.tio"));
        Path tis = tmp.resolve("src.tis");
        Path rt  = tmp.resolve("rt.tio");

        try (SpectralDataset ds = SpectralDataset.open(src.toString());
             OutputStream out = Files.newOutputStream(tis);
             TransportWriter w = new TransportWriter(out)) {
            w.writeDataset(ds);
        }

        // The reference-only .tio is ~22KB on disk (3 contigs, mostly
        // HDF5 metadata overhead). The .tis with references emitted
        // must be at least ~1KB -- the chr_medium contig is 1000 bytes
        // uncompressed (under the 4KB zlib threshold). The known silent-
        // drop baseline was ~190 bytes (StreamHeader + EndOfStream only).
        long srcSize = Files.size(src);
        long tisSize = Files.size(tis);
        assertTrue(tisSize > 1_000,
            "reference-only writeDataset produced only " + tisSize
            + " bytes; source was " + srcSize + " bytes -- silent drop?");

        try (TransportReader r = new TransportReader(Files.readAllBytes(tis));
             SpectralDataset materialised = r.materializeTo(rt.toString())) {
        }

        try (SpectralDataset a = SpectralDataset.open(src.toString());
             SpectralDataset b = SpectralDataset.open(rt.toString())) {
            AccessorSpec.REFERENCES.assertContentEquals(a, b);
        }
    }

    @Test
    void writeDataset_emits_v0_11_feature_flag_when_references_present(@TempDir Path tmp)
            throws Exception {
        Path src = FixtureBuilder.buildReferenceOnly(tmp.resolve("src.tio"));
        Path tis = tmp.resolve("src.tis");

        try (SpectralDataset ds = SpectralDataset.open(src.toString());
             OutputStream out = Files.newOutputStream(tis);
             TransportWriter w = new TransportWriter(out)) {
            w.writeDataset(ds);
        }

        // Read raw and inspect StreamHeader. The first packet is the
        // StreamHeader; its payload contains the features list which
        // includes the literal UTF-8 string "transport_v0_11".
        TransportReader r = new TransportReader(Files.readAllBytes(tis));
        var streamHeader = r.recordsForTest().get(0);
        boolean found = new String(streamHeader.payload, java.nio.charset.StandardCharsets.UTF_8)
            .contains("transport_v0_11");
        assertTrue(found, "StreamHeader must contain transport_v0_11 feature flag");
    }
}
