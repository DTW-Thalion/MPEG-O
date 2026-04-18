/* MPEG-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: LGPL-3.0-or-later */
package com.dtwthalion.mpgo;

import com.dtwthalion.mpgo.hdf5.Hdf5File;
import com.dtwthalion.mpgo.hdf5.Hdf5Group;
import com.dtwthalion.mpgo.providers.Hdf5Provider;

/**
 * Sequential reader for a single MS run inside an {@code .mpgo}
 * file. Delegates to {@link AcquisitionRun}'s Streamable methods.
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code MPGOStreamReader}, Python
 * {@code mpeg_o.stream_reader.StreamReader}.</p>
 *
 * @since 0.6
 */
public final class StreamReader implements AutoCloseable {

    private Hdf5File file;
    private final AcquisitionRun run;

    public StreamReader(String filePath, String runName) {
        this.file = Hdf5File.openReadOnly(filePath);
        try (Hdf5Group study = file.rootGroup().openGroup("study");
             Hdf5Group runs = study.openGroup("ms_runs")) {
            // v0.7 M44: AcquisitionRun.readFrom takes StorageGroup; wrap the
            // raw Hdf5Group via the Hdf5Provider adapter.
            this.run = AcquisitionRun.readFrom(
                    Hdf5Provider.adapterForGroup(runs), runName);
        }
    }

    public int totalCount() { return run.count(); }
    public int currentPosition() { return run.currentPosition(); }
    public boolean atEnd() { return !run.hasMore(); }

    public Spectrum nextSpectrum() { return run.nextObject(); }

    public void reset() { run.reset(); }

    @Override
    public void close() {
        if (file != null) {
            file.close();
            file = null;
        }
    }
}
