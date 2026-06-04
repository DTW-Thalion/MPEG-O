/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.importers.readers;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums;
import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.MSImage;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.SpectrumIndex;
import global.thalion.ttio.exporters.writers.ImzMLWriterAdapter;
import global.thalion.ttio.exporters.writers.JcampDxWriterAdapter;
import global.thalion.ttio.importers.ImportedDataset;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * End-to-end round-trip coverage for the per-format {@code Reader} adapters
 * that have pure-Java writers: write the format via its {@code Writer}
 * adapter, then re-import it via the matching {@code Reader} adapter and
 * assert the materialised {@link ImportedDataset} carries the expected
 * structure. Exercises both the writer and reader adapter in one flow.
 */
class AdapterRoundTripTest {

    @TempDir
    Path tmp;

    private static SpectrumIndex oneSpectrum(int n, double basePeak) {
        return new SpectrumIndex(1,
            new long[]{0}, new int[]{n},
            new double[]{0.0}, new int[]{0}, new int[]{0},
            new double[]{0.0}, new int[]{0}, new double[]{basePeak});
    }

    // ── JCAMP-DX: IR write → read ───────────────────────────────────

    @Test
    void jcampDxIrRoundTrip() throws Exception {
        double[] x = {400, 800, 1200, 1600, 2000, 2400};
        double[] y = {0.1, 0.5, 0.2, 0.9, 0.3, 0.7};
        Map<String, double[]> ch = new LinkedHashMap<>();
        ch.put("wavenumber", x);
        ch.put("intensity", y);
        AcquisitionRun run = new AcquisitionRun("ir_run", AcquisitionMode.IR,
            oneSpectrum(x.length, 0.9),
            new InstrumentConfig("", "", "", "", "", ""),
            ch, List.of(), List.of(), null, 0.0);
        run.setIRMetadata(Enums.IRMode.ABSORBANCE, 4.0, 32);

        Path tio = tmp.resolve("ir.tio");
        try (SpectralDataset ds = SpectralDataset.create(tio.toString(), "ir",
                "ISA-ir", List.of(run), List.of(), List.of(), List.of())) {
            assertNotNull(ds);
        }

        Path jdx = tmp.resolve("out.jdx");
        try (SpectralDataset ds = SpectralDataset.open(tio.toString())) {
            new JcampDxWriterAdapter().write(ds, "ir_run", jdx, Map.of());
        }
        assertTrue(Files.exists(jdx));
        assertTrue(Files.size(jdx) > 0);

        ImportedDataset imp = new JcampDxReaderAdapter()
            .read(List.of(jdx.toString()), Map.of(), null);
        assertEquals(1, imp.runs.size(), "one run materialised from JCAMP-DX");
        AcquisitionRun back = imp.runs.get(0);
        assertEquals(AcquisitionMode.IR, back.acquisitionMode());
        assertFalse(back.channels().isEmpty(), "channels forwarded from spectrum");
    }

    @Test
    void jcampDxReaderHonoursNameOpt() throws Exception {
        double[] x = {200, 700, 1200, 1700};
        double[] y = {0.05, 0.4, 0.6, 0.2};
        Map<String, double[]> ch = new LinkedHashMap<>();
        ch.put("wavenumber", x);
        ch.put("intensity", y);
        AcquisitionRun run = new AcquisitionRun("rm_run", AcquisitionMode.RAMAN,
            oneSpectrum(x.length, 0.6),
            new InstrumentConfig("", "", "", "", "", ""),
            ch, List.of(), List.of(), null, 0.0);
        run.setRamanMetadata(785.0, 10.0, 2.5);

        Path tio = tmp.resolve("rm.tio");
        try (SpectralDataset ds = SpectralDataset.create(tio.toString(), "rm",
                "ISA-rm", List.of(run), List.of(), List.of(), List.of())) {
            assertNotNull(ds);
        }
        Path jdx = tmp.resolve("rm.jdx");
        try (SpectralDataset ds = SpectralDataset.open(tio.toString())) {
            new JcampDxWriterAdapter().write(ds, "rm_run", jdx, Map.of());
        }

        ImportedDataset imp = new JcampDxReaderAdapter()
            .read(List.of(jdx.toString()), Map.of("name", "my_run"), null);
        assertEquals("my_run", imp.runs.get(0).name());
        assertEquals(AcquisitionMode.RAMAN, imp.runs.get(0).acquisitionMode());
    }

    // ── imzML: image write → read ───────────────────────────────────

    private MSImage smallImage() {
        int w = 2;
        int h = 2;
        int sp = 3;
        double[] mz = {100.0, 200.0, 300.0};
        double[] cube = new double[w * h * sp];
        for (int i = 0; i < cube.length; i++) cube[i] = i + 1.0;
        return new MSImage(w, h, sp, 0, 10.0, 10.0, "flyback",
            cube, mz, "", "", List.of(), List.of(), List.of());
    }

    @Test
    void imzMLRoundTrip() throws Exception {
        MSImage img = smallImage();
        Path tio = tmp.resolve("img.tio");
        SpectralDataset.createWithImages(tio.toString(), "img", "ISA-img",
            img, null, null);

        Path imzml = tmp.resolve("out.imzML");
        try (SpectralDataset ds = SpectralDataset.open(tio.toString())) {
            assertNotNull(ds.imageForKind(Enums.ImageKind.MS),
                "image must round-trip into the .tio");
            new ImzMLWriterAdapter().write(ds, null, imzml, Map.of());
        }
        assertTrue(Files.exists(imzml));
        Path ibd = tmp.resolve("out.ibd");
        assertTrue(Files.exists(ibd), "sibling .ibd must be written");

        ImportedDataset imp = new ImzMLReaderAdapter()
            .read(List.of(imzml.toString(), ibd.toString()), Map.of(), null);
        assertNotNull(imp.image, "reader adapter must materialise an MSImage");
        assertEquals(2, imp.image.width());
        assertEquals(2, imp.image.height());
    }

    @Test
    void imzMLReaderHonoursIbdOpt() throws Exception {
        MSImage img = smallImage();
        Path tio = tmp.resolve("img2.tio");
        SpectralDataset.createWithImages(tio.toString(), "img2", "ISA-img2",
            img, null, null);

        Path imzml = tmp.resolve("out2.imzML");
        try (SpectralDataset ds = SpectralDataset.open(tio.toString())) {
            new ImzMLWriterAdapter().write(ds, null, imzml, Map.of());
        }
        Path ibd = tmp.resolve("out2.ibd");

        // Supply the .ibd path via the "ibd" opt instead of a 2nd input.
        ImportedDataset imp = new ImzMLReaderAdapter().read(
            List.of(imzml.toString()),
            Map.of("ibd", ibd.toString()), null);
        assertNotNull(imp.image);
        assertEquals(3, imp.image.spectralPoints());
    }
}
