/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.importers;

import global.thalion.ttio.Chromatogram;
import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.SpectralStreamWriter;
import global.thalion.ttio.WrittenSpectralBatch;
import global.thalion.ttio.io.ProgressSink;
import global.thalion.ttio.providers.StorageGroup;

import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.function.Supplier;

/**
 * A spectral run delivered as consecutive {@link WrittenSpectralBatch}es
 * (see {@link MzMLReader#stream}), written through
 * {@link SpectralStreamWriter}. {@code chromatogramsAfter}, when given, is
 * read after the last batch. Python: {@code ttio.importers.SpectralStreamSource}.
 */
public record SpectralStreamSource(String name, Supplier<Iterator<WrittenSpectralBatch>> batches,
                                   AcquisitionMode acquisitionMode, InstrumentConfig instrumentConfig,
                                   int batchSpectra, Supplier<List<Chromatogram>> chromatogramsAfter) {

    /** Write the run into {@code /study} {@code study}; returns the
     *  spectra written. */
    public long writeInto(StorageGroup study, ProgressSink progress) {
        ProgressSink sink = progress == null ? ProgressSink.discard() : progress;
        SpectralStreamWriter writer = null;
        long n = 0;
        Iterator<WrittenSpectralBatch> it = batches.get();
        try {
            while (it.hasNext()) {
                WrittenSpectralBatch b = it.next();
                if (writer == null) {
                    writer = new SpectralStreamWriter(study, name,
                        SpectralStreamWriter.Options.ms(acquisitionMode,
                            new ArrayList<>(b.channelData().keySet()), instrumentConfig)
                            .withBatchSpectra(batchSpectra));
                }
                writer.appendBatch(b);
                n += b.spectrumCount();
                sink.onProgress(n, -1L);
            }
        } finally {
            if (it instanceof AutoCloseable c) {
                try { c.close(); } catch (Exception ignored) { }
            }
        }
        if (writer != null) {
            if (chromatogramsAfter != null) writer.setChromatograms(chromatogramsAfter.get());
            writer.close();
        }
        sink.onProgress(n, n);
        return n;
    }
}
