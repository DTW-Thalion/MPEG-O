// SPDX-License-Identifier: Apache-2.0
package global.thalion.ttio.importers;

import global.thalion.ttio.genomics.GenomicRun;
import global.thalion.ttio.providers.MemoryProvider;
import global.thalion.ttio.providers.StorageGroup;
import global.thalion.ttio.providers.StorageProvider;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.zip.GZIPOutputStream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class FastqParallelProducerTest {

    static Path writeGzFixture(Path tmp, int reads, int len) throws Exception {
        Path fq = tmp.resolve("par.fastq.gz");
        int rs = 12345;
        byte[] seq = new byte[len], qual = new byte[len];
        try (GZIPOutputStream gz = new GZIPOutputStream(java.nio.file.Files.newOutputStream(fq))) {
            for (int i = 0; i < reads; i++) {
                for (int j = 0; j < len; j++) {
                    rs = rs * 1103515245 + 12345;
                    seq[j] = (byte) "ACGT".charAt((rs >>> 16) & 3);
                    qual[j] = (byte) (33 + ((rs >>> 18) & 31));
                }
                gz.write(("@r" + i + " desc\n").getBytes(StandardCharsets.ISO_8859_1));
                gz.write(seq); gz.write('\n'); gz.write('+'); gz.write('\n');
                gz.write(qual); gz.write('\n');
            }
        }
        return fq;
    }

    static StorageGroup writeVia(Path fq, String url, long batchBytes) {
        StorageGroup root = new MemoryProvider().open(url, StorageProvider.Mode.CREATE).rootGroup();
        StorageGroup study = root.createGroup("study");
        new FastqReader(fq).stream("g", "s", Integer.MAX_VALUE, batchBytes)
            .writeInto(study, null);
        return study;
    }

    /** The parallel side pins {@code ttio.threads}: the default resolver
     *  yields 1 on small CI hosts, which would silently compare the
     *  serial path against itself. */
    static StorageGroup writeViaThreads(Path fq, String url, long batchBytes,
                                        String threads) {
        System.setProperty("ttio.threads", threads);
        try {
            return writeVia(fq, url, batchBytes);
        } finally {
            System.clearProperty("ttio.threads");
        }
    }

    @Test
    void pipelineIdenticalToSerial(@TempDir Path tmp) throws Exception {
        Path fq = writeGzFixture(tmp, 20_000, 4096);
        StorageGroup a = writeViaThreads(fq, "memory://fpp-a", 4L << 20, "3");
        System.setProperty("ttio.threads", "1");
        StorageGroup b;
        try {
            b = writeVia(fq, "memory://fpp-b", 4L << 20);
        } finally {
            System.clearProperty("ttio.threads");
        }
        GenomicRun ga = GenomicRun.readFrom(a.openGroup("genomic_runs").openGroup("g"), "g");
        GenomicRun gb = GenomicRun.readFrom(b.openGroup("genomic_runs").openGroup("g"), "g");
        assertEquals(20_000, ga.readCount());
        assertEquals(gb.readCount(), ga.readCount());
        int[] idxs = {0, 1, 9_999, 10_000, 19_998, 19_999};
        for (int i : idxs) {
            var ra = ga.readAt(i);
            var rb = gb.readAt(i);
            assertEquals(rb.readName(), ra.readName(), "name at " + i);
            assertEquals(rb.sequence(), ra.sequence(), "sequence at " + i);
            assertTrue(java.util.Arrays.equals(rb.qualities(), ra.qualities()), "quals at " + i);
        }
    }

    static Path writePlainFixture(Path tmp, String name, int reads, int bigEvery, int bigLen)
            throws Exception {
        Path fq = tmp.resolve(name);
        int rs = 777;
        try (var out = java.nio.file.Files.newOutputStream(fq)) {
            byte[] big = new byte[bigLen];
            for (int i = 0; i < reads; i++) {
                int len = (bigEvery > 0 && i % bigEvery == 0) ? bigLen : 120;
                out.write(("@s" + i + " x\n").getBytes(StandardCharsets.ISO_8859_1));
                for (int j = 0; j < len; j++) {
                    rs = rs * 1103515245 + 12345;
                    big[j] = (byte) "ACGT".charAt((rs >>> 16) & 3);
                }
                out.write(big, 0, len);
                out.write("\n+\n".getBytes(StandardCharsets.ISO_8859_1));
                for (int j = 0; j < len; j++) {
                    rs = rs * 1103515245 + 12345;
                    big[j] = (byte) (33 + ((rs >>> 18) & 31));
                }
                out.write(big, 0, len);
                out.write('\n');
            }
        }
        return fq;
    }

    static String spotDigest(StorageGroup study, int expectReads) {
        GenomicRun g = GenomicRun.readFrom(study.openGroup("genomic_runs").openGroup("g"), "g");
        assertEquals(expectReads, g.readCount());
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < g.readCount(); i += Math.max(1, g.readCount() / 97)) {
            var r = g.readAt(i);
            sb.append(r.readName()).append('|').append(r.sequence())
              .append('|').append(java.util.Arrays.hashCode(r.qualities())).append('\n');
        }
        return sb.toString();
    }

    @Test
    void shardIdenticalToSerial(@TempDir Path tmp) throws Exception {
        // Mixed lengths: mostly 120 B with a 100 KiB read every 500.
        Path fq = writePlainFixture(tmp, "shard.fastq", 30_000, 500, 100 * 1024);
        StorageGroup a = writeViaThreads(fq, "memory://fps-a", 1L << 20, "3");
        System.setProperty("ttio.threads", "1");
        StorageGroup b;
        try {
            b = writeVia(fq, "memory://fps-b", 1L << 20);
        } finally {
            System.clearProperty("ttio.threads");
        }
        assertEquals(spotDigest(b, 30_000), spotDigest(a, 30_000));
    }

    @Test
    void sparseShardsIdenticalToSerial(@TempDir Path tmp) throws Exception {
        // Two 200 KiB records with a 64 KiB batch limit: the file
        // shards, most ranges are empty, order still holds.
        Path fq = writePlainFixture(tmp, "shard2.fastq", 2, 1, 200 * 1024);
        StorageGroup a = writeViaThreads(fq, "memory://fps2-a", 64L << 10, "3");
        System.setProperty("ttio.threads", "1");
        StorageGroup b;
        try {
            b = writeVia(fq, "memory://fps2-b", 64L << 10);
        } finally {
            System.clearProperty("ttio.threads");
        }
        assertEquals(spotDigest(b, 2), spotDigest(a, 2));
    }
}
