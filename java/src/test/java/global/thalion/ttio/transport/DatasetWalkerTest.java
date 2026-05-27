/*
 * TTI-O Java Implementation.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * Unit tests for DatasetWalker + AccessUnitVisitor.
 *
 * Cross-language equivalents:
 *   objc/Tests/TestDatasetWalker.m
 *   python/tests/test_dataset_walker.py
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.SpectrumIndex;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

class DatasetWalkerTest {

    private static SpectralDataset buildFixture(Path dir, String name) {
        int n = 5;
        int p = 3;
        double[] mz = new double[n * p];
        double[] intensity = new double[n * p];
        for (int i = 0; i < n * p; i++) {
            mz[i] = 100.0 + i;
            intensity[i] = 100.0 * (i + 1);
        }
        long[] offsets = {0, 3, 6, 9, 12};
        int[] lengths = {3, 3, 3, 3, 3};
        double[] rts = {1.0, 2.0, 3.0, 4.0, 5.0};
        int[] msLevels = {1, 2, 1, 2, 1};
        int[] pols = {1, 1, 1, 1, 1};
        double[] pmzs = {0.0, 510.0, 0.0, 530.0, 0.0};
        int[] pcs = {0, 2, 0, 2, 0};
        double[] bpis = new double[n];
        for (int i = 0; i < n; i++) {
            double best = 0;
            for (int k = 0; k < p; k++) best = Math.max(best, intensity[i * p + k]);
            bpis[i] = best;
        }
        SpectrumIndex idx = new SpectrumIndex(n, offsets, lengths, rts,
                msLevels, pols, pmzs, pcs, bpis);
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("mz", mz);
        channels.put("intensity", intensity);
        AcquisitionRun run = new AcquisitionRun("run_0001",
                Enums.AcquisitionMode.MS1_DDA, idx,
                new InstrumentConfig("", "", "", "", "", ""),
                channels, List.of(), List.of(), "", 0.0);
        Path ttio = dir.resolve(name);
        return SpectralDataset.create(ttio.toString(),
                "walker fixture", "ISA-WALKER",
                List.of(run), List.of(), List.of(), List.of());
    }

    /** Visitor that records every event. */
    private static final class Recording implements AccessUnitVisitor {
        final List<String> events = new ArrayList<>();
        final List<AccessUnit> aus = new ArrayList<>();

        @Override public void visitStreamHeader(DatasetWalker w, String fv,
                                                  String t, String isa,
                                                  List<String> f, int n) {
            events.add("stream:" + n);
        }
        @Override public void visitDatasetHeader(DatasetWalker w, int did,
                                                   String name, int am,
                                                   String sc, List<String> ch,
                                                   String j, int cnt) {
            events.add("dsh:" + did + "/" + name + "/" + cnt);
        }
        @Override public void visitAccessUnit(DatasetWalker w, AccessUnit au,
                                                int did, int seq) {
            aus.add(au);
            events.add("au:" + did + "/" + seq);
        }
        @Override public void visitEndOfDataset(DatasetWalker w, int did,
                                                  int finalSeq) {
            events.add("eod:" + did + "/" + finalSeq);
        }
        @Override public void visitEndOfStream(DatasetWalker w) {
            events.add("eos");
        }
    }

    /** Visitor that implements only the AU callback. */
    private static final class AUOnly implements AccessUnitVisitor {
        int auCount = 0;
        @Override public void visitAccessUnit(DatasetWalker w, AccessUnit au,
                                                int did, int seq) {
            auCount++;
        }
    }

    @Test
    void unfilteredWalkEmitsFullEventSequence(@TempDir Path dir) throws Exception {
        try (SpectralDataset src = buildFixture(dir, "src.tio")) { /* close */ }
        try (SpectralDataset ds = SpectralDataset.open(
                dir.resolve("src.tio").toString())) {
            Recording v = new Recording();
            new DatasetWalker().walk(ds, null, v);
            assertEquals(5, v.aus.size(),
                "unfiltered walk: 5 AccessUnits");
            assertTrue(v.events.get(0).startsWith("stream:"),
                "first event is StreamHeader");
            assertEquals("eos", v.events.get(v.events.size() - 1),
                "last event is EndOfStream");
            assertTrue(v.events.stream().anyMatch(e -> e.startsWith("dsh:")),
                "walk emits DatasetHeader");
            assertTrue(v.events.stream().anyMatch(e -> e.startsWith("eod:")),
                "walk emits EndOfDataset");
        }
    }

    @Test
    void msLevelFilterKeepsMatchingAUs(@TempDir Path dir) throws Exception {
        try (SpectralDataset src = buildFixture(dir, "src.tio")) { /* close */ }
        try (SpectralDataset ds = SpectralDataset.open(
                dir.resolve("src.tio").toString())) {
            AUFilter f = new AUFilter(
                /*rtMin*/ null, /*rtMax*/ null,
                /*msLevel*/ 1,
                /*precursorMzMin*/ null, /*precursorMzMax*/ null,
                /*polarity*/ null, /*datasetId*/ null,
                /*maxAu*/ null);
            Recording v = new Recording();
            new DatasetWalker().walk(ds, f, v);
            assertEquals(3, v.aus.size(),
                "ms_level=1 filter: 3 AUs (indexes 0,2,4)");
        }
    }

    @Test
    void maxAUCapHonoured(@TempDir Path dir) throws Exception {
        try (SpectralDataset src = buildFixture(dir, "src.tio")) { /* close */ }
        try (SpectralDataset ds = SpectralDataset.open(
                dir.resolve("src.tio").toString())) {
            AUFilter f = new AUFilter(
                null, null, null, null, null, null, null,
                /*maxAu*/ 2);
            Recording v = new Recording();
            new DatasetWalker().walk(ds, f, v);
            assertEquals(2, v.aus.size(),
                "max_au=2 cap: exactly 2 AUs");
        }
    }

    @Test
    void walkerReusableAcrossWalks(@TempDir Path dir) throws Exception {
        try (SpectralDataset src = buildFixture(dir, "src.tio")) { /* close */ }
        try (SpectralDataset ds = SpectralDataset.open(
                dir.resolve("src.tio").toString())) {
            DatasetWalker w = new DatasetWalker();
            Recording v1 = new Recording();
            Recording v2 = new Recording();
            w.walk(ds, null, v1);
            w.walk(ds, null, v2);
            assertEquals(v1.events, v2.events,
                "walker reusable: two walks → identical event sequences");
        }
    }

    @Test
    void auOnlyVisitorReceivesOnlyAUEvents(@TempDir Path dir) throws Exception {
        try (SpectralDataset src = buildFixture(dir, "src.tio")) { /* close */ }
        try (SpectralDataset ds = SpectralDataset.open(
                dir.resolve("src.tio").toString())) {
            AUOnly v = new AUOnly();
            new DatasetWalker().walk(ds, null, v);
            assertEquals(5, v.auCount,
                "AU-only visitor: 5 AU callbacks, other events skipped via defaults");
        }
    }

    // ── v0.11 §5.4 prelude parity (#141) ───────────────────────────

    /** Visitor that records every v0.11 prelude event in the order
     *  it sees the call. Captures the marker string AND a quick
     *  payload snapshot so tests can spot-check content alongside
     *  ordering. */
    private static final class V011Recording implements AccessUnitVisitor {
        final List<String> events = new ArrayList<>();
        String encryptionAlgorithm;
        int provenanceCount;
        int subjectsCount;
        int samplesCount;
        int referencesCount;
        boolean sawImage, sawRaman, sawIR;
        int identificationsCount;
        int quantificationsCount;
        final List<AccessUnit> aus = new ArrayList<>();

        @Override public void visitStreamHeader(DatasetWalker w, String fv,
                                                  String t, String isa,
                                                  List<String> f, int n) {
            events.add("stream:" + n);
        }
        @Override public void visitDatasetHeader(DatasetWalker w, int did,
                                                   String name, int am,
                                                   String sc, List<String> ch,
                                                   String j, int cnt) {
            events.add("dsh:" + did + "/" + name);
        }
        @Override public void visitAccessUnit(DatasetWalker w, AccessUnit au,
                                                int did, int seq) {
            aus.add(au);
            events.add("au:" + did + "/" + seq);
        }
        @Override public void visitEndOfDataset(DatasetWalker w, int did,
                                                  int finalSeq) {
            events.add("eod:" + did);
        }
        @Override public void visitEndOfStream(DatasetWalker w) {
            events.add("eos");
        }
        @Override public void visitEncryptionAlgorithm(DatasetWalker w,
                                                        String algorithm) {
            encryptionAlgorithm = algorithm;
            events.add("encryption");
        }
        @Override public void visitDatasetProvenance(DatasetWalker w,
                                                      List<global.thalion.ttio.ProvenanceRecord> records) {
            provenanceCount = records.size();
            events.add("provenance");
        }
        @Override public void visitSubjectMetadata(DatasetWalker w,
                                                     List<global.thalion.ttio.Subject> rows) {
            subjectsCount = rows.size();
            events.add("subjects");
        }
        @Override public void visitSampleMetadata(DatasetWalker w,
                                                    List<global.thalion.ttio.Sample> rows) {
            samplesCount = rows.size();
            events.add("samples");
        }
        @Override public void visitReferenceGroup(DatasetWalker w,
                                                    global.thalion.ttio.genomics.ReferenceImport reference) {
            referencesCount++;
            events.add("reference:" + reference.uri());
        }
        @Override public void visitImage(DatasetWalker w,
                                           global.thalion.ttio.MSImage image) {
            sawImage = true;
            events.add("image");
        }
        @Override public void visitRamanImage(DatasetWalker w,
                                                global.thalion.ttio.RamanImage image) {
            sawRaman = true;
            events.add("raman");
        }
        @Override public void visitIRImage(DatasetWalker w,
                                             global.thalion.ttio.IRImage image) {
            sawIR = true;
            events.add("ir");
        }
        @Override public void visitIdentificationsTable(DatasetWalker w,
                                                          List<global.thalion.ttio.Identification> rows) {
            identificationsCount = rows.size();
            events.add("identifications");
        }
        @Override public void visitQuantificationsTable(DatasetWalker w,
                                                          List<global.thalion.ttio.Quantification> rows) {
            quantificationsCount = rows.size();
            events.add("quantifications");
        }
    }

    @Test
    void walkerEmitsV011PreludeInSpecOrder(@TempDir Path dir) throws Exception {
        // FixtureBuilder.buildEverything covers all v0.11 accessors
        // EXCEPT Raman/IR images (which live only in the standalone
        // _only fixtures — same as the Python fixture builder).
        Path target = dir.resolve("everything.tio");
        FixtureBuilder.buildEverything(target);
        try (SpectralDataset ds = SpectralDataset.open(target.toString())) {
            V011Recording v = new V011Recording();
            new DatasetWalker().walk(ds, null, v);

            // Filter the v0.11 prelude window: everything between the
            // StreamHeader (events[0]) and the first DatasetHeader.
            int firstDsh = -1;
            for (int i = 0; i < v.events.size(); i++) {
                if (v.events.get(i).startsWith("dsh:")) {
                    firstDsh = i;
                    break;
                }
            }
            assertTrue(firstDsh > 0, "DatasetHeader must follow prelude");
            List<String> prelude = v.events.subList(1, firstDsh);
            // §5.4 ordering: ENCRYPTION → PROVENANCE → SUBJECTS →
            // SAMPLES → REFERENCES (1 in everything) → IMAGE → IDS →
            // QUANTS. Raman/IR are NOT in everything.
            assertEquals(List.of(
                "encryption",
                "provenance",
                "subjects",
                "samples",
                "reference:fixture-everything-v1",
                "image",
                "identifications",
                "quantifications"
            ), prelude, "v0.11 prelude order does not match §5.4");

            // Spot-check payloads — ensures the visitor saw real data
            // rather than placeholder calls.
            assertEquals("aes-256-gcm", v.encryptionAlgorithm);
            assertEquals(2, v.provenanceCount);
            assertEquals(2, v.subjectsCount);
            assertEquals(3, v.samplesCount);
            assertEquals(1, v.referencesCount);
            assertTrue(v.sawImage);
            assertFalse(v.sawRaman);
            assertFalse(v.sawIR);
            assertEquals(2, v.identificationsCount);
            assertEquals(2, v.quantificationsCount);
        }
    }

    @Test
    void walkerSkipsUnpopulatedPreludeEvents(@TempDir Path dir) throws Exception {
        // Bare MS-only fixture: NONE of the v0.11 prelude visitor
        // methods should be called.
        try (SpectralDataset src = buildFixture(dir, "src.tio")) { /* close */ }
        try (SpectralDataset ds = SpectralDataset.open(
                dir.resolve("src.tio").toString())) {
            V011Recording v = new V011Recording();
            new DatasetWalker().walk(ds, null, v);
            assertNull(v.encryptionAlgorithm);
            assertEquals(0, v.provenanceCount);
            assertEquals(0, v.subjectsCount);
            assertEquals(0, v.samplesCount);
            assertEquals(0, v.referencesCount);
            assertFalse(v.sawImage);
            assertFalse(v.sawRaman);
            assertFalse(v.sawIR);
            assertEquals(0, v.identificationsCount);
            assertEquals(0, v.quantificationsCount);
        }
    }

    @Test
    void walkerEmitsRamanAndIrImageEvents(@TempDir Path dir) throws Exception {
        Path ramanTarget = dir.resolve("raman.tio");
        FixtureBuilder.buildRamanImageOnly(ramanTarget);
        try (SpectralDataset ds = SpectralDataset.open(ramanTarget.toString())) {
            V011Recording v = new V011Recording();
            new DatasetWalker().walk(ds, null, v);
            assertTrue(v.sawRaman, "Raman fixture must trigger visitRamanImage");
            assertFalse(v.sawImage);
            assertFalse(v.sawIR);
        }

        Path irTarget = dir.resolve("ir.tio");
        FixtureBuilder.buildIrImageOnly(irTarget);
        try (SpectralDataset ds = SpectralDataset.open(irTarget.toString())) {
            V011Recording v = new V011Recording();
            new DatasetWalker().walk(ds, null, v);
            assertTrue(v.sawIR, "IR fixture must trigger visitIRImage");
            assertFalse(v.sawImage);
            assertFalse(v.sawRaman);
        }
    }

    @Test
    void walkerEmitsGenomicAccessUnits(@TempDir Path dir) throws Exception {
        Path target = dir.resolve("genomic.tio");
        FixtureBuilder.buildGenomicRunsOnly(target);
        try (SpectralDataset ds = SpectralDataset.open(target.toString())) {
            V011Recording v = new V011Recording();
            new DatasetWalker().walk(ds, null, v);
            // synthGenomicRun emits 4 reads.
            assertEquals(4, v.aus.size(),
                "genomic-only walk: one AccessUnit per read");
            // Each genomic AU has the 5-channel layout
            // (sequences, qualities, cigar, read_name, mate_chromosome).
            for (AccessUnit au : v.aus) {
                assertEquals(5, au.channels.size());
                assertEquals("sequences", au.channels.get(0).name);
                assertEquals("qualities", au.channels.get(1).name);
                assertEquals("cigar", au.channels.get(2).name);
                assertEquals("read_name", au.channels.get(3).name);
                assertEquals("mate_chromosome", au.channels.get(4).name);
                // GenomicRead wire class = 5.
                assertEquals(5, au.spectrumClass);
            }
        }
    }
}
