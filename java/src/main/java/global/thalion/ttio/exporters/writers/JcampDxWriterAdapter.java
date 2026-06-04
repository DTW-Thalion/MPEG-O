/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.exporters.writers;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.IRSpectrum;
import global.thalion.ttio.RamanSpectrum;
import global.thalion.ttio.Spectrum;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.UVVisSpectrum;
import global.thalion.ttio.exporters.JcampDxEncoding;
import global.thalion.ttio.exporters.JcampDxWriter;
import global.thalion.ttio.exporters.RunSelection;
import global.thalion.ttio.exporters.Writer;

import java.io.IOException;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;

/**
 * {@link Writer} adapter for JCAMP-DX export. Mirrors Python
 * {@code ttio.exporters.writers.JcampDxWriter}: select the analytical run,
 * dispatch the first spectrum to the matching IR / Raman / UV-Vis writer with
 * the {@code encoding} opt (default {@code "affn"}), else raise Python's
 * "not a vibrational" error.
 *
 * <p>The tio-browser GUI {@code ExportTask.exportJcampDx} dispatches on the
 * first Raman/IR/UV-Vis spectrum found across runs and passes the encoding +
 * {@code ds.title()}. This adapter follows Python's stricter single-run
 * "first spectrum" contract (run selected via {@link RunSelection}) while
 * keeping the GUI's {@code title} and {@code encoding} call shape.</p>
 *
 * @since 1.7.0
 */
public final class JcampDxWriterAdapter implements Writer {

    @Override
    public void write(SpectralDataset ds, String layer, Path output,
                      Map<String, Object> opts) throws IOException {
        Object encOpt = opts.getOrDefault("encoding", "affn");
        JcampDxEncoding enc = JcampDxEncoding.fromString(encOpt.toString());
        AcquisitionRun run = RunSelection.analyticalRun(ds, layer);
        List<Spectrum> spectra = run.spectra();
        String layerRepr = (layer == null || layer.isEmpty())
            ? "'(only)'" : "'" + layer + "'";
        if (spectra.isEmpty()) {
            throw new IllegalArgumentException(
                "run " + layerRepr + " has no spectra");
        }
        Spectrum first = spectra.get(0);
        if (first instanceof IRSpectrum ir) {
            JcampDxWriter.writeIRSpectrum(ir, output, ds.title(), enc, null);
        } else if (first instanceof RamanSpectrum r) {
            JcampDxWriter.writeRamanSpectrum(r, output, ds.title(), enc, null);
        } else if (first instanceof UVVisSpectrum uv) {
            JcampDxWriter.writeUVVisSpectrum(uv, output, ds.title(), enc, null);
        } else {
            throw new IllegalArgumentException(
                "run " + layerRepr + " is "
                + first.getClass().getSimpleName()
                + ", not a vibrational (IR/Raman/UV-Vis) spectrum");
        }
    }
}
