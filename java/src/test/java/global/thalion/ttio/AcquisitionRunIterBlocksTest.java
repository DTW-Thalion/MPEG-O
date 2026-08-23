/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.providers.ProviderRegistry;
import global.thalion.ttio.providers.StorageGroup;
import global.thalion.ttio.providers.StorageProvider;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

import static org.junit.jupiter.api.Assertions.*;

/** {@link AcquisitionRun#iterBlocks}, the spectral parallel block
 *  consumer. Parity with Python {@code AcquisitionRun.for_each_block}
 *  and Objective-C
 *  {@code -iterBlocksFrom:to:threads:error:usingBlock:}. */
class AcquisitionRunIterBlocksTest {

    private static final int N_SPEC = 600;
    // The FDZ1 block is 2**20 values and is not configurable, so the
    // corpus is sized past it on purpose: 600 x 2000 is 1200000 values
    // per channel, which is 2 blocks. A smaller corpus is one block and
    // never crosses a unit boundary.
    private static final int N_PTS = 2000;

    /** m/z value j of spectrum i is 1000*i + j, so a spectrum's content
     *  names the spectrum and no assertion needs a derived index. */
    private static AcquisitionRun synthetic() {
        long[] offsets = new long[N_SPEC];
        int[] lengths = new int[N_SPEC];
        double[] mz = new double[N_SPEC * N_PTS];
        double[] intensity = new double[N_SPEC * N_PTS];
        double[] rt = new double[N_SPEC];
        int[] msLevels = new int[N_SPEC], polarities = new int[N_SPEC];
        int[] charges = new int[N_SPEC];
        double[] precursors = new double[N_SPEC], basePeaks = new double[N_SPEC];
        for (int i = 0; i < N_SPEC; i++) {
            offsets[i] = (long) i * N_PTS;
            lengths[i] = N_PTS;
            rt[i] = i;
            msLevels[i] = 1;
            polarities[i] = 1;
            basePeaks[i] = 100.0;
            for (int j = 0; j < N_PTS; j++) {
                mz[i * N_PTS + j] = 1000.0 * i + j;
                intensity[i * N_PTS + j] = (i * 7 + j) % 977;
            }
        }
        SpectrumIndex idx = new SpectrumIndex(N_SPEC, offsets, lengths, rt,
                msLevels, polarities, precursors, charges, basePeaks);
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("mz", mz);
        channels.put("intensity", intensity);
        return new AcquisitionRun("run_0001", Enums.AcquisitionMode.MS1_DDA, idx,
                new InstrumentConfig("", "", "", "", "", ""), channels,
                Collections.emptyList(), Collections.emptyList(), "", 0.0);
    }

    private static Path write(Path tmp, AcquisitionRun run) {
        Path out = tmp.resolve("sib.tio");
        try (StorageProvider p = ProviderRegistry.open(out.toString(),
                StorageProvider.Mode.CREATE, "hdf5")) {
            StorageGroup study = p.rootGroup().createGroup("study");
            StorageGroup ms = study.createGroup("ms_runs");
            ms.setAttribute("_run_names", run.name());
            run.writeTo(ms);
        }
        return out;
    }

    private static AcquisitionRun open(Path p) {
        StorageProvider prov = ProviderRegistry.open(p.toString(),
                StorageProvider.Mode.READ, "hdf5");
        return AcquisitionRun.readFrom(
                prov.rootGroup().openGroup("study").openGroup("ms_runs"), "run_0001");
    }

    /** m/z[0] per run index, gathered through iterBlocks. */
    private static Map<Integer, Double> collect(AcquisitionRun run, int from, int to,
                                                int threads, List<Integer> unitsOut) {
        Map<Integer, Double> got = new ConcurrentHashMap<>();
        List<Integer> units = Collections.synchronizedList(new ArrayList<>());
        run.iterBlocks(from, to, threads, (view, viewStart, firstSpectrum, nSpectra) -> {
            for (int k = 0; k < nSpectra; k++) {
                MassSpectrum sp = (MassSpectrum) view.objectAtIndex(viewStart + k);
                got.put(firstSpectrum + k, sp.mzValues()[0]);
            }
            units.add(nSpectra);
        });
        if (unitsOut != null) unitsOut.addAll(units);
        return got;
    }

    @Test
    void theCorpusSpansSeveralUnits(@TempDir Path tmp) {
        AcquisitionRun run = open(write(tmp, synthetic()));
        List<Integer> units = new ArrayList<>();
        collect(run, 0, N_SPEC, 1, units);
        // Without this the suite is a false green: a single-unit corpus
        // passes every assertion below without crossing a boundary.
        assertTrue(units.size() >= 2,
                "corpus planned " + units.size() + " unit(s); a boundary is never crossed");
    }

    @Test
    void everySpectrumCarriesItsOwnContent(@TempDir Path tmp) {
        AcquisitionRun run = open(write(tmp, synthetic()));
        for (int threads : new int[] {1, 2, 4, 8}) {
            Map<Integer, Double> got = collect(run, 0, N_SPEC, threads, null);
            assertEquals(N_SPEC, got.size(), "threads=" + threads);
            for (int i = 0; i < N_SPEC; i++) {
                assertEquals(1000.0 * i, got.get(i), 1e-9,
                        "threads=" + threads + " spectrum " + i);
            }
        }
    }

    @Test
    void aRangeStartingPartWayInReportsRunGlobalIndices(@TempDir Path tmp) {
        // The shape that returned the wrong records on the genomic side.
        AcquisitionRun run = open(write(tmp, synthetic()));
        final int lo = 37, hi = 461;
        Map<Integer, Double> got = collect(run, lo, hi, 4, null);
        assertEquals(hi - lo, got.size());
        for (int i = lo; i < hi; i++) {
            assertEquals(1000.0 * i, got.get(i), 1e-9, "spectrum " + i);
        }
    }

    @Test
    void matchesObjectAtIndex(@TempDir Path tmp) {
        AcquisitionRun run = open(write(tmp, synthetic()));
        Map<Integer, Double> got = collect(run, 0, N_SPEC, 4, null);
        for (int i = 0; i < N_SPEC; i++) {
            MassSpectrum sp = (MassSpectrum) run.objectAtIndex(i);
            assertEquals(sp.mzValues()[0], got.get(i), 0.0, "spectrum " + i);
        }
    }

    @Test
    void anEmptyRangeVisitsNothing(@TempDir Path tmp) {
        AcquisitionRun run = open(write(tmp, synthetic()));
        List<Integer> units = new ArrayList<>();
        collect(run, 5, 5, 4, units);
        assertTrue(units.isEmpty());
    }
}
