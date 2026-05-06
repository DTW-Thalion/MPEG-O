/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.tools;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.SpectrumIndex;
import global.thalion.ttio.importers.MzMLReader;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

/**
 * Cross-language mzML parity probe.
 *
 * <p>Reads an mzML file via {@link MzMLReader} and emits a single-line
 * JSON object on stdout containing the per-spectrum parity surface
 * (retention time, MS level, polarity, precursor m/z + charge, full
 * mz + intensity arrays). Used by
 * {@code python/tests/integration/test_mzml_cross_lang_parity.py} to
 * drive Python / Java / ObjC readers against the same mzML input and
 * assert byte-equal surface fields.</p>
 *
 * <p>Doubles are emitted via {@link Double#toString(double)} so the
 * IEEE-754 round-trip is exact across languages.</p>
 */
public final class MzMLProbe {

    private MzMLProbe() {}

    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            System.err.println("usage: MzMLProbe <input.mzML>");
            System.exit(1);
        }
        Path in = Paths.get(args[0]);
        if (!Files.exists(in)) {
            System.err.println("input not found: " + in);
            System.exit(2);
        }

        AcquisitionRun run = MzMLReader.read(in.toString());
        SpectrumIndex idx = run.spectrumIndex();
        int n = idx.count();

        StringBuilder sb = new StringBuilder(4096);
        sb.append("{\"spectrumCount\":").append(n);
        sb.append(",\"spectra\":[");
        for (int i = 0; i < n; i++) {
            if (i > 0) sb.append(',');
            sb.append("{\"retentionTime\":")
              .append(Double.toString(idx.retentionTimeAt(i)));
            sb.append(",\"msLevel\":").append(idx.msLevelAt(i));
            sb.append(",\"polarity\":").append(idx.polarities()[i]);
            sb.append(",\"precursorMz\":")
              .append(Double.toString(idx.precursorMzAt(i)));
            sb.append(",\"precursorCharge\":").append(idx.precursorChargeAt(i));
            appendDoubleArray(sb, ",\"mz\":", run.channelSlice("mz", i));
            appendDoubleArray(sb, ",\"intensity\":",
                              run.channelSlice("intensity", i));
            sb.append('}');
        }
        sb.append("]}");
        System.out.println(sb.toString());
    }

    private static void appendDoubleArray(
        StringBuilder sb, String key, double[] arr
    ) {
        sb.append(key).append('[');
        if (arr != null) {
            for (int i = 0; i < arr.length; i++) {
                if (i > 0) sb.append(',');
                sb.append(Double.toString(arr[i]));
            }
        }
        sb.append(']');
    }
}
