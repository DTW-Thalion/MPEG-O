/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.importers.readers;

import global.thalion.ttio.MSImage;
import global.thalion.ttio.importers.ImportedDataset;
import global.thalion.ttio.importers.ImzMLReader;
import global.thalion.ttio.importers.Reader;
import global.thalion.ttio.io.ProgressSink;

import java.io.IOException;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;

/** {@link Reader} adapter for imzML (continuous mode only). Mirrors the
 *  GUI {@code ImportTask.importImzML}: reads the {@code .imzML} + sibling
 *  {@code .ibd}, projects pixel spectra into a flat intensity cube, and
 *  builds an {@link MSImage} set on {@link ImportedDataset#image}.
 *
 *  <p>The {@code .ibd} location follows the Python {@code ImzMLReader}:
 *  {@code opts.get("ibd")} if present, else {@code inputs.get(1)} if a
 *  second input was supplied, else {@code null} (auto-located by the
 *  underlying reader via filename rewriting).</p>
 *
 *  <p>Processed-mode files are rejected, exactly as the GUI does.</p> */
public final class ImzMLReaderAdapter implements Reader {
    @Override
    public ImportedDataset read(List<String> inputs, Map<String, Object> opts,
                                ProgressSink progress) throws IOException {
        Path imzml = Path.of(inputs.get(0));

        Path ibd = null;
        Object ibdOpt = opts.get("ibd");
        if (ibdOpt instanceof Path p) {
            ibd = p;
        } else if (ibdOpt instanceof String s && !s.isEmpty()) {
            ibd = Path.of(s);
        } else if (inputs.size() > 1 && inputs.get(1) != null) {
            ibd = Path.of(inputs.get(1));
        }

        ImzMLReader.ImzMLImport imp = ImzMLReader.read(
            imzml, ibd, progress != null ? progress : ProgressSink.discard());

        if (imp.spectra().isEmpty()) {
            throw new IllegalStateException(
                "imzML import: no pixels parsed from " + imzml);
        }
        if (!"continuous".equals(imp.mode())) {
            throw new UnsupportedOperationException(
                "imzML import: processed mode not yet supported; "
                + "only continuous mode is wired. "
                + "File reports mode=" + imp.mode() + ".");
        }

        int width  = imp.gridMaxX();
        int height = imp.gridMaxY();
        int sp     = imp.spectra().get(0).mz().length;
        double[] mzAxis = imp.spectra().get(0).mz();

        double[] cube = new double[width * height * sp];
        for (ImzMLReader.PixelSpectrum pix : imp.spectra()) {
            int col = pix.x() - 1;  // imzML is 1-indexed
            int row = pix.y() - 1;
            if (row < 0 || row >= height || col < 0 || col >= width) continue;
            double[] pi = pix.intensity();
            int base = (row * width + col) * sp;
            System.arraycopy(pi, 0, cube, base, Math.min(pi.length, sp));
        }

        MSImage img = new MSImage(
            width, height, sp, 0,
            imp.pixelSizeX(), imp.pixelSizeY(),
            imp.scanPattern(),
            cube, mzAxis,
            "", "",
            List.of(), List.of(), List.of());

        ImportedDataset d = new ImportedDataset();
        d.image = img;
        return d;
    }
}
