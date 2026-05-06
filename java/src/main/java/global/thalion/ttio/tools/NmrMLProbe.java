/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.tools;

import global.thalion.ttio.importers.NmrMLReader;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

/**
 * Cross-language nmrML parity probe.
 *
 * <p>Reads an nmrML file and emits the four parity fields
 * (numberOfScans, spectrometerFrequencyMHz, fidReal, fidImag) as a
 * tiny JSON object on stdout. Used by
 * {@code python/tests/test_nmrml_cross_lang_parity.py} to drive
 * Python / Java / ObjC readers against the same synthetic input
 * and assert byte-equal surface fields.</p>
 *
 * <p>Output format (single line, no trailing newline required):</p>
 * <pre>
 * {"numberOfScans": 16, "spectrometerFrequencyMHz": 600.0,
 *  "fidReal": [...], "fidImag": [...]}
 * </pre>
 *
 * <p>Doubles are emitted via {@link Double#toString(double)} so the
 * IEEE-754 round-trip is exact.</p>
 */
public final class NmrMLProbe {

    private NmrMLProbe() {}

    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            System.err.println("usage: NmrMLProbe <input.nmrML>");
            System.exit(1);
        }
        Path in = Paths.get(args[0]);
        if (!Files.exists(in)) {
            System.err.println("input not found: " + in);
            System.exit(2);
        }

        NmrMLReader.NmrMLResult r = NmrMLReader.read(in.toString());

        StringBuilder sb = new StringBuilder(1024);
        sb.append("{\"numberOfScans\":").append(r.numberOfScans());
        sb.append(",\"spectrometerFrequencyMHz\":")
          .append(Double.toString(r.spectrometerFrequencyMHz()));
        appendDoubleArray(sb, ",\"fidReal\":", r.fidReal());
        appendDoubleArray(sb, ",\"fidImag\":", r.fidImag());
        sb.append("}");
        System.out.println(sb.toString());
    }

    private static void appendDoubleArray(
        StringBuilder sb, String key, double[] arr
    ) {
        sb.append(key).append('[');
        for (int i = 0; i < arr.length; i++) {
            if (i > 0) sb.append(',');
            sb.append(Double.toString(arr[i]));
        }
        sb.append(']');
    }
}
