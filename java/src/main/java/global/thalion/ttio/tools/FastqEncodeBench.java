// SPDX-License-Identifier: Apache-2.0
package global.thalion.ttio.tools;

import global.thalion.ttio.importers.FastqReader;
import global.thalion.ttio.providers.ProviderRegistry;
import global.thalion.ttio.providers.StorageGroup;
import global.thalion.ttio.providers.StorageProvider;

import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Times a FASTQ import into a blocks_v1 .tio through the streaming
 * importer (the parallel producer when TTIO_THREADS resolves above
 * one), so the encode throughput the parallel-producer work targets
 * stays watched.
 *
 * <p>Usage: {@code FastqEncodeBench <in.fastq[.gz]> <out.tio>
 * [batchBytes [blockBytes]]}</p>
 *
 * <p>Emits one line: {@code [java-bench] FASTQ encode <in> B in
 * <wall> s: <MB/s> MB/s, peak <MB> MB}</p>
 */
public final class FastqEncodeBench {
    private FastqEncodeBench() { }

    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("usage: FastqEncodeBench <in.fastq[.gz]> <out.tio> [batchBytes [blockBytes]]");
            System.exit(1);
        }
        Path in = Path.of(args[0]);
        Path out = Path.of(args[1]);
        long batchBytes = args.length > 2 ? Long.parseLong(args[2]) : 0L;
        Long blockBytes = args.length > 3 ? Long.parseLong(args[3]) : null;
        Files.deleteIfExists(out);
        long t0 = System.nanoTime();
        try (StorageProvider p = ProviderRegistry.open(out.toString(), StorageProvider.Mode.CREATE, "hdf5")) {
            StorageGroup study = p.rootGroup().createGroup("study");
            var src = new FastqReader(in).stream("genomic_0001", "s", Integer.MAX_VALUE, batchBytes);
            if (blockBytes != null) {
                src = new global.thalion.ttio.importers.GenomicStreamSource(
                    src.name(), src.batches(), src.referenceFasta(), src.embedReference(),
                    null, blockBytes, src.optLegacyWholeChannel());
            }
            src.writeInto(study, null);
        }
        long t1 = System.nanoTime();
        long insz = Files.size(in);
        double wall = (t1 - t0) / 1e9;
        long peakMb = 0;
        for (var pool : java.lang.management.ManagementFactory.getMemoryPoolMXBeans()) {
            var peak = pool.getPeakUsage();
            if (peak != null) peakMb += peak.getUsed() / (1024 * 1024);
        }
        System.out.printf("[java-bench] FASTQ encode %d B in %.1f s: %.1f MB/s, peak %d MB%n",
            insz, wall, insz / wall / 1048576.0, peakMb);
    }
}
