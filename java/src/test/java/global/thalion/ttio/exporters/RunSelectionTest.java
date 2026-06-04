/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.exporters;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.SpectrumIndex;
import global.thalion.ttio.Enums.AcquisitionMode;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * JT4: unit tests for the shared {@link RunSelection} export helpers.
 *
 * <p>Mirrors the Python reference {@code ttio.exporters._select}
 * (functions {@code analytical_run} / {@code nmr_run} /
 * {@code genomic_run}) for selection behaviour and error-message
 * text, so cross-language error parity holds.</p>
 *
 * <p>Java structural note: {@link SpectralDataset} exposes a single
 * analytical-run map via {@link SpectralDataset#msRuns()} (there is no
 * separate {@code nmrRuns()} accessor); NMR runs live inside that map
 * and are distinguished by
 * {@code AcquisitionRun.spectrumClassName().equals("TTIONMRSpectrum")}.
 * The genomic-run case is exercised end-to-end by JT7's writer tests;
 * here we cover analytical selection + the ambiguity / sole-run
 * branches.</p>
 */
class RunSelectionTest {

    @TempDir
    Path tempDir;

    /** Minimal single-point MS run with the given name. */
    private static AcquisitionRun msRun(String name) {
        SpectrumIndex idx = new SpectrumIndex(1,
                new long[]{0}, new int[]{1},
                new double[]{0}, new int[]{0}, new int[]{0},
                new double[]{0}, new int[]{0}, new double[]{1000});
        Map<String, double[]> ch = new LinkedHashMap<>();
        ch.put("mz", new double[]{100});
        ch.put("intensity", new double[]{1});
        return new AcquisitionRun(name, AcquisitionMode.MS1_DDA,
                idx, null, ch, List.of(), List.of(), null, 0);
    }

    /** Build, persist, and reopen a .tio holding the given runs. */
    private SpectralDataset datasetWith(String tag, AcquisitionRun... runs) {
        String path = tempDir.resolve(tag + ".tio").toString();
        try (SpectralDataset ds = SpectralDataset.create(path, tag, "ISA-" + tag,
                List.of(runs), List.of(), List.of(), List.of())) {
            assertNotNull(ds);
        }
        return SpectralDataset.open(path);
    }

    @Test
    void analyticalRunByLayerNameReturnsThatRun() {
        try (SpectralDataset ds =
                 datasetWith("by_name", msRun("run_a"), msRun("run_b"))) {
            AcquisitionRun picked = RunSelection.analyticalRun(ds, "run_b");
            assertEquals("run_b", picked.name(),
                "layer name must select the matching analytical run");
        }
    }

    @Test
    void analyticalRunAmbiguousWithoutLayerThrows() {
        try (SpectralDataset ds =
                 datasetWith("ambig", msRun("run_a"), msRun("run_b"))) {
            IllegalArgumentException ex = assertThrows(
                IllegalArgumentException.class,
                () -> RunSelection.analyticalRun(ds, null));
            assertEquals("multiple runs present; pass --layer <name>",
                ex.getMessage(),
                "ambiguity message must mirror Python's analytical_run text");
        }
    }

    @Test
    void analyticalRunSoleRunWithoutLayerReturnsIt() {
        try (SpectralDataset ds = datasetWith("sole", msRun("only_run"))) {
            AcquisitionRun picked = RunSelection.analyticalRun(ds, null);
            assertEquals("only_run", picked.name(),
                "the single run is returned when no layer is given");
        }
    }

    @Test
    void analyticalRunUnknownLayerThrowsWithAvailableNames() {
        try (SpectralDataset ds =
                 datasetWith("unknown", msRun("run_a"), msRun("run_b"))) {
            IllegalArgumentException ex = assertThrows(
                IllegalArgumentException.class,
                () -> RunSelection.analyticalRun(ds, "nope"));
            assertEquals("run 'nope' not found; have: run_a, run_b",
                ex.getMessage(),
                "not-found message must mirror Python's wording + sorted names");
        }
    }

    @Test
    void analyticalRunEmptyDatasetThrows() {
        try (SpectralDataset ds = datasetWith("empty")) {
            IllegalArgumentException ex = assertThrows(
                IllegalArgumentException.class,
                () -> RunSelection.analyticalRun(ds, null));
            assertEquals("no analytical runs in dataset", ex.getMessage());
        }
    }
}
