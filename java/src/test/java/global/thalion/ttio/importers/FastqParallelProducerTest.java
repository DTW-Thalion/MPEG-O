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

    @Test
    void pipelineIdenticalToSerial(@TempDir Path tmp) throws Exception {
        Path fq = writeGzFixture(tmp, 20_000, 4096);
        StorageGroup a = writeVia(fq, "memory://fpp-a", 4L << 20);
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
}
