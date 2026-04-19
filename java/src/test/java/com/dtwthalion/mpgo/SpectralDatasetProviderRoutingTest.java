/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import com.dtwthalion.mpgo.Enums.AcquisitionMode;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/**
 * v0.9 M64.5 (Java) — SpectralDataset URL-scheme dispatch.
 *
 * Mirrors Python's tests/integration/test_mzml_roundtrip.py provider
 * matrix at the Java dataset layer: write an .mpgo through each
 * supported provider (via URL scheme on {@link SpectralDataset#create}),
 * then re-open through the same URL and assert the summary round-trips.
 */
final class SpectralDatasetProviderRoutingTest {

    private static AcquisitionRun makeRun() {
        int n = 3, peaks = 4;
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        double[] rts = new double[n];
        int[] mls = new int[n];
        int[] pols = new int[n];
        double[] pmzs = new double[n];
        int[] pcs = new int[n];
        double[] bps = new double[n];
        for (int i = 0; i < n; i++) {
            offsets[i] = (long) i * peaks;
            lengths[i] = peaks;
            rts[i] = i;
            mls[i] = 1;
            pols[i] = 1;
            pmzs[i] = 0.0;
            pcs[i] = 0;
            bps[i] = 10.0;
        }
        SpectrumIndex idx = new SpectrumIndex(n, offsets, lengths, rts, mls, pols, pmzs, pcs, bps);

        Map<String, double[]> channels = new LinkedHashMap<>();
        double[] mz = new double[n * peaks];
        double[] intensity = new double[n * peaks];
        for (int i = 0; i < n; i++) {
            for (int j = 0; j < peaks; j++) {
                int pos = i * peaks + j;
                mz[pos] = 100.0 + j;
                intensity[pos] = 1.0 + j;
            }
        }
        channels.put("mz", mz);
        channels.put("intensity", intensity);
        return new AcquisitionRun("run_0001", AcquisitionMode.MS1_DDA,
                idx, null, channels, List.of(), List.of(), null, 0);
    }

    private static String urlFor(String provider, Path tmp) {
        switch (provider) {
            case "hdf5":
                return tmp.resolve("routing.mpgo").toString();
            case "memory":
                return "memory://routing-" + UUID.randomUUID();
            case "sqlite":
                return "sqlite://" + tmp.resolve("routing.sqlite");
            case "zarr":
                return "zarr://" + tmp.resolve("routing.zarr");
            default:
                throw new IllegalArgumentException(provider);
        }
    }

    @ParameterizedTest
    @ValueSource(strings = {"hdf5", "memory", "sqlite", "zarr"})
    void roundTripThroughEachProvider(String provider, @TempDir Path tmp) throws Exception {
        String url = urlFor(provider, tmp);
        AcquisitionRun run = makeRun();
        List<Identification> ids = List.of(
                new Identification("run_0001", 0, "P12345", 0.95, List.of("engine-A")),
                new Identification("run_0001", 2, "P67890", 0.81, List.of("engine-B"))
        );

        try (SpectralDataset ds = SpectralDataset.create(
                url, "routing-" + provider, "ISA-ROUTE",
                List.of(run), ids, List.of(), List.of())) {
            assertEquals("routing-" + provider, ds.title());
        }

        try (SpectralDataset ds = SpectralDataset.open(url)) {
            assertEquals("routing-" + provider, ds.title());
            assertEquals("ISA-ROUTE", ds.isaInvestigationId());
            AcquisitionRun re = ds.msRuns().get("run_0001");
            assertNotNull(re, "run_0001 must be visible after provider re-open");
            assertEquals(3, re.spectrumCount());
            List<Identification> got = ds.identifications();
            assertEquals(2, got.size());
            assertEquals("P12345", got.get(0).chemicalEntity());
            assertEquals(0.95, got.get(0).confidenceScore(), 1e-9);
        }
    }
}
