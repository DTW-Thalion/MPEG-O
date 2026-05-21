/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Java parity for the vibrational {@code .tio} round-trip (parity-audit
 * v1.0 §3.1): an AcquisitionRun tagged IR / Raman / UV-Vis writes its
 * per-class metadata as run-group attributes and materializes back into
 * the right Spectrum subclass. The run-attribute contract matches the
 * Python writer/reader so a Python-written vibrational {@code .tio} reads
 * here too.
 */
class JcampVibrationalRoundTripTest {

    private static SpectrumIndex oneSpectrum(int n, double basePeak) {
        return new SpectrumIndex(1,
            new long[]{0}, new int[]{n},
            new double[]{0.0}, new int[]{0}, new int[]{0},
            new double[]{0.0}, new int[]{0},
            new double[]{basePeak});
    }

    private static AcquisitionRun run(String spectrumClassChannels,
                                      double[] x, double[] y,
                                      String xChannel, String yChannel) {
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put(xChannel, x);
        channels.put(yChannel, y);
        double bp = 0.0;
        for (double v : y) bp = Math.max(bp, v);
        return new AcquisitionRun("run_0001", Enums.AcquisitionMode.MS1_DDA,
            oneSpectrum(x.length, bp),
            new InstrumentConfig("", "", "", "", "", ""),
            channels, List.of(), List.of(), null, 0.0);
    }

    private static Spectrum firstSpectrum(String path) {
        try (SpectralDataset ds = SpectralDataset.open(path)) {
            AcquisitionRun r = ds.msRuns().values().iterator().next();
            List<Spectrum> spectra = r.spectra();
            assertFalse(spectra.isEmpty(), "run materialized no spectra");
            return spectra.get(0);
        }
    }

    @Test
    void irRoundTrip(@TempDir Path tmp) {
        double[] x = {400, 800, 1200, 1600, 2000, 2400};
        double[] y = {0.1, 0.5, 0.2, 0.9, 0.3, 0.7};
        AcquisitionRun run = run("ir", x, y, "wavenumber", "intensity");
        run.setIRMetadata(Enums.IRMode.ABSORBANCE, 4.0, 32);

        String p = tmp.resolve("ir.tio").toString();
        try (SpectralDataset ds = SpectralDataset.create(p, "ir", "ISA-IR",
                List.of(run), List.of(), List.of(), List.of())) { }

        Spectrum s = firstSpectrum(p);
        assertInstanceOf(IRSpectrum.class, s);
        IRSpectrum ir = (IRSpectrum) s;
        assertEquals(Enums.IRMode.ABSORBANCE, ir.mode());
        assertEquals(4.0, ir.resolutionCmInv());
        assertEquals(32L, ir.numberOfScans());
        assertArrayEquals(x, ir.wavenumberValues());
        assertArrayEquals(y, ir.intensityValues());
    }

    @Test
    void ramanRoundTrip(@TempDir Path tmp) {
        double[] x = {200, 700, 1200, 1700, 2200, 2700};
        double[] y = {0.05, 0.4, 0.6, 0.2, 0.8, 0.1};
        AcquisitionRun run = run("raman", x, y, "wavenumber", "intensity");
        run.setRamanMetadata(785.0, 10.0, 2.5);

        String p = tmp.resolve("raman.tio").toString();
        try (SpectralDataset ds = SpectralDataset.create(p, "rm", "ISA-RM",
                List.of(run), List.of(), List.of(), List.of())) { }

        Spectrum s = firstSpectrum(p);
        assertInstanceOf(RamanSpectrum.class, s);
        RamanSpectrum rm = (RamanSpectrum) s;
        assertEquals(785.0, rm.excitationWavelengthNm());
        assertEquals(10.0, rm.laserPowerMw());
        assertEquals(2.5, rm.integrationTimeSec());
        assertArrayEquals(x, rm.wavenumberValues());
        assertArrayEquals(y, rm.intensityValues());
    }

    @Test
    void uvVisRoundTrip(@TempDir Path tmp) {
        double[] x = {200, 320, 440, 560, 680, 800};
        double[] y = {0.9, 0.7, 0.5, 0.3, 0.2, 0.1};
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("wavelength", x);
        channels.put("absorbance", y);
        // UV-Vis solvent rides the run's solvent field (full constructor).
        AcquisitionRun run = new AcquisitionRun("run_0001",
            Enums.AcquisitionMode.MS1_DDA, oneSpectrum(x.length, 0.9),
            new InstrumentConfig("", "", "", "", "", ""),
            channels, List.of(), List.of(), null, 0.0,
            "mass_spectrometry", "methanol");
        run.setUVVisMetadata(1.0);

        String p = tmp.resolve("uvvis.tio").toString();
        try (SpectralDataset ds = SpectralDataset.create(p, "uv", "ISA-UV",
                List.of(run), List.of(), List.of(), List.of())) { }

        Spectrum s = firstSpectrum(p);
        assertInstanceOf(UVVisSpectrum.class, s);
        UVVisSpectrum uv = (UVVisSpectrum) s;
        assertEquals(1.0, uv.pathLengthCm());
        assertEquals("methanol", uv.solvent());
        assertArrayEquals(x, uv.wavelengthValues());
        assertArrayEquals(y, uv.absorbanceValues());
    }

    @Test
    void msRunUnaffected(@TempDir Path tmp) {
        double[] mz = {100, 101, 102, 103};
        double[] intensity = {10, 20, 30, 40};
        AcquisitionRun run = run("ms", mz, intensity, "mz", "intensity");
        String p = tmp.resolve("ms.tio").toString();
        try (SpectralDataset ds = SpectralDataset.create(p, "ms", "ISA-MS",
                List.of(run), List.of(), List.of(), List.of())) { }
        assertInstanceOf(MassSpectrum.class, firstSpectrum(p));
    }
}
