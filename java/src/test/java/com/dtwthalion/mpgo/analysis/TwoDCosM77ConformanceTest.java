/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo.analysis;

import com.dtwthalion.mpgo.TwoDimensionalCorrelationSpectrum;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Assumptions;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * M77 cross-language conformance gate — Java side. Loads the shared
 * {@code conformance/two_d_cos/} fixtures produced by the Python
 * reference implementation and asserts that the Java compute output
 * matches within {@code rtol=1e-9, atol=1e-12}.
 */
class TwoDCosM77ConformanceTest {

    private static Path findConformanceDir() {
        Path here = Paths.get("").toAbsolutePath();
        for (int up = 0; up < 6; up++) {
            Path probe = here.resolve("conformance").resolve("two_d_cos");
            if (Files.isDirectory(probe)) {
                return probe;
            }
            if (here.getParent() == null) break;
            here = here.getParent();
        }
        return null;
    }

    private static double[][] readCsv(Path path) throws IOException {
        List<double[]> rows = new ArrayList<>();
        for (String line : Files.readAllLines(path)) {
            String trimmed = line.trim();
            if (trimmed.isEmpty()) continue;
            String[] parts = trimmed.split(",");
            double[] row = new double[parts.length];
            for (int i = 0; i < parts.length; i++) {
                row[i] = Double.parseDouble(parts[i]);
            }
            rows.add(row);
        }
        return rows.toArray(new double[0][]);
    }

    private static double[] flatten(double[][] rows) {
        int m = rows.length;
        int n = m == 0 ? 0 : rows[0].length;
        double[] out = new double[m * n];
        for (int i = 0; i < m; i++) {
            System.arraycopy(rows[i], 0, out, i * n, n);
        }
        return out;
    }

    private static void assertAllclose(double[] actual, double[] expected,
                                       double rtol, double atol, String label) {
        assertEquals(expected.length, actual.length,
            label + " length mismatch");
        for (int i = 0; i < actual.length; i++) {
            double tol = atol + rtol * Math.abs(expected[i]);
            double diff = Math.abs(actual[i] - expected[i]);
            if (diff > tol) {
                fail(label + "[" + i + "] mismatch: "
                    + actual[i] + " vs " + expected[i]
                    + " (diff=" + diff + ", tol=" + tol + ")");
            }
        }
    }

    @Test void m77TwoDCosConformanceFixture() throws IOException {
        Path conf = findConformanceDir();
        Assumptions.assumeTrue(conf != null,
            "conformance/two_d_cos not reachable from CWD");
        double[][] dynRows = readCsv(conf.resolve("dynamic.csv"));
        double[][] syncRows = readCsv(conf.resolve("sync.csv"));
        double[][] asyncRows = readCsv(conf.resolve("async.csv"));

        int m = dynRows.length;
        int n = dynRows[0].length;
        double[] dyn = flatten(dynRows);
        double[] expectedSync = flatten(syncRows);
        double[] expectedAsync = flatten(asyncRows);

        TwoDimensionalCorrelationSpectrum spec = TwoDCos.compute(dyn, m, n);

        assertAllclose(spec.synchronousMatrix(), expectedSync,
            1e-9, 1e-12, "synchronous");
        assertAllclose(spec.asynchronousMatrix(), expectedAsync,
            1e-9, 1e-12, "asynchronous");
    }
}
