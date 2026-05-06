/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.codecs.TtioRansNative;
import global.thalion.ttio.exporters.FastqWriter;
import global.thalion.ttio.genomics.GenomicRun;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.importers.FastqReader;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Random;

import static org.junit.jupiter.api.Assumptions.assumeTrue;

/**
 * Bulk-fetch FASTQ writer benchmark. Opt-in via
 * {@code -DTTIO_FASTQ_BENCH=1}. Confirms the read-side
 * {@link FastqWriter#write(GenomicRun, Path)} benefits from the same
 * bulk-fetch pattern that produced a 24× speedup in the Python
 * FastqWriter at 1M reads.
 */
final class FastqBulkBenchTest {

    @Test
    void fastqBulkWriteThroughput(@TempDir Path tmp) throws Exception {
        if (!"1".equals(System.getProperty("TTIO_FASTQ_BENCH"))) {
            return;
        }
        assumeTrue(TtioRansNative.isAvailable(),
            "libttio_rans not available — skipping FASTQ bulk benchmark");

        int n = Integer.parseInt(
            System.getProperty("TTIO_FASTQ_BENCH_N", "100000"));
        int len = 100;

        // Build a synthetic FASTQ in memory.
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

        // FASTQ -> WrittenGenomicRun -> .tio.
        WrittenGenomicRun runIn = new FastqReader(src).read("S1");
        SpectralDataset.create(
            tioPath.toString(),
            "", "",
            List.<AcquisitionRun>of(),
            List.of(runIn),
            null, null, null,
            FeatureFlags.defaultCurrent()
        );

        // Time the read-side FastqWriter against the on-disk run.
        Path outFq = tmp.resolve("out.fq");
        try (SpectralDataset ds = SpectralDataset.open(tioPath.toString())) {
            GenomicRun run = ds.genomicRuns().get("genomic_0001");
            // Warm-up: pre-decode read names to isolate the per-record loop.
            run.readNamesAll();
            long t0 = System.nanoTime();
            FastqWriter.write(run, outFq);
            long t1 = System.nanoTime();
            double ms = (t1 - t0) / 1e6;
            System.out.printf(
                "[java-bench] FASTQ %d reads × %dbp via GenomicRun bulk-fetch: "
              + "%.1f ms (%.0f K reads/s)%n",
                n, len, ms, n / ms);
        }
    }
}
