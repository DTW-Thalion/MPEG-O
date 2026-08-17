/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.genomics;

import global.thalion.ttio.SpectralDataset;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Iterator;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

/** The committed Python-written {@code blocks_v1} golden fixture: the
 *  cross-language decode contract for the block layout. */
class BlocksV1GoldenTest {

    static final Path GOLDEN = Paths.get("..", "python", "tests", "fixtures", "genomic", "blocks_v1_golden.tio");
    static final Path SAM = Paths.get("src", "test", "resources", "ttio", "fixtures", "genomic", "m87_test.sam");

    /** md5 over the sorted SAM 11-column lines, RNEXT {@code =} expanded
     *  to RNAME; the same digest as {@code python/tests/_digests.py}. */
    static String md5Lines(List<String> lines) throws Exception {
        List<String> sorted = new ArrayList<>(lines);
        Collections.sort(sorted);
        MessageDigest md = MessageDigest.getInstance("MD5");
        for (String l : sorted) {
            md.update(l.getBytes(StandardCharsets.UTF_8));
            md.update((byte) '\n');
        }
        StringBuilder sb = new StringBuilder();
        for (byte b : md.digest()) sb.append(String.format("%02x", b));
        return sb.toString();
    }

    static String sam11Md5FromSam(Path sam) throws Exception {
        List<String> lines = new ArrayList<>();
        for (String line : Files.readAllLines(sam)) {
            if (line.startsWith("@") || line.isEmpty()) continue;
            String[] c = line.split("\t", 12);
            String[] cols = new String[11];
            System.arraycopy(c, 0, cols, 0, 11);
            if (cols[6].equals("=")) cols[6] = cols[2];
            lines.add(String.join("\t", cols));
        }
        return md5Lines(lines);
    }

    static String sam11Md5FromRun(GenomicRun run) throws Exception {
        List<String> lines = new ArrayList<>();
        Iterator<AlignedRead> it = run.iterReads();
        while (it.hasNext()) {
            AlignedRead r = it.next();
            String seq = (r.sequence() == null || r.sequence().isEmpty()) ? "*" : r.sequence();
            byte[] q = r.qualities();
            String qual;
            if (q == null || q.length == 0) {
                qual = "*";
            } else {
                boolean allFF = true;
                for (byte b : q) if ((b & 0xFF) != 0xFF) { allFF = false; break; }
                qual = allFF ? "*" : new String(q, StandardCharsets.ISO_8859_1);
            }
            String rnext = (r.mateChromosome() == null || r.mateChromosome().isEmpty()) ? "*" : r.mateChromosome();
            lines.add(String.join("\t",
                (r.readName() == null || r.readName().isEmpty()) ? "*" : r.readName(),
                Integer.toString(r.flags()),
                (r.chromosome() == null || r.chromosome().isEmpty()) ? "*" : r.chromosome(),
                Long.toString(r.position()),
                Integer.toString(r.mappingQuality()),
                (r.cigar() == null || r.cigar().isEmpty()) ? "*" : r.cigar(),
                rnext,
                Long.toString(r.matePosition()),
                Integer.toString(r.templateLength()),
                seq, qual));
        }
        return md5Lines(lines);
    }

    @Test
    void goldenLayout() {
        assumeTrue(Files.exists(GOLDEN), "golden fixture present");
        try (SpectralDataset ds = SpectralDataset.open(GOLDEN.toString())) {
            GenomicRun g = ds.genomicRuns().get("genomic_0001");
            assertEquals("blocks_v1", g.layout());
            assertEquals(4, g.blockCount());
            assertEquals(10, g.readCount());
        }
    }

    @Test
    void goldenReadsMatchSourceSam() throws Exception {
        assumeTrue(Files.exists(GOLDEN), "golden fixture present");
        try (SpectralDataset ds = SpectralDataset.open(GOLDEN.toString())) {
            assertEquals(sam11Md5FromSam(SAM), sam11Md5FromRun(ds.genomicRuns().get("genomic_0001")));
        }
    }
}
