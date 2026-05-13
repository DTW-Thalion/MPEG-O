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
            AUFilter f = new AUFilter();
            f.msLevel = 1;
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
            AUFilter f = new AUFilter();
            f.maxAu = 2;
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
}
