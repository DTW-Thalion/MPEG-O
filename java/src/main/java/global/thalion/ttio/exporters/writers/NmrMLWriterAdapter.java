/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.exporters.writers;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.NMRSpectrum;
import global.thalion.ttio.Spectrum;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.exporters.NmrMLWriter;
import global.thalion.ttio.exporters.RunSelection;
import global.thalion.ttio.exporters.Writer;

import java.io.IOException;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;

/**
 * {@link Writer} adapter for nmrML export. Mirrors Python
 * {@code ttio.exporters.writers.NmrMLWriter}: select the NMR run, verify the
 * first spectrum is an NMR spectrum (Python-parity error text), then delegate
 * to the SDK {@code NmrMLWriter}.
 *
 * <p>The tio-browser GUI {@code ExportTask.exportNmrML} passes the whole run
 * to {@code NmrMLWriter.write(run, path, sink)}; this adapter does the same
 * after applying Python's NMR-class guard so a non-NMR run is rejected with
 * the cross-language message.</p>
 *
 * @since 1.7.0
 */
public final class NmrMLWriterAdapter implements Writer {

    @Override
    public void write(SpectralDataset ds, String layer, Path output,
                      Map<String, Object> opts) throws IOException {
        AcquisitionRun run = RunSelection.nmrRun(ds, layer);
        List<Spectrum> spectra = run.spectra();
        String layerRepr = (layer == null || layer.isEmpty())
            ? "'(only)'" : "'" + layer + "'";
        if (spectra.isEmpty()) {
            throw new IllegalArgumentException(
                "run " + layerRepr + " has no spectra");
        }
        Spectrum first = spectra.get(0);
        if (!(first instanceof NMRSpectrum)) {
            throw new IllegalArgumentException(
                "run " + layerRepr + " is "
                + first.getClass().getSimpleName()
                + ", not an NMR spectrum; pass --layer to select an NMR run");
        }
        // GUI: NmrMLWriter.write(run, targetPath, sink).
        NmrMLWriter.write(run, output.toString(), null);
    }
}
