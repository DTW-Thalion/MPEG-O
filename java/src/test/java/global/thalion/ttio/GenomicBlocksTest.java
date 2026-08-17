/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.genomics.AlignedRead;
import global.thalion.ttio.genomics.GenomicRun;
import global.thalion.ttio.genomics.GenomicWriteContext;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.importers.BamReader;
import global.thalion.ttio.providers.MemoryProvider;
import global.thalion.ttio.providers.StorageGroup;
import global.thalion.ttio.providers.StorageProvider;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Paths;
import java.util.LinkedHashMap;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/** The whole-channel genomic writer over a memory-provider root, and the
 *  block encoder built on it. */
class GenomicBlocksTest {

    static WrittenGenomicRun m87() throws IOException {
        return new BamReader(Paths.get("src", "test", "resources", "ttio",
                "fixtures", "genomic", "m87_test.bam")).toGenomicRun("genomic_0001");
    }

    static StorageGroup memRoot(String url) {
        return new MemoryProvider().open(url, StorageProvider.Mode.CREATE).rootGroup();
    }

    @Test
    void v18WriterRoundTripsThroughMemoryProvider() throws Exception {
        WrittenGenomicRun run = m87();
        StorageGroup root = memRoot("memory://gb-roundtrip");
        SpectralDatasetGenomicWriter.writeGenomicRunSubtree(root, "r", run,
                GenomicWriteContext.none());
        try (GenomicRun g = GenomicRun.readFrom(root.openGroup("r"), "r")) {
            assertEquals(run.readCount(), g.readCount());
            for (int i = 0; i < run.readCount(); i++) {
                AlignedRead r = g.readAt(i);
                assertEquals(run.readNames().get(i), r.readName());
                assertEquals(run.cigars().get(i), r.cigar());
                assertEquals(run.chromosomes().get(i), r.chromosome());
                assertEquals(run.positions()[i], r.position());
            }
        }
        MemoryProvider.discardStore("memory://gb-roundtrip");
    }

    @Test
    void sharedChromMapGivesStableIdsAcrossWrites() throws Exception {
        WrittenGenomicRun run = m87();
        Map<String, Integer> shared = new LinkedHashMap<>();
        shared.put("chrZ", 0);
        StorageGroup root = memRoot("memory://gb-shared");
        SpectralDatasetGenomicWriter.writeGenomicRunSubtree(root, "a", run,
                new GenomicWriteContext(shared, null));
        short[] ids = (short[]) root.openGroup("a").openGroup("genomic_index")
                .openDataset("chromosome_ids").readAll();
        String first = run.chromosomes().get(0);
        assertTrue(shared.get(first) >= 1, "pre-seeded id 0 must survive");
        assertEquals(shared.get(first).intValue(), ids[0]);
        // the run-level name tables list names in id order, chrZ first
        var names = root.openGroup("a").openGroup("genomic_index")
                .openDataset("chromosome_names").readRows();
        assertEquals("chrZ", names.get(0).get("name").toString());
        MemoryProvider.discardStore("memory://gb-shared");
    }
}
