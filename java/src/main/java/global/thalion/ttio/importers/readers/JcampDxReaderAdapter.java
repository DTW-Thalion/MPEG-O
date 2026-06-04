/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.importers.readers;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.IRSpectrum;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.RamanSpectrum;
import global.thalion.ttio.SignalArray;
import global.thalion.ttio.Spectrum;
import global.thalion.ttio.SpectrumIndex;
import global.thalion.ttio.UVVisSpectrum;
import global.thalion.ttio.importers.ImportedDataset;
import global.thalion.ttio.importers.JcampDxReader;
import global.thalion.ttio.importers.Reader;
import global.thalion.ttio.io.ProgressSink;

import java.io.IOException;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** {@link Reader} adapter for JCAMP-DX. Replicates the GUI
 *  {@code ImportTask.importJcampDx}: wraps the single parsed
 *  {@link Spectrum} into a single-spectrum {@link AcquisitionRun}, with
 *  the {@link AcquisitionMode} chosen from the spectrum subclass
 *  (Raman / IR / UV-Vis, defaulting to Raman) and every named signal
 *  array forwarded as a run channel. */
public final class JcampDxReaderAdapter implements Reader {
    @Override
    public ImportedDataset read(List<String> inputs, Map<String, Object> opts,
                                ProgressSink progress) throws IOException {
        Path src = Path.of(inputs.get(0));
        Spectrum spectrum = JcampDxReader.readSpectrum(
            src, progress != null ? progress : ProgressSink.discard());

        AcquisitionMode mode;
        if (spectrum instanceof RamanSpectrum) {
            mode = AcquisitionMode.RAMAN;
        } else if (spectrum instanceof IRSpectrum) {
            mode = AcquisitionMode.IR;
        } else if (spectrum instanceof UVVisSpectrum) {
            mode = AcquisitionMode.UV_VIS;
        } else {
            mode = AcquisitionMode.RAMAN;
        }

        Map<String, double[]> channels = new LinkedHashMap<>();
        for (Map.Entry<String, SignalArray> entry
                : spectrum.signalArrays().entrySet()) {
            channels.put(entry.getKey(), entry.getValue().asDoubles());
        }

        int totalPeaks = channels.isEmpty() ? 0
            : channels.values().iterator().next().length;
        SpectrumIndex index = new SpectrumIndex(
            1,
            new long[]   { 0 },
            new int[]    { totalPeaks },
            new double[] { 0.0 },
            new int[]    { 1 },
            new int[]    { 0 },
            new double[] { 0.0 },
            new int[]    { 0 },
            new double[] { 0.0 });

        Object nameOpt = opts.get("name");
        String runName = (nameOpt instanceof String s && !s.isEmpty())
            ? s : "spectrum_0001";
        AcquisitionRun run = new AcquisitionRun(
            runName, mode, index,
            new InstrumentConfig("", "", "", "", "", ""),
            channels, List.of(), List.of(), "", 0.0);

        ImportedDataset d = new ImportedDataset();
        d.title = stem(src);
        d.runs.add(run);
        return d;
    }

    private static String stem(Path p) {
        String fn = p.getFileName().toString();
        int dot = fn.lastIndexOf('.');
        return dot > 0 ? fn.substring(0, dot) : fn;
    }
}
