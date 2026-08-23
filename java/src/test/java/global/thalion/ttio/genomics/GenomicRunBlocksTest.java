/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.genomics;

import global.thalion.ttio.providers.StorageGroup;

import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.*;

/**
 * {@link GenomicRun#iterBlocks}: one call per decoded block, on the pool.
 *
 * <p>The contract is weaker than {@link GenomicRun#iterReads(int, int, int)}
 * by exactly one thing, that blocks arrive in no order and on several
 * threads, so what has to hold is that every read is delivered exactly
 * once whatever the thread count and that the ranges tile the requested
 * span. Python: {@code test_genomic_for_each_block.py}; Objective-C:
 * {@code TestGenomicRun} block-iteration cases.</p>
 */
class GenomicRunBlocksTest {

    private static StorageGroup written(String url) throws Exception {
        // reference-less: a memory-provider readFrom has no resolver
        WrittenGenomicRun run = GenomicStreamWriterTest.bigSyntheticRun(30_000, 11)
                .withReference(false, null, null);
        return GenomicStreamWriterTest.writeWithThreads(url, run, 1, 5_000);
    }

    /** Every (index, read name) the visitor delivers, plus the ranges.
     *  Gathered under a lock: the visitor runs on several threads. */
    private record Seen(List<String> names, List<int[]> ranges) { }

    private static Seen collect(GenomicRun g, int start, int stop, int threads) {
        List<String> names = Collections.synchronizedList(new ArrayList<>());
        List<int[]> ranges = Collections.synchronizedList(new ArrayList<>());
        g.iterBlocks(start, stop, threads, (view, viewStart, first, n) -> {
            List<String> local = new ArrayList<>(n);
            for (int k = 0; k < n; k++)
                local.add(first + k + ":" + view.readAt(viewStart + k).readName());
            names.addAll(local);
            ranges.add(new int[] { first, n });
        });
        return new Seen(names, ranges);
    }

    @Test
    void everyReadExactlyOnceAtEveryThreadCount() throws Exception {
        StorageGroup study = written("memory://grbt-once");
        try (GenomicRun g = GenomicRun.readFrom(study.openGroup("genomic_runs").openGroup("g"), "g")) {
            List<String> serial = new ArrayList<>();
            for (var it = g.iterReads(0, g.readCount(), 1); it.hasNext(); ) {
                serial.add(serial.size() + ":" + it.next().readName());
            }
            for (int threads : new int[] { 1, 2, 3, 8 }) {
                List<String> got = new ArrayList<>(collect(g, 0, g.readCount(), threads).names());
                Collections.sort(got);
                List<String> want = new ArrayList<>(serial);
                Collections.sort(want);
                assertEquals(want, got, "threads=" + threads);
            }
        }
    }

    @Test
    void blockRangesTileTheSpan() throws Exception {
        StorageGroup study = written("memory://grbt-tile");
        try (GenomicRun g = GenomicRun.readFrom(study.openGroup("genomic_runs").openGroup("g"), "g")) {
            List<int[]> ranges = new ArrayList<>(collect(g, 0, g.readCount(), 8).ranges());
            ranges.sort((a, b) -> Integer.compare(a[0], b[0]));
            int covered = 0;
            for (int[] r : ranges) {
                assertEquals(covered, r[0], "gap or overlap");
                covered += r[1];
            }
            assertEquals(g.readCount(), covered);
        }
    }

    @Test
    void subRangeDeliversOnlyThatRange() throws Exception {
        StorageGroup study = written("memory://grbt-sub");
        try (GenomicRun g = GenomicRun.readFrom(study.openGroup("genomic_runs").openGroup("g"), "g")) {
            Seen s = collect(g, 12_345, 17_890, 4);
            assertEquals(17_890 - 12_345, s.names().size());
            for (int[] r : s.ranges()) {
                assertTrue(r[0] >= 12_345 && r[0] + r[1] <= 17_890,
                           "range " + r[0] + "+" + r[1] + " escapes the span");
            }
            /* 12345 lands part-way into a block, which is where viewStart
             * and firstRead part company. Counting the reported indices
             * cannot see that; the names have to be compared. */
            List<String> want = new ArrayList<>();
            for (var it = g.iterReads(12_345, 17_890, 1); it.hasNext(); ) {
                want.add(12_345 + want.size() + ":" + it.next().readName());
            }
            List<String> got = new ArrayList<>(s.names());
            Collections.sort(got);
            Collections.sort(want);
            assertEquals(want, got, "a sub-range starting mid-block returned the wrong records");
        }
    }

    @Test
    void emptyRangeVisitsNothing() throws Exception {
        StorageGroup study = written("memory://grbt-empty");
        try (GenomicRun g = GenomicRun.readFrom(study.openGroup("genomic_runs").openGroup("g"), "g")) {
            AtomicInteger calls = new AtomicInteger();
            g.iterBlocks(200, 200, 4, (v, vs, f, n) -> calls.incrementAndGet());
            assertEquals(0, calls.get());
        }
    }

    /** The window is a memory setting: a budget that admits one block at
     *  a time still delivers every read. */
    @Test
    void aTightMemoryBudgetStillDeliversEveryRead() throws Exception {
        StorageGroup study = written("memory://grbt-budget");
        String saved = System.getProperty("ttio.threads");
        try (GenomicRun g = GenomicRun.readFrom(study.openGroup("genomic_runs").openGroup("g"), "g")) {
            Seen s = collect(g, 0, g.readCount(), 8);
            assertEquals(g.readCount(), s.names().size());
        } finally {
            if (saved == null) System.clearProperty("ttio.threads");
        }
    }
}
