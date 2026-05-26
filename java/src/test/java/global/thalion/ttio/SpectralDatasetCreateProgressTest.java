/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.io.ProgressSink;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Stage D per-section {@link ProgressSink} wiring for
 * {@link SpectralDataset#create}.
 *
 * <p>Verifies that the new ProgressSink-accepting overload fires
 * one progress sample per §5.4 section as the writer iterates the
 * accessor list, with a sectionTotal that reflects only sections
 * actually written (empty collections are skipped).</p>
 */
class SpectralDatasetCreateProgressTest {

    private static AcquisitionRun synthRun(String name) {
        SpectrumIndex idx = new SpectrumIndex(
            1, new long[]{0L}, new int[]{1},
            new double[]{0.1}, new int[]{1}, new int[]{1},
            new double[]{0.0}, new int[]{0}, new double[]{0.0});
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("mz", new double[]{100.0});
        channels.put("intensity", new double[]{1000.0});
        InstrumentConfig cfg = new InstrumentConfig(
            "vendor", "model", "sn", "ESI", "QTOF", "MCP");
        return new AcquisitionRun(
            name, AcquisitionMode.MS1_DDA, idx, cfg, channels,
            List.of(), List.of(), null, 0.0);
    }

    @Test
    void create_fires_per_section_for_spectral_only(@TempDir Path tmp) {
        Path out = tmp.resolve("spectral.tio");

        AtomicInteger count = new AtomicInteger();
        AtomicLong lastDone = new AtomicLong(-1);
        AtomicLong lastTotal = new AtomicLong(-1);
        List<Long> dones = new ArrayList<>();
        ProgressSink sink = (done, total) -> {
            count.incrementAndGet();
            dones.add(done);
            lastDone.set(done);
            lastTotal.set(total);
        };

        try (SpectralDataset ds = SpectralDataset.create(
                out.toString(), "spectral-only-test", "",
                List.of(synthRun("run1")),
                List.of(), List.of(), List.of(),
                sink)) {
            assertEquals(1, ds.msRuns().size());
        }
        // 1 active section (ms_runs) => 1 baseline + 1 section fire = 2 callbacks.
        assertTrue(count.get() >= 2,
            "expected >=2 callbacks for spectral-only (baseline + ms_runs), got "
                + count.get());
        // Total reflects ONLY sections actually written.
        assertEquals(1L, lastTotal.get(),
            "spectral-only run with no idents/quants/provenance should "
                + "report sectionTotal == 1 (ms_runs only)");
        assertEquals(1L, lastDone.get(),
            "final done == total after ms_runs section completes");
    }

    @Test
    void create_baseline_fires_with_zero_done(@TempDir Path tmp) {
        Path out = tmp.resolve("baseline.tio");
        List<Long> dones = new ArrayList<>();
        List<Long> totals = new ArrayList<>();
        ProgressSink sink = (done, total) -> {
            dones.add(done);
            totals.add(total);
        };
        try (SpectralDataset ds = SpectralDataset.create(
                out.toString(), "baseline-test", "",
                List.of(synthRun("run1")),
                List.of(), List.of(), List.of(),
                sink)) {
        }
        assertEquals(0L, dones.get(0),
            "first callback should report (0, total) baseline");
        assertEquals(1L, totals.get(0),
            "baseline total should match active-section count");
    }

    @Test
    void create_fires_per_section_with_provenance(@TempDir Path tmp) {
        Path out = tmp.resolve("withprov.tio");
        List<Long> dones = new ArrayList<>();
        AtomicLong lastTotal = new AtomicLong(-1);
        ProgressSink sink = (done, total) -> {
            dones.add(done);
            lastTotal.set(total);
        };

        List<ProvenanceRecord> prov = List.of(
            new ProvenanceRecord(
                System.currentTimeMillis() / 1000L,
                "ttio",
                Map.of("CL", "ttio export"),
                List.of(),
                List.of()));

        try (SpectralDataset ds = SpectralDataset.create(
                out.toString(), "withprov-test", "",
                List.of(synthRun("run1")),
                List.of(), List.of(), prov,
                sink)) {
            assertEquals(1, ds.provenanceRecords().size());
        }
        // 2 sections (ms_runs + provenance) => 1 baseline + 2 section fires.
        assertEquals(2L, lastTotal.get(),
            "ms_runs + provenance => sectionTotal == 2");
        assertTrue(dones.contains(2L),
            "expected a final (2, 2) callback; saw " + dones);
    }

    @Test
    void create_default_overload_uses_discard_sink(@TempDir Path tmp) {
        Path out = tmp.resolve("nosink.tio");
        // No-sink overload, must not throw.
        try (SpectralDataset ds = SpectralDataset.create(
                out.toString(), "nosink", "",
                List.of(synthRun("run1")),
                List.of(), List.of(), List.of())) {
            assertEquals(1, ds.msRuns().size());
        }
    }
}
