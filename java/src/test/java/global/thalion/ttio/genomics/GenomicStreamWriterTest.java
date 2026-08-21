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

    // ── block-parallel writer ─────────────────────────────────────────

    /** Two chromosomes, placed-unmapped reads (every 97th, cigar "*"),
     *  cross-chromosome mates (every 13th), "=" mates (every 3rd);
     *  mirrors the Python test's _big_synthetic_run. */
    static WrittenGenomicRun bigSyntheticRun(int n, long seed) {
        java.util.Random rng = new java.util.Random(seed);
        final int L = 100;
        byte[] alphabet = {'A', 'C', 'G', 'T'};
        byte[] ref1 = new byte[400_000], ref2 = new byte[400_000];
        for (int i = 0; i < ref1.length; i++) { ref1[i] = alphabet[rng.nextInt(4)]; ref2[i] = alphabet[rng.nextInt(4)]; }
        Map<String, byte[]> refs = new java.util.LinkedHashMap<>();
        refs.put("chr1", ref1); refs.put("chr2", ref2);
        int half = n / 2;
        long[] pos1 = new long[half], pos2 = new long[n - half];
        for (int i = 0; i < half; i++) pos1[i] = 1 + rng.nextInt(399_000);
        for (int i = 0; i < n - half; i++) pos2[i] = 1 + rng.nextInt(399_000);
        Arrays.sort(pos1); Arrays.sort(pos2);
        long[] positions = new long[n];
        List<String> chroms = new java.util.ArrayList<>(n);
        for (int i = 0; i < half; i++) { positions[i] = pos1[i]; chroms.add("chr1"); }
        for (int i = 0; i < n - half; i++) { positions[half + i] = pos2[i]; chroms.add("chr2"); }
        byte[] seqs = new byte[n * L], quals = new byte[n * L];
        int[] flags = new int[n];
        long[] mpos = new long[n];
        int[] tlen = new int[n];
        List<String> cigars = new java.util.ArrayList<>(n), names = new java.util.ArrayList<>(n), mates = new java.util.ArrayList<>(n);
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        byte[] mq = new byte[n];
        for (int i = 0; i < n; i++) {
            byte[] ref = refs.get(chroms.get(i));
            int p0 = (int) positions[i] - 1;
            System.arraycopy(ref, p0, seqs, i * L, L);
            for (int k = 0; k < 3; k++) seqs[i * L + rng.nextInt(L)] = alphabet[rng.nextInt(4)];
            for (int k = 0; k < L; k++) quals[i * L + k] = (byte) (2 + rng.nextInt(38));
            offsets[i] = (long) i * L; lengths[i] = L; mq[i] = 60;
            names.add(String.format("r%06d", i));
            flags[i] = 0x3; mpos[i] = -1;
            if (i % 97 == 0) { cigars.add("*"); flags[i] = 0x5; } else cigars.add(L + "M");
            if (i % 13 == 0) { mates.add(chroms.get(i).equals("chr1") ? "chr2" : "chr1"); mpos[i] = positions[(i * 7) % n]; }
            else if (i % 3 == 0) { mates.add("="); mpos[i] = positions[i] + 200; }
            else mates.add("");
        }
        return new WrittenGenomicRun(
            global.thalion.ttio.Enums.AcquisitionMode.GENOMIC_WGS,
            "synthetic", "ILLUMINA", "s",
            positions, mq, flags, seqs, quals, offsets, lengths,
            cigars, names, mates, mpos, tlen, chroms,
            global.thalion.ttio.Enums.Compression.ZLIB)
            .withReference(true, refs, null);
    }

    static long lastMaxInFlight;

    static StorageGroup writeWithBudget(String url, WrittenGenomicRun run, int threads,
                                        int blockReads, long budget) {
        StorageGroup study = study(url);
        GenomicStreamWriter.Options o = GenomicStreamWriter.Options.fromRun(run)
            .withBlockPolicy(blockReads, Long.MAX_VALUE);
        if (run.referenceChromSeqs() != null) o = o.withReference(run.referenceChromSeqs(), true);
        try (GenomicStreamWriter w = new GenomicStreamWriter(study, "g", o, threads, budget)) {
            int n = run.readCount();
            for (int a = 0; a < n; a += 7_001) {
                w.appendBatch(GenomicBlocks.sliceRun(run, a, Math.min(n, a + 7_001)));
            }
            lastMaxInFlight = w.maxInFlightBytesObserved();
        }
        return study;
    }

    @org.junit.jupiter.api.Test
    void budgetBoundsInFlightBytes() {
        WrittenGenomicRun run = bigSyntheticRun(40_000, 5);
        long budget = 4L << 20;
        StorageGroup a = writeWithBudget("memory://gswb-a", run, 6, 2_000, budget);
        long maxObs = lastMaxInFlight;
        StorageGroup b = writeWithBudget("memory://gswb-b", run, 1, 2_000, budget);
        org.junit.jupiter.api.Assertions.assertTrue(maxObs > 0 && maxObs <= budget,
            "in-flight bytes " + maxObs + " within " + budget);
        Map<String, String> ma = new java.util.TreeMap<>(), mb = new java.util.TreeMap<>();
        collect(a, "", ma);
        collect(b, "", mb);
        assertEquals(ma.keySet(), mb.keySet());
        for (String k : ma.keySet()) assertEquals(ma.get(k), mb.get(k), k + " differs under the budget");
    }

    static StorageGroup writeWithThreads(String url, WrittenGenomicRun run, int threads, int blockReads) {
        StorageGroup study = study(url);
        GenomicStreamWriter.Options o = GenomicStreamWriter.Options.fromRun(run)
            .withBlockPolicy(blockReads, Long.MAX_VALUE);
        if (run.referenceChromSeqs() != null) o = o.withReference(run.referenceChromSeqs(), true);
        try (GenomicStreamWriter w = new GenomicStreamWriter(study, "g", o, threads)) {
            int n = run.readCount();
            for (int a = 0; a < n; a += 7_001) {
                w.appendBatch(GenomicBlocks.sliceRun(run, a, Math.min(n, a + 7_001)));
            }
            assertEquals(threads, w.threads());
        }
        return study;
    }

    static String canon(Object raw) {
        if (raw == null) return "null";
        if (raw instanceof byte[] a) return Arrays.toString(a);
        if (raw instanceof int[] a) return Arrays.toString(a);
        if (raw instanceof long[] a) return Arrays.toString(a);
        if (raw instanceof short[] a) return Arrays.toString(a);
        if (raw instanceof double[] a) return Arrays.toString(a);
        if (raw instanceof float[] a) return Arrays.toString(a);
        if (raw instanceof Object[] a) {
            StringBuilder b = new StringBuilder("[");
            for (Object o : a) b.append(canon(o)).append(",");
            return b.append("]").toString();
        }
        if (raw instanceof java.util.List<?> l) {
            StringBuilder b = new StringBuilder("L[");
            for (Object o : l) b.append(canon(o)).append(",");
            return b.append("]").toString();
        }
        return String.valueOf(raw);
    }

    static void collect(StorageGroup g, String prefix, Map<String, String> out) {
        StringBuilder attrs = new StringBuilder();
        for (String a : g.attributeNames()) attrs.append(a).append("=").append(canon(g.getAttribute(a))).append(";");
        out.put(prefix, attrs.toString());
        for (String c : g.childNames()) {
            try (StorageGroup sub = g.openGroup(c)) {
                collect(sub, prefix + "/" + c, out);
            } catch (RuntimeException e) {
                try (global.thalion.ttio.providers.StorageDataset ds = g.openDataset(c)) {
                    StringBuilder da = new StringBuilder();
                    for (String a : ds.attributeNames()) da.append(a).append("=").append(canon(ds.getAttribute(a))).append(";");
                    out.put(prefix + "/" + c, da + "|" + canon(ds.readAll()));
                }
            }
        }
    }

    @Test
    void threadedWriterIsByteIdenticalToSerial() throws Exception {
        WrittenGenomicRun run = bigSyntheticRun(60_000, 7);
        StorageGroup a = writeWithThreads("memory://gswt-a", run, 1, 20_000);
        StorageGroup b = writeWithThreads("memory://gswt-b", run, 6, 20_000);
        Map<String, String> ma = new java.util.TreeMap<>(), mb = new java.util.TreeMap<>();
        collect(a, "", ma);
        collect(b, "", mb);
        assertEquals(ma.keySet(), mb.keySet());
        for (String k : ma.keySet()) assertEquals(ma.get(k), mb.get(k), k + " differs between threads=1 and threads=6");
        try (GenomicRun g = GenomicRun.readFrom(b.openGroup("genomic_runs").openGroup("g"), "g")) {
            assertEquals(60_000, g.readCount());
            assertEquals(4, g.blockCount());   // 20k, 10k (chr1 ends), 20k, 10k
        }
    }

    @Test
    void stickyPinMatchesExhaustive() throws Exception {
        WrittenGenomicRun run = bigSyntheticRun(40_000, 11);
        StorageGroup a = writeWithThreads("memory://gsw-sticky", run, 6, 20_000);
        System.setProperty("ttio.m94z.exhaustive", "1");
        StorageGroup b;
        try {
            b = writeWithThreads("memory://gsw-exh", run, 6, 20_000);
        } finally {
            System.clearProperty("ttio.m94z.exhaustive");
        }
        Map<String, String> ma = new java.util.TreeMap<>(), mb = new java.util.TreeMap<>();
        collect(a, "", ma);
        collect(b, "", mb);
        assertEquals(ma.keySet(), mb.keySet());
        for (String k : ma.keySet())
            assertEquals(ma.get(k), mb.get(k), k + " differs between sticky and exhaustive");
    }

    @Test
    void stickyDeterministicAcrossRuns() throws Exception {
        WrittenGenomicRun run = bigSyntheticRun(40_000, 12);
        StorageGroup a = writeWithThreads("memory://gsw-r1", run, 6, 20_000);
        StorageGroup b = writeWithThreads("memory://gsw-r2", run, 6, 20_000);
        Map<String, String> ma = new java.util.TreeMap<>(), mb = new java.util.TreeMap<>();
        collect(a, "", ma);
        collect(b, "", mb);
        assertEquals(ma.keySet(), mb.keySet());
        for (String k : ma.keySet())
            assertEquals(ma.get(k), mb.get(k), k + " differs between repeated runs");
    }

    @Test
    void pinIsSetAfterFirstBlock() throws Exception {
        WrittenGenomicRun run = bigSyntheticRun(40_000, 13);
        StorageGroup study = study("memory://gsw-pin");
        GenomicStreamWriter.Options o = GenomicStreamWriter.Options.fromRun(run)
            .withBlockPolicy(20_000, Long.MAX_VALUE)
            .withReference(run.referenceChromSeqs(), true);
        try (GenomicStreamWriter w = new GenomicStreamWriter(study, "g", o, 2)) {
            w.appendBatch(run);
            w.flush();
            assertTrue(w.qualStrategyHintForTests() != -1);
        }
    }

    /* The hint knob pins the strategy at construction rather than after
     * block 0. V6 is reachable no other way, which is what it is for.
     * Parity with the Python and Objective-C writers. */
    @Test
    void hintPropertyPinsBeforeBlockZero() throws Exception {
        WrittenGenomicRun run = bigSyntheticRun(40_000, 14);
        StorageGroup study = study("memory://gsw-hint");
        GenomicStreamWriter.Options o = GenomicStreamWriter.Options.fromRun(run)
            .withBlockPolicy(20_000, Long.MAX_VALUE)
            .withReference(run.referenceChromSeqs(), true);
        try {
            System.setProperty("ttio.m94z.hint", "8");
            try (GenomicStreamWriter w = new GenomicStreamWriter(study, "g", o, 2)) {
                assertEquals(8, w.qualStrategyHintForTests(),
                             "pinned at construction, before any block");
                w.appendBatch(run);
                w.flush();
                assertEquals(8, w.qualStrategyHintForTests(),
                             "and the pin survives the run");
            }
            int i = 0;
            for (String bad : new String[] { "junk", "0", "-1", " " }) {
                System.setProperty("ttio.m94z.hint", bad);
                try (GenomicStreamWriter w =
                         new GenomicStreamWriter(study, "gb" + (i++), o, 2)) {
                    assertEquals(-1, w.qualStrategyHintForTests(),
                                 "\"" + bad + "\" falls through to the tune");
                }
            }
            System.setProperty("ttio.m94z.hint", "8");
            System.setProperty("ttio.m94z.exhaustive", "1");
            try (GenomicStreamWriter w = new GenomicStreamWriter(study, "ge", o, 2)) {
                assertEquals(-1, w.qualStrategyHintForTests(),
                             "the exhaustive flag wins over the hint");
            }
        } finally {
            System.clearProperty("ttio.m94z.hint");
            System.clearProperty("ttio.m94z.exhaustive");
        }
    }

    @Test
    void registerBlockChromosomesMatchesEncoderOrder() throws Exception {
        WrittenGenomicRun m87 = m87();
        Map<String, Integer> m = new java.util.LinkedHashMap<>();
        GenomicStreamWriter.registerBlockChromosomes(m87, m);
        // m87: chromosomes chr1, chr2, "*"; own names in read order first
        assertEquals(0, m.get("chr1"));
        assertTrue(m.containsKey("chr2") && m.containsKey("*"));
        int size = m.size();
        GenomicStreamWriter.registerBlockChromosomes(m87, m);
        assertEquals(size, m.size());   // idempotent
    }
}
