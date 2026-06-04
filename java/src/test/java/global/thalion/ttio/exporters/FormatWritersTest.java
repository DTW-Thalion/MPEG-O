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
import global.thalion.ttio.exporters.writers.BamWriterAdapter;
import global.thalion.ttio.exporters.writers.CramWriterAdapter;
import global.thalion.ttio.exporters.writers.ImzMLWriterAdapter;
import global.thalion.ttio.exporters.writers.IsaWriterAdapter;
import global.thalion.ttio.exporters.writers.JcampDxWriterAdapter;
import global.thalion.ttio.exporters.writers.MzMLWriterAdapter;
import global.thalion.ttio.exporters.writers.MzTabWriterAdapter;
import global.thalion.ttio.exporters.writers.NmrMLWriterAdapter;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * JT7: the eight per-format {@link Writer} adapters.
 *
 * <p>Each adapter mirrors the tio-browser GUI {@code ExportTask.exportX}
 * call and the merged Python {@code ttio.exporters.writers}. This test
 * asserts (a) all eight are constructible and {@code instanceof Writer},
 * and (b) a real end-to-end mzML write produces a non-empty file via the
 * uniform {@code Writer.write(ds, layer, output, opts)} entry point.</p>
 */
class FormatWritersTest {

    @TempDir
    Path tempDir;

    /** Minimal single-point MS run with the given name. */
    private static AcquisitionRun msRun(String name) {
        SpectrumIndex idx = new SpectrumIndex(1,
                new long[]{0}, new int[]{1},
                new double[]{0}, new int[]{1}, new int[]{1},
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
    void allEightAdaptersAreWriters() {
        assertInstanceOf(Writer.class, new MzMLWriterAdapter());
        assertInstanceOf(Writer.class, new MzTabWriterAdapter());
        assertInstanceOf(Writer.class, new NmrMLWriterAdapter());
        assertInstanceOf(Writer.class, new ImzMLWriterAdapter());
        assertInstanceOf(Writer.class, new JcampDxWriterAdapter());
        assertInstanceOf(Writer.class, new IsaWriterAdapter());
        assertInstanceOf(Writer.class, new BamWriterAdapter());
        assertInstanceOf(Writer.class, new CramWriterAdapter());
    }

    @Test
    void mzMLAdapterWritesNonEmptyFile() throws Exception {
        try (SpectralDataset ds = datasetWith("mzml_one", msRun("only_run"))) {
            Path out = tempDir.resolve("out.mzml");
            new MzMLWriterAdapter().write(ds, null, out, Map.of());
            assertTrue(Files.exists(out), "mzML output must exist");
            assertTrue(Files.size(out) > 0, "mzML output must be non-empty");
        }
    }
}
