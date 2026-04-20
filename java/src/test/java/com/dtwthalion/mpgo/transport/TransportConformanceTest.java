/*
 * MPEG-O Java Implementation — v0.10 M70.
 * SPDX-License-Identifier: Apache-2.0
 */
package com.dtwthalion.mpgo.transport;

import com.dtwthalion.mpgo.AcquisitionRun;
import com.dtwthalion.mpgo.Enums;
import com.dtwthalion.mpgo.InstrumentConfig;
import com.dtwthalion.mpgo.MassSpectrum;
import com.dtwthalion.mpgo.SpectralDataset;
import com.dtwthalion.mpgo.Spectrum;
import com.dtwthalion.mpgo.SpectrumIndex;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * v0.10 M70: bidirectional conversion conformance (in-language).
 * .mpgo → .mots → .mpgo preserves every signal sample bit-for-bit.
 */
class TransportConformanceTest {

    private static SpectralDataset buildDataset(Path path, int nRuns,
                                                   int nSpectra, int pointsPerSpectrum) {
        List<AcquisitionRun> runs = new java.util.ArrayList<>();
        for (int r = 0; r < nRuns; r++) {
            int total = nSpectra * pointsPerSpectrum;
            double[] mz = new double[total];
            double[] intensity = new double[total];
            for (int i = 0; i < total; i++) {
                mz[i] = 100.0 * (r + 1) + i;
                intensity[i] = 100.0 * (r + 1) * (i + 1);
            }
            long[] offsets = new long[nSpectra];
            int[] lengths = new int[nSpectra];
            for (int i = 0; i < nSpectra; i++) {
                offsets[i] = (long) i * pointsPerSpectrum;
                lengths[i] = pointsPerSpectrum;
            }
            double[] rts = new double[nSpectra];
            for (int i = 0; i < nSpectra; i++) rts[i] = 1.0 + i;
            int[] msLevels = new int[nSpectra];
            int[] pols = new int[nSpectra];
            double[] pmzs = new double[nSpectra];
            int[] pcs = new int[nSpectra];
            double[] bpis = new double[nSpectra];
            for (int i = 0; i < nSpectra; i++) {
                msLevels[i] = (i % 2 == 0) ? 1 : 2;
                pols[i] = 1;
                pmzs[i] = msLevels[i] == 1 ? 0.0 : 500.0 + i;
                pcs[i] = msLevels[i] == 1 ? 0 : 2;
                double best = 0;
                for (int k = 0; k < pointsPerSpectrum; k++) {
                    best = Math.max(best, intensity[i * pointsPerSpectrum + k]);
                }
                bpis[i] = best;
            }
            SpectrumIndex idx = new SpectrumIndex(nSpectra, offsets, lengths, rts,
                    msLevels, pols, pmzs, pcs, bpis);
            Map<String, double[]> channels = new LinkedHashMap<>();
            channels.put("mz", mz);
            channels.put("intensity", intensity);
            runs.add(new AcquisitionRun(
                    String.format("run_%04d", r),
                    Enums.AcquisitionMode.MS1_DDA, idx,
                    new InstrumentConfig("", "", "", "", "", ""),
                    channels, List.of(), List.of(), "", 0.0));
        }
        return SpectralDataset.create(path.toString(),
                "M70 Java conformance", "ISA-M70-JAVA",
                runs, List.of(), List.of(), List.of());
    }

    private static void assertSignalEqual(SpectralDataset a, SpectralDataset b) {
        assertEquals(a.msRuns().keySet(), b.msRuns().keySet());
        for (String name : a.msRuns().keySet()) {
            AcquisitionRun ra = a.msRuns().get(name);
            AcquisitionRun rb = b.msRuns().get(name);
            assertEquals(ra.spectrumCount(), rb.spectrumCount(), "run " + name);
            for (int i = 0; i < ra.spectrumCount(); i++) {
                Spectrum sa = ra.objectAtIndex(i);
                Spectrum sb = rb.objectAtIndex(i);
                assertEquals(sa.scanTimeSeconds(), sb.scanTimeSeconds(), 1e-12);
                assertEquals(sa.precursorMz(), sb.precursorMz(), 1e-12);
                if (sa instanceof MassSpectrum ma && sb instanceof MassSpectrum mb) {
                    assertArrayEquals(ma.mzValues(), mb.mzValues(),
                            "mz mismatch at " + name + "/" + i);
                    assertArrayEquals(ma.intensityValues(), mb.intensityValues(),
                            "intensity mismatch at " + name + "/" + i);
                }
            }
        }
    }

    @Test
    void singleRunRoundTrip(@TempDir Path dir) throws Exception {
        try (SpectralDataset src = buildDataset(dir.resolve("src.mpgo"), 1, 5, 4)) {
            // close to flush
        }
        Path mots = dir.resolve("stream.mots");
        Path rt = dir.resolve("rt.mpgo");
        try (SpectralDataset src = SpectralDataset.open(dir.resolve("src.mpgo").toString());
             TransportWriter tw = new TransportWriter(mots)) {
            tw.writeDataset(src);
        }
        try (TransportReader tr = new TransportReader(mots);
             SpectralDataset rtDs = tr.materializeTo(rt.toString());
             SpectralDataset src = SpectralDataset.open(dir.resolve("src.mpgo").toString())) {
            assertSignalEqual(src, rtDs);
        }
    }

    @Test
    void multiRunRoundTrip(@TempDir Path dir) throws Exception {
        try (SpectralDataset src = buildDataset(dir.resolve("src.mpgo"), 3, 4, 5)) {
            // close
        }
        Path mots = dir.resolve("stream.mots");
        Path rt = dir.resolve("rt.mpgo");
        try (SpectralDataset src = SpectralDataset.open(dir.resolve("src.mpgo").toString());
             TransportWriter tw = new TransportWriter(mots)) {
            tw.writeDataset(src);
        }
        try (TransportReader tr = new TransportReader(mots);
             SpectralDataset rtDs = tr.materializeTo(rt.toString());
             SpectralDataset src = SpectralDataset.open(dir.resolve("src.mpgo").toString())) {
            assertSignalEqual(src, rtDs);
        }
    }

    @Test
    void largerSpectraRoundTrip(@TempDir Path dir) throws Exception {
        try (SpectralDataset src = buildDataset(dir.resolve("src.mpgo"), 1, 20, 128)) {
            // close
        }
        Path mots = dir.resolve("stream.mots");
        Path rt = dir.resolve("rt.mpgo");
        try (SpectralDataset src = SpectralDataset.open(dir.resolve("src.mpgo").toString());
             TransportWriter tw = new TransportWriter(mots)) {
            tw.writeDataset(src);
        }
        try (TransportReader tr = new TransportReader(mots);
             SpectralDataset rtDs = tr.materializeTo(rt.toString());
             SpectralDataset src = SpectralDataset.open(dir.resolve("src.mpgo").toString())) {
            assertSignalEqual(src, rtDs);
        }
    }

    @Test
    void checksumRoundTrip(@TempDir Path dir) throws Exception {
        try (SpectralDataset src = buildDataset(dir.resolve("src.mpgo"), 1, 5, 4)) {
            // close
        }
        Path mots = dir.resolve("stream.mots");
        Path rt = dir.resolve("rt.mpgo");
        try (SpectralDataset src = SpectralDataset.open(dir.resolve("src.mpgo").toString());
             TransportWriter tw = new TransportWriter(mots)) {
            tw.setUseChecksum(true);
            tw.writeDataset(src);
        }
        try (TransportReader tr = new TransportReader(mots);
             SpectralDataset rtDs = tr.materializeTo(rt.toString());
             SpectralDataset src = SpectralDataset.open(dir.resolve("src.mpgo").toString())) {
            assertSignalEqual(src, rtDs);
        }
    }
}
