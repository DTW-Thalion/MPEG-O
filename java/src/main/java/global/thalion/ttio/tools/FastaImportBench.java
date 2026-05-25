/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.tools;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.genomics.ReferenceImport;
import global.thalion.ttio.importers.FastaReader;
import global.thalion.ttio.io.ProgressSink;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;

/**
 * Standalone perf bench for FASTA → reference HDF5 encoding.
 *
 * <p>Usage:</p>
 * <pre>
 *   java -cp ... global.thalion.ttio.tools.FastaImportBench \
 *        &lt;source.fa&gt; &lt;target.tio&gt;
 * </pre>
 *
 * <p>Prints:</p>
 * <ul>
 *   <li>Read phase wall time (FASTA parse → in-memory ReferenceImport).</li>
 *   <li>Chromosome count + size distribution
 *       (min/median/p90/p99/max bytes).</li>
 *   <li>Per-N-chromosome batch wall time + file-size snapshot during
 *       the write phase (so a slowdown shows up clearly as a batch
 *       that takes much longer than its siblings).</li>
 *   <li>Total write wall time, average chroms/sec.</li>
 *   <li>H5Fclose wall time (the often-invisible finalize step).</li>
 * </ul>
 *
 * <p>Output is line-buffered, prefixed {@code BENCH}, so it can be
 * grepped out of mixed logs.</p>
 *
 * @since 1.3.0
 */
public final class FastaImportBench {

    private static final int BATCH = 500;

    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("usage: FastaImportBench <source.fa> <target.tio>");
            System.exit(2);
        }
        Path src = Paths.get(args[0]);
        Path dst = Paths.get(args[1]);

        if (Files.exists(dst)) {
            Files.delete(dst);
            log("removed pre-existing target " + dst);
        }
        long srcBytes = Files.size(src);
        log("source = " + src + "  (" + srcBytes + " bytes / "
            + (srcBytes / 1024 / 1024) + " MB)");

        // --- read phase ---
        long t0 = System.nanoTime();
        FastaReader r = new FastaReader(src);
        ReferenceImport ref = r.readReference();
        long readNs = System.nanoTime() - t0;
        int n = ref.chromosomes().size();
        log("read   = " + ms(readNs) + " ms  (" + n + " chromosomes)");

        // size distribution
        int[] sizes = new int[n];
        long totalBases = 0L;
        for (int i = 0; i < n; i++) {
            int sz = ref.sequences().get(i).length;
            sizes[i] = sz;
            totalBases += sz;
        }
        int[] sorted = sizes.clone();
        java.util.Arrays.sort(sorted);
        log("sizes  min=" + sorted[0]
            + "  median=" + sorted[n / 2]
            + "  p90=" + sorted[(int) (n * 0.90)]
            + "  p99=" + sorted[(int) (n * 0.99)]
            + "  max=" + sorted[n - 1]
            + "  totalBases=" + totalBases);

        // --- write phase ---
        log("creating target dataset ...");
        long createT0 = System.nanoTime();
        SpectralDataset ds = SpectralDataset.create(
            dst.toString(), "", "",
            List.of(), List.of(), List.of(), List.of());
        log("created in " + ms(System.nanoTime() - createT0) + " ms");

        final long[] batchT0 = { System.nanoTime() };
        final int[] lastDoneBatch = { 0 };
        final List<long[]> samples = new ArrayList<>(); // (chromsDone, elapsedNs, fileSize)

        ProgressSink sink = (recDone, recTotal) -> {
            if (recDone == 0L) return;
            int done = (int) recDone;
            if (done == lastDoneBatch[0]) return;
            if (done % BATCH == 0 || done == n) {
                long now = System.nanoTime();
                long batchNs = now - batchT0[0];
                long fileSz = -1L;
                try { fileSz = Files.size(dst); } catch (Exception ignored) {}
                int batchSize = done - lastDoneBatch[0];
                double batchSec = batchNs / 1.0e9;
                double rate = batchSize / batchSec;
                log(String.format(
                    "  batch %5d..%5d  %5d chroms in %7.2f s  %7.1f chroms/s  file=%9d (%5.1f MB)",
                    lastDoneBatch[0], done, batchSize, batchSec, rate,
                    fileSz, fileSz / 1024.0 / 1024.0));
                samples.add(new long[] { done, now - createT0, fileSz });
                batchT0[0] = now;
                lastDoneBatch[0] = done;
            }
        };

        log("write phase begin ...");
        long writeT0 = System.nanoTime();
        try (ds) {
            ref.writeToDataset(ds, /*overwrite=*/false, sink);
            log("ref.writeToDataset returned in "
                + ms(System.nanoTime() - writeT0) + " ms");

            log("calling H5Fclose via try-with-resources ...");
        }
        long writeAndCloseNs = System.nanoTime() - writeT0;
        long fileSz = Files.size(dst);
        log("write+close TOTAL  " + ms(writeAndCloseNs) + " ms");
        log("final file size    " + fileSz + " bytes ("
            + (fileSz / 1024 / 1024) + " MB)");
        log("chroms / sec avg   "
            + String.format("%.1f", n / (writeAndCloseNs / 1.0e9)));

        // close-only delta = (total) - (last batch end)
        if (!samples.isEmpty()) {
            long[] last = samples.get(samples.size() - 1);
            long closeOnlyNs = writeAndCloseNs - last[1];
            log("H5Fclose-only      "
                + ms(closeOnlyNs) + " ms  ("
                + String.format("%.1f%%", 100.0 * closeOnlyNs / writeAndCloseNs)
                + " of write+close)");
        }
    }

    private static long ms(long ns) {
        return ns / 1_000_000L;
    }

    private static void log(String s) {
        System.out.println("BENCH " + s);
        System.out.flush();
    }
}
