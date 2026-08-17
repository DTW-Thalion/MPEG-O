/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.genomics;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.importers.FastqReader;
import global.thalion.ttio.importers.ImportedDataset;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfSystemProperty;
import org.junit.jupiter.api.io.TempDir;

import java.io.BufferedWriter;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Random;

import static org.junit.jupiter.api.Assertions.*;

/** Memory ceiling of a streamed FASTQ import: 1 M synthetic 100 bp
 *  reads through {@link FastqReader#stream} in a forked JVM capped at
 *  768 MB of heap. Runs with {@code -Dttio.slow=true}. */
class StreamingMemoryTest {

    static final int READS = 1_000_000;

    /** Forked entry point: import {@code args[0]} to {@code args[1]}. */
    public static void main(String[] args) throws Exception {
        ImportedDataset d = new ImportedDataset();
        d.genomicStreams.put("genomic_0001", new FastqReader(Path.of(args[0])).stream("genomic_0001", "synthetic"));
        d.write(Path.of(args[1]));
    }

    static void writeFastq(Path p) throws IOException {
        Random rnd = new Random(1);
        char[] bases = {'A', 'C', 'G', 'T'};
        try (BufferedWriter w = Files.newBufferedWriter(p, StandardCharsets.US_ASCII)) {
            char[] seq = new char[100];
            char[] qual = new char[100];
            for (int i = 0; i < READS; i++) {
                for (int j = 0; j < 100; j++) {
                    seq[j] = bases[rnd.nextInt(4)];
                    qual[j] = (char) ('#' + rnd.nextInt(40));
                }
                w.write("@r" + i + "\n");
                w.write(seq);
                w.write("\n+\n");
                w.write(qual);
                w.write("\n");
            }
        }
    }

    @Test
    @EnabledIfSystemProperty(named = "ttio.slow", matches = "true")
    void oneMillionReadsImportUnder768MbHeap(@TempDir Path tmp) throws Exception {
        Path fq = tmp.resolve("reads.fq");
        writeFastq(fq);
        Path out = tmp.resolve("out.tio");
        String javaBin = Path.of(System.getProperty("java.home"), "bin", "java").toString();
        List<String> cmd = new java.util.ArrayList<>(List.of(javaBin, "-Xmx768m",
            "--enable-native-access=ALL-UNNAMED",
            "-Djava.library.path=" + System.getProperty("java.library.path", ""),
            "-cp", System.getProperty("java.class.path"),
            StreamingMemoryTest.class.getName(), fq.toString(), out.toString()));
        Process p = new ProcessBuilder(cmd).redirectErrorStream(true).start();
        String log = new String(p.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
        int rc = p.waitFor();
        assertEquals(0, rc, "forked import failed:\n" + log);
        assertFalse(log.contains("OutOfMemoryError"), log);
        try (SpectralDataset ds = SpectralDataset.open(out.toString())) {
            GenomicRun g = ds.genomicRuns().get("genomic_0001");
            assertEquals("blocks_v1", g.layout());
            assertEquals(READS, g.readCount());
            assertEquals(1, g.blockCount());
            assertEquals("r0", g.readAt(0).readName());
            assertEquals("r" + (READS - 1), g.readAt(READS - 1).readName());
        }
    }
}
