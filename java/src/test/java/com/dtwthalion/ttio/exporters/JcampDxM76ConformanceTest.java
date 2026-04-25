/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio.exporters;

import com.dtwthalion.ttio.UVVisSpectrum;

import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

import static org.junit.jupiter.api.Assertions.assertEquals;

/**
 * M76 byte-parity conformance check for the Java JCAMP-DX compressed
 * writer.
 *
 * <p>Each mode (PAC / SQZ / DIF) has a matching golden fixture under
 * {@code conformance/jcamp_dx/}. Python and Objective-C ship the
 * analogous tests — together they form the M76 cross-language
 * byte-parity gate.</p>
 */
class JcampDxM76ConformanceTest {

    @TempDir
    Path tempDir;

    private static Path conformanceDir() {
        // java/ is one level below the repo root, so conformance/ lives
        // next to us. Works under "mvn -f java/pom.xml" and under a
        // workspace checkout alike.
        Path here = Paths.get("").toAbsolutePath();
        // Walk up to find conformance/jcamp_dx.
        for (int up = 0; up < 4; up++) {
            Path candidate = here.resolve("conformance").resolve("jcamp_dx");
            if (Files.isDirectory(candidate)) {
                return candidate;
            }
            here = here.getParent();
            if (here == null) break;
        }
        return Paths.get("conformance").resolve("jcamp_dx"); // relative fallback
    }

    private static UVVisSpectrum ramp25Fixture() {
        int n = 25;
        double[] wl = new double[n];
        double[] absorb = new double[n];
        for (int i = 0; i < n; i++) {
            wl[i] = 200.0 + i * 10.0;  // equispaced 200..440 nm
            absorb[i] = Math.min(i, 24 - i);
        }
        return new UVVisSpectrum(wl, absorb, 0, 0.0, 1.0, "water");
    }

    @ParameterizedTest
    @EnumSource(value = JcampDxEncoding.class, names = {"PAC", "SQZ", "DIF"})
    void javaWriterMatchesGolden(JcampDxEncoding mode) throws IOException {
        String suffix = mode.name().toLowerCase();
        Path golden = conformanceDir().resolve("uvvis_ramp25_" + suffix + ".jdx");
        Assumptions.assumeTrue(Files.isRegularFile(golden),
                "golden fixture missing: " + golden);

        Path out = tempDir.resolve("gen_" + suffix + ".jdx");
        JcampDxWriter.writeUVVisSpectrum(ramp25Fixture(), out, "m76 ramp-25", mode);

        byte[] produced = Files.readAllBytes(out);
        byte[] expected = Files.readAllBytes(golden);

        // String comparison gives a much more readable failure message
        // than raw byte diffs.
        assertEquals(
                new String(expected, StandardCharsets.UTF_8),
                new String(produced, StandardCharsets.UTF_8),
                "byte-parity drift on " + mode + " encoder");
    }
}
