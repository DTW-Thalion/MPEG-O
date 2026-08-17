/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.genomics;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.importers.BamReader;
import global.thalion.ttio.providers.MemoryProvider;
import global.thalion.ttio.providers.ProviderRegistry;
import global.thalion.ttio.providers.StorageGroup;
import global.thalion.ttio.providers.StorageProvider;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Arrays;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/** {@link GenomicStreamWriter}: the blocks_v1 layout on disk. */
class GenomicStreamWriterTest {

    static WrittenGenomicRun m87() throws IOException {
        return new BamReader(Paths.get("src", "test", "resources", "ttio",
                "fixtures", "genomic", "m87_test.bam")).toGenomicRun("genomic_0001");
    }

    static StorageGroup study(String url) {
        StorageGroup root = new MemoryProvider().open(url, StorageProvider.Mode.CREATE).rootGroup();
        return root.createGroup("study");
    }

    static AlignedRead readAt(WrittenGenomicRun run, int i) {
        int o = (int) run.offsets()[i], l = run.lengths()[i];
        return new AlignedRead(run.readNames().get(i), run.chromosomes().get(i),
                run.positions()[i], run.mappingQualities()[i] & 0xFF, run.cigars().get(i),
                new String(run.sequences(), o, l, StandardCharsets.US_ASCII),
                Arrays.copyOfRange(run.qualities(), o, o + l), run.flags()[i],
                run.mateChromosomes().get(i), run.matePositions()[i], run.templateLengths()[i]);
    }

    @Test
    void writesBlocksV1LayoutAndIndex() throws Exception {
        WrittenGenomicRun run = m87();
        StorageGroup study = study("memory://gsw-layout");
        try (GenomicStreamWriter w = new GenomicStreamWriter(study, "genomic_0001",
                GenomicStreamWriter.Options.fromRun(run).withBlockPolicy(4, Long.MAX_VALUE))) {
            w.appendBatch(run);
        }
        StorageGroup rg = study.openGroup("genomic_runs").openGroup("genomic_0001");
        assertEquals("blocks_v1", rg.getAttribute("layout").toString());
        assertEquals(10L, ((Number) rg.getAttribute("read_count")).longValue());
        assertEquals("genomic_0001", study.openGroup("genomic_runs").getAttribute("_run_names").toString());
        List<Map<String, Object>> rows = rg.openGroup("blocks").openDataset("index").readRows();
        long total = 0;
        for (var r : rows) {
            total += ((Number) r.get("n_reads")).longValue();
            assertTrue(((Number) r.get("n_reads")).longValue() <= 4);
        }
        assertEquals(10, total);
        assertEquals(19, rows.get(0).size());
        assertEquals(0L, ((Number) rows.get(0).get("read_start")).longValue());
        assertEquals(0L, ((Number) rows.get(0).get("sequences_off")).longValue());
        assertTrue(((Number) rows.get(0).get("sequences_len")).longValue() > 0);
        assertTrue(rg.openGroup("signal_channels").openGroup("sequences").hasChild("data"));
        assertTrue(rg.openGroup("genomic_index").hasChild("chromosome_names"));
        assertFalse(rg.openGroup("genomic_index").hasChild("offsets"));
        assertTrue(rg.openGroup("signal_channels").openGroup("mate_info").hasChild("chrom_names"));
        assertEquals("reads=4,bytes=" + Long.MAX_VALUE, rg.getAttribute("block_policy").toString());
        MemoryProvider.discardStore("memory://gsw-layout");
    }

    @Test
    void blocksNeverSpanChromosomes() throws Exception {
        WrittenGenomicRun run = m87();
        StorageGroup study = study("memory://gsw-chrom");
        try (GenomicStreamWriter w = new GenomicStreamWriter(study, "g",
                GenomicStreamWriter.Options.fromRun(run))) {
            w.appendBatch(run);
        }
        StorageGroup rg = study.openGroup("genomic_runs").openGroup("g");
        List<Map<String, Object>> rows = rg.openGroup("blocks").openDataset("index").readRows();
        short[] ids = (short[]) rg.openGroup("genomic_index").openDataset("chromosome_ids").readAll();
        for (var r : rows) {
            int s = ((Number) r.get("read_start")).intValue();
            int n = ((Number) r.get("n_reads")).intValue();
            for (int i = s; i < s + n; i++) assertEquals(ids[s], ids[i]);
        }
        // m87 is coordinate-sorted: one block per chromosome run
        int runs = 1;
        for (int i = 1; i < run.readCount(); i++) {
            if (!run.chromosomes().get(i).equals(run.chromosomes().get(i - 1))) runs++;
        }
        assertEquals(runs, rows.size());
        assertEquals(new LinkedHashSet<>(run.chromosomes()).size(),
                rg.openGroup("genomic_index").openDataset("chromosome_names").readRows().size());
        MemoryProvider.discardStore("memory://gsw-chrom");
    }

    @Test
    void legacyFlagWritesWholeChannelLayout() throws Exception {
        WrittenGenomicRun run = m87();
        StorageGroup study = study("memory://gsw-legacy");
        try (GenomicStreamWriter w = new GenomicStreamWriter(study, "g",
                GenomicStreamWriter.Options.fromRun(run).withLegacy(true))) {
            w.appendBatch(run);
        }
        StorageGroup rg = study.openGroup("genomic_runs").openGroup("g");
        assertFalse(rg.hasAttribute("layout"));
        assertFalse(rg.hasChild("blocks"));
        assertEquals(10L, ((Number) rg.getAttribute("read_count")).longValue());
        MemoryProvider.discardStore("memory://gsw-legacy");
    }

    @Test
    void appendSingleReadsEqualsBatch() throws Exception {
        WrittenGenomicRun run = m87();
        StorageGroup study = study("memory://gsw-single");
        try (GenomicStreamWriter w = new GenomicStreamWriter(study, "g",
                GenomicStreamWriter.Options.fromRun(run).withBlockPolicy(3, Long.MAX_VALUE))) {
            for (int i = 0; i < run.readCount(); i++) w.append(readAt(run, i));
        }
        StorageGroup rg = study.openGroup("genomic_runs").openGroup("g");
        assertEquals(10L, ((Number) rg.getAttribute("read_count")).longValue());
        int[] lengths = (int[]) rg.openGroup("genomic_index").openDataset("lengths").readAll();
        assertArrayEquals(run.lengths(), lengths);
        MemoryProvider.discardStore("memory://gsw-single");
    }

    @Test
    void spectralDatasetCreateWritesBlocksV1ByDefault(@TempDir Path tmp) throws Exception {
        WrittenGenomicRun run = m87();
        Path out = tmp.resolve("d.tio");
        SpectralDataset.create(out.toString(), "t", "", List.of(), List.of(run),
                List.of(), List.of(), List.of(), global.thalion.ttio.FeatureFlags.defaultCurrent()).close();
        try (StorageProvider p = ProviderRegistry.open(out.toString(), StorageProvider.Mode.READ, "hdf5")) {
            StorageGroup rg = p.rootGroup().openGroup("study").openGroup("genomic_runs").openGroup("genomic_0001");
            assertEquals("blocks_v1", rg.getAttribute("layout").toString());
            assertTrue(rg.openGroup("blocks").openDataset("index").extendable());
        }
        Path legacy = tmp.resolve("l.tio");
        SpectralDataset.create(legacy.toString(), "t", "", List.of(),
                List.of(run.withOptLegacyWholeChannel(true)), List.of(), List.of(), List.of(), global.thalion.ttio.FeatureFlags.defaultCurrent()).close();
        try (StorageProvider p = ProviderRegistry.open(legacy.toString(), StorageProvider.Mode.READ, "hdf5")) {
            StorageGroup rg = p.rootGroup().openGroup("study").openGroup("genomic_runs").openGroup("genomic_0001");
            assertFalse(rg.hasAttribute("layout"));
        }
    }
}
