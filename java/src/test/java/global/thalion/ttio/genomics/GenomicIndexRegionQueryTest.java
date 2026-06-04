/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.genomics;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.FeatureFlags;
import global.thalion.ttio.SpectralDataset;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * PJ1 equivalence suite for {@link GenomicIndex#indicesForRegion} and
 * {@link GenomicIndex#indicesForFlag}.
 *
 * <p>The perf optimization (interned-id region scan on disk-loaded
 * indices) must return IDENTICAL indices in IDENTICAL ascending order
 * as a straightforward independent reference computed in-test from
 * {@code chromosomeAt(i)} + {@code positionAt(i)} / {@code flagsAt(i)}.
 * Both the disk-loaded (interned-id) path AND the in-memory
 * (string-fallback) path are exercised over the same battery.</p>
 */
class GenomicIndexRegionQueryTest {

    // ── Fixture: a varied multi-chromosome index ───────────────────

    /** Chromosomes, positions and flags for the battery. ≥2 chromosomes,
     *  reads interleaved across them at varied positions including
     *  duplicate positions and boundary-relevant values. */
    private static final String[] CHROMS = {
        "chr1", "chr2", "chr1", "chrX", "chr1", "chr2",
        "chr1", "chrX", "chr2", "chr1", "chr1", "chrX",
    };
    private static final long[] POSITIONS = {
        100, 100, 200, 100, 100, 500,
        300, 900, 200, 100, 400, 100,
    };
    private static final int[] FLAGS = {
        0x0, 0x4, 0x10, 0x1, 0x4, 0x0,
        0x10, 0x4, 0x1, 0x0, 0x11, 0x4,
    };

    private static GenomicIndex makeInMemoryIndex() {
        int n = CHROMS.length;
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        byte[] mapqs = new byte[n];
        for (int i = 0; i < n; i++) {
            offsets[i] = (long) i * 150;
            lengths[i] = 150;
            mapqs[i] = 60;
        }
        return new GenomicIndex(offsets, lengths, List.of(CHROMS),
            POSITIONS.clone(), mapqs, FLAGS.clone());
    }

    /** Write a genomic .tio from the fixture and reopen it so the
     *  returned index is DISK-LOADED (carries interned chromosome ids). */
    private static GenomicIndex makeDiskLoadedIndex(Path tmp) {
        int n = CHROMS.length;
        int readLength = 150;
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        byte[] mapqs = new byte[n];
        for (int i = 0; i < n; i++) {
            offsets[i] = (long) i * readLength;
            lengths[i] = readLength;
            mapqs[i] = 60;
        }
        byte[] sequences = new byte[n * readLength];
        char[] bases = {'A', 'C', 'G', 'T'};
        for (int i = 0; i < sequences.length; i++) {
            sequences[i] = (byte) bases[i % 4];
        }
        byte[] qualities = new byte[n * readLength];
        java.util.Arrays.fill(qualities, (byte) 30);

        List<String> cigars = new ArrayList<>(n);
        List<String> readNames = new ArrayList<>(n);
        List<String> mateChroms = new ArrayList<>(n);
        long[] matePos = new long[n];
        int[] tlens = new int[n];
        for (int i = 0; i < n; i++) {
            cigars.add(readLength + "M");
            readNames.add(String.format("read_%06d", i));
            mateChroms.add("");
            matePos[i] = -1L;
            tlens[i] = 0;
        }

        WrittenGenomicRun run = new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS, "GRCh38.p14", "ILLUMINA", "NA12878",
            POSITIONS.clone(), mapqs, FLAGS.clone(), sequences, qualities,
            offsets, lengths, cigars, readNames, mateChroms,
            matePos, tlens, List.of(CHROMS), Compression.ZLIB);

        Path file = tmp.resolve("pj1.tio");
        SpectralDataset.create(file.toString(), "t", "i",
            List.of(), List.of(run),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();

        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertNotNull(gr);
            // Force eager materialization of an in-memory copy that
            // survives ds.close(): the GenomicIndex holds plain arrays.
            return gr.index();
        }
    }

    // ── Independent reference implementations (the contract) ───────

    private static List<Integer> referenceRegion(
            GenomicIndex idx, String chromosome, long start, long end) {
        List<Integer> out = new ArrayList<>();
        for (int i = 0; i < idx.count(); i++) {
            if (idx.chromosomeAt(i).equals(chromosome)
                    && idx.positionAt(i) >= start
                    && idx.positionAt(i) < end) {
                out.add(i);
            }
        }
        return out;
    }

    private static List<Integer> referenceFlag(GenomicIndex idx, int mask) {
        List<Integer> out = new ArrayList<>();
        for (int i = 0; i < idx.count(); i++) {
            if ((idx.flagsAt(i) & mask) != 0) out.add(i);
        }
        return out;
    }

    // ── The query battery, run against any index ──────────────────

    private record RegionQuery(String chrom, long start, long end) {}

    private static final List<RegionQuery> REGION_BATTERY = List.of(
        new RegionQuery("chr1", 100, 300),        // sub-range
        new RegionQuery("chr1", 0, 1_000_000),    // full range
        new RegionQuery("chr1", 100, 100),        // empty range (start==end)
        new RegionQuery("chr1", 100, 101),        // boundary: read at start included
        new RegionQuery("chr1", 100, 200),        // boundary: read at end excluded
        new RegionQuery("chr2", 100, 600),        // second chromosome
        new RegionQuery("chrX", 100, 1000),       // third chromosome
        new RegionQuery("chrX", 900, 901),        // single isolated position
        new RegionQuery("chrY", 0, 1_000_000),    // chromosome NOT present → empty
        new RegionQuery("chr1", 1000, 100)        // inverted range → empty
    );

    private static final List<Integer> FLAG_BATTERY =
        List.of(0x4, 0x10, 0x1, 0x11, 0x0, 0x800);

    private static void runBattery(GenomicIndex idx, String label) {
        for (RegionQuery q : REGION_BATTERY) {
            List<Integer> expected = referenceRegion(idx, q.chrom(), q.start(), q.end());
            List<Integer> actual = idx.indicesForRegion(q.chrom(), q.start(), q.end());
            assertEquals(expected, actual,
                label + " region " + q.chrom() + "[" + q.start() + "," + q.end() + ")");
        }
        for (int mask : FLAG_BATTERY) {
            List<Integer> expected = referenceFlag(idx, mask);
            List<Integer> actual = idx.indicesForFlag(mask);
            assertEquals(expected, actual,
                label + " flag 0x" + Integer.toHexString(mask));
        }
        // indicesForUnmapped is the 0x4 convenience path.
        assertEquals(referenceFlag(idx, 0x4), idx.indicesForUnmapped(),
            label + " unmapped");
    }

    // ── Tests ─────────────────────────────────────────────────────

    @Test
    void diskLoadedIndexMatchesReference(@TempDir Path tmp) {
        GenomicIndex idx = makeDiskLoadedIndex(tmp);
        runBattery(idx, "disk");
    }

    @Test
    void inMemoryIndexMatchesReference() {
        GenomicIndex idx = makeInMemoryIndex();
        runBattery(idx, "in-memory");
    }

    @Test
    void diskAndInMemoryAgree(@TempDir Path tmp) {
        GenomicIndex disk = makeDiskLoadedIndex(tmp);
        GenomicIndex mem = makeInMemoryIndex();
        for (RegionQuery q : REGION_BATTERY) {
            assertEquals(
                mem.indicesForRegion(q.chrom(), q.start(), q.end()),
                disk.indicesForRegion(q.chrom(), q.start(), q.end()),
                "disk vs in-memory region " + q.chrom());
        }
        for (int mask : FLAG_BATTERY) {
            assertEquals(
                mem.indicesForFlag(mask),
                disk.indicesForFlag(mask),
                "disk vs in-memory flag 0x" + Integer.toHexString(mask));
        }
    }
}
