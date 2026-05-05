/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.tools;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.FeatureFlags;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.genomics.WrittenGenomicRun;

import java.util.ArrayList;
import java.util.List;

/**
 * One-shot fixture writer used by the M82.4 cross-language conformance
 * matrix. Writes a deterministic 100-read genomic-only .tio file to the
 * path given on the command line, then exits.
 *
 * <p>The shape mirrors {@code python/tests/fixtures/genomic/generate.py}
 * and {@code TtioWriteGenomicFixture.m}: same title, ISA id, run name,
 * 100 reads × 150 bases, ACGT cycled, qualities = 30, chromosomes round-
 * robin over {chr1,chr2,chrX}, positions 10_000 + (i/3)*100. Sequence
 * bases are intentionally generated with a portable cycle (not a
 * platform RNG) so all three writers produce <em>identical</em> bytes.</p>
 *
 * <p>Usage:
 * {@code java -cp ... global.thalion.ttio.tools.TtioWriteGenomicFixture <out-path>}</p>
 *
 * M82.4
 */
public final class TtioWriteGenomicFixture {

    private TtioWriteGenomicFixture() {}

    public static void main(String[] args) {
        if (args.length < 1) {
            System.err.println("usage: TtioWriteGenomicFixture <out-path>");
            System.exit(2);
        }
        try {
            WrittenGenomicRun run = build();
            SpectralDataset.create(
                args[0],
                "m82-cross-lang-fixture",
                "ISA-M82-100",
                List.of(),
                List.of(run),
                List.of(),
                List.of(),
                List.of(),
                FeatureFlags.defaultCurrent()
            ).close();
        } catch (Exception e) {
            System.err.println("TtioWriteGenomicFixture: " + e.getMessage());
            System.exit(1);
        }
    }

    /** Builds the deterministic fixture. Public so tests can reuse. */
    public static WrittenGenomicRun build() {
        final int nReads = 100;
        final int readLength = 150;
        String[] chromsPool = {"chr1", "chr2", "chrX"};
        char[] bases = {'A', 'C', 'G', 'T'};

        List<String> chromosomes = new ArrayList<>(nReads);
        long[] positions = new long[nReads];
        int[] flags = new int[nReads];
        byte[] mapqs = new byte[nReads];
        long[] offsets = new long[nReads];
        int[] lengths = new int[nReads];
        List<String> cigars = new ArrayList<>(nReads);
        List<String> readNames = new ArrayList<>(nReads);
        List<String> mateChroms = new ArrayList<>(nReads);
        long[] matePos = new long[nReads];
        int[] tlens = new int[nReads];

        for (int i = 0; i < nReads; i++) {
            chromosomes.add(chromsPool[i % 3]);
            positions[i] = 10_000L + (i / 3) * 100L;
            flags[i] = 0;
            mapqs[i] = 60;
            offsets[i] = (long) i * readLength;
            lengths[i] = readLength;
            cigars.add(readLength + "M");
            readNames.add(String.format("read_%06d", i));
            mateChroms.add("");
            matePos[i] = -1L;
            tlens[i] = 0;
        }

        byte[] sequences = new byte[nReads * readLength];
        for (int i = 0; i < sequences.length; i++) {
            sequences[i] = (byte) bases[i % 4];
        }
        byte[] qualities = new byte[nReads * readLength];
        java.util.Arrays.fill(qualities, (byte) 30);

        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS,
            "GRCh38.p14", "ILLUMINA", "NA12878",
            positions, mapqs, flags, sequences, qualities,
            offsets, lengths, cigars, readNames, mateChroms,
            matePos, tlens, chromosomes, Compression.ZLIB);
    }
}
