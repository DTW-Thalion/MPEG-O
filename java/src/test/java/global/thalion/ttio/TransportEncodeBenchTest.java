/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.codecs.TtioRansNative;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.importers.FastqReader;
import global.thalion.ttio.transport.TransportWriter;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Random;

import static org.junit.jupiter.api.Assumptions.assumeTrue;

/**
 * Genomic transport-encode microbench. Opt-in via
 * {@code -DTTIO_TRANSPORT_BENCH=1}. Times
 * {@link TransportWriter#writeDataset(SpectralDataset)} on a
 * synthetic genomic .tio in per-AU mode (the path that calls
 * {@code emitGenomicRunAccessUnits}, which hits
 * {@code GenomicRun.objectAtIndex(i)} per record).
 */
final class TransportEncodeBenchTest {

    @Test
    void genomicTransportEncodeThroughput(@TempDir Path tmp) throws Exception {
        if (!"1".equals(System.getProperty("TTIO_TRANSPORT_BENCH"))) {
            return;
        }
        assumeTrue(TtioRansNative.isAvailable(),
            "libttio_rans not available — skipping transport bench");

        int n = Integer.parseInt(
            System.getProperty("TTIO_TRANSPORT_BENCH_N", "100000"));
        int len = 100;

        Random rng = new Random(42);
        StringBuilder sb = new StringBuilder(n * (len * 2 + 16));
        char[] bases = {'A', 'C', 'G', 'T'};
        for (int i = 0; i < n; i++) {
            sb.append('@').append("read_").append(i).append('\n');
            for (int j = 0; j < len; j++) sb.append(bases[rng.nextInt(4)]);
            sb.append('\n').append("+\n");
            for (int j = 0; j < len; j++) {
                sb.append((char) ('!' + rng.nextInt(40)));
            }
            sb.append('\n');
        }
        Path src = tmp.resolve("bench.fq");
        Files.writeString(src, sb.toString(), StandardCharsets.US_ASCII);
        Path tioPath = tmp.resolve("bench.tio");

        WrittenGenomicRun runIn = new FastqReader(src).read("S1");
        SpectralDataset.create(
            tioPath.toString(),
            "", "",
            List.<AcquisitionRun>of(),
            List.of(runIn),
            null, null, null,
            FeatureFlags.defaultCurrent()
        );

        Path tisPath = tmp.resolve("bench.tis");
        try (SpectralDataset ds = SpectralDataset.open(tioPath.toString())) {
            // Warm: open the run + decode caches before timing.
            ds.genomicRuns().get("genomic_0001").readNamesAll();

            long t0 = System.nanoTime();
            try (OutputStream os = Files.newOutputStream(tisPath);
                 TransportWriter tw = new TransportWriter(os)) {
                tw.writeDataset(ds);
            }
            long t1 = System.nanoTime();
            double ms = (t1 - t0) / 1e6;
            long bytes = Files.size(tisPath);
            System.out.printf(
                "[java-bench] transport encode (genomic per-AU) %d reads × %dbp: "
              + "%.1f ms (%.0f K reads/s), .tis=%d bytes%n",
                n, len, ms, n / ms, bytes);
        }
    }
}
