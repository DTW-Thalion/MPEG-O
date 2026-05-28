/* TTI-O Java Implementation / Copyright (c) 2026 The Thalion Initiative / SPDX-License-Identifier: LGPL-3.0-or-later */
package global.thalion.ttio;

import global.thalion.ttio.hdf5.Hdf5File;
import global.thalion.ttio.hdf5.Hdf5Group;
import global.thalion.ttio.providers.Hdf5Provider;

/**
 * Sequential reader for a single MS run inside an {@code .tio}
 * file. Delegates to {@link AcquisitionRun}'s Streamable methods.
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOStreamReader}, Python
 * {@code ttio.stream_reader.StreamReader}.</p>
 *
 *
 */
public final class StreamReader implements AutoCloseable {

    private Hdf5File file;
    private final AcquisitionRun run;

    /**
     * Open the {@code .tio} file at {@code filePath} and position a
     * cursor at the start of run {@code runName}.
     *
     * @param filePath absolute path to the {@code .tio} file
     * @param runName  MS-run name under {@code /study/ms_runs/}
     */
    public StreamReader(String filePath, String runName) {
        this.file = Hdf5File.openReadOnly(filePath);
        try (Hdf5Group study = file.rootGroup().openGroup("study");
             Hdf5Group runs = study.openGroup("ms_runs")) {
            // AcquisitionRun.readFrom takes StorageGroup; wrap the
            // raw Hdf5Group via the Hdf5Provider adapter.
            this.run = AcquisitionRun.readFrom(
                    Hdf5Provider.adapterForGroup(runs), runName);
        }
    }

    /** @return Total number of spectra in the opened run. */
    public int totalCount() { return run.count(); }

    /** @return Current zero-based stream cursor position. */
    public int currentPosition() { return run.currentPosition(); }

    /** @return {@code true} when no further spectra remain to be read. */
    public boolean atEnd() { return !run.hasMore(); }

    /**
     * Advance the cursor and return the next spectrum.
     *
     * @return next spectrum
     * @throws java.util.NoSuchElementException when the cursor has
     *         already reached the end of the run
     */
    public Spectrum nextSpectrum() { return run.nextObject(); }

    /** Reset the cursor to the beginning of the run. */
    public void reset() { run.reset(); }

    /** Close the underlying HDF5 file. Idempotent. */
    @Override
    public void close() {
        if (file != null) {
            file.close();
            file = null;
        }
    }
}
