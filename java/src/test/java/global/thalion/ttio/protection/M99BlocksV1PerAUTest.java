/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.protection;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.FeatureFlags;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.genomics.AlignedRead;
import global.thalion.ttio.genomics.GenomicBlocks;
import global.thalion.ttio.genomics.GenomicRun;
import global.thalion.ttio.genomics.GenomicStreamWriter;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.providers.ProviderRegistry;
import global.thalion.ttio.providers.StorageDataset;
import global.thalion.ttio.providers.StorageGroup;
import global.thalion.ttio.providers.StorageProvider;

import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

/** M99: per-AU encryption over the blocks_v1 genomic layout. Mirrors
 *  python/tests/test_m99_blocks_v1_per_au.py and the ObjC
 *  TestM99BlocksV1PerAU. */
class M99BlocksV1PerAUTest {

    @TempDir Path tempDir;

    private static byte[] key() {
        byte[] k = new byte[32];
        for (int i = 0; i < 32; i++) k[i] = (byte) (0x51 + i);
        return k;
    }

    /** Deterministic LCG so runs are reproducible. */
    private static final class Lcg {
        private int s;
        Lcg(int seed) { s = seed; }
        int next() {
            s = s * 1664525 + 1013904223;
            return (s >>> 8);
        }
    }

    private static WrittenGenomicRun makeRun(int n, int seed,
                                             int zeroEvery,
                                             boolean crossMates) {
        Lcg rng = new Lcg(seed);
        int[] lengths = new int[n];
        long total = 0;
        for (int i = 0; i < n; i++) {
            int l = 60 + (rng.next() % 140);
            if (zeroEvery > 0 && i > 10 && (i % zeroEvery) == 0) l = 0;
            lengths[i] = l;
            total += l;
        }
        long[] offsets = new long[n];
        long cum = 0;
        for (int i = 0; i < n; i++) { offsets[i] = cum; cum += lengths[i]; }
        byte[] seq = new byte[(int) total];
        byte[] qual = new byte[(int) total];
        byte[] bases = "ACGTN".getBytes(StandardCharsets.US_ASCII);
        for (int i = 0; i < total; i++) {
            seq[i] = bases[rng.next() % 5];
            qual[i] = (byte) (33 + (rng.next() % 40));
        }
        long[] positions = new long[n];
        byte[] mapqs = new byte[n];
        int[] flags = new int[n];
        long[] matePos = new long[n];
        int[] tlens = new int[n];
        List<String> cigars = new ArrayList<>(n);
        List<String> names = new ArrayList<>(n);
        List<String> mateChroms = new ArrayList<>(n);
        List<String> chroms = new ArrayList<>(n);
        int half = n / 2;
        for (int i = 0; i < n; i++) {
            positions[i] = (long) i * 40;
            mapqs[i] = 60;
            flags[i] = crossMates ? 0x1 : 0;
            matePos[i] = crossMates ? (rng.next() % 10000) : -1;
            tlens[i] = crossMates ? ((rng.next() % 1000) - 500) : 0;
            cigars.add(lengths[i] > 0 ? lengths[i] + "M" : "*");
            names.add(String.format("m99r%06d", i));
            String own = i < half ? "chr1" : "chr2";
            chroms.add(own);
            mateChroms.add(crossMates
                ? (i < half ? "chr2" : "chr1") : "");
        }
        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS, "", "ILLUMINA", "M99",
            positions, mapqs, flags, seq, qual, offsets, lengths,
            cigars, names, mateChroms, matePos, tlens, chroms,
            Compression.ZLIB, Map.of(), List.of(), false, null, null,
            null, false, false, null, 0);
    }

    /** An aligned run over an embedded reference: sequences code
     *  through REF_DIFF_V2. */
    private static WrittenGenomicRun makeRefDiffRun() {
        int n = 300, len = 120;
        Lcg rng = new Lcg(33);
        byte[] ref = new byte[60000];
        byte[] bases = "ACGT".getBytes(StandardCharsets.US_ASCII);
        for (int i = 0; i < ref.length; i++) ref[i] = bases[rng.next() % 4];
        byte[] seq = new byte[n * len];
        byte[] qual = new byte[n * len];
        long[] positions = new long[n];
        byte[] mapqs = new byte[n];
        int[] flags = new int[n];
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        long[] matePos = new long[n];
        int[] tlens = new int[n];
        List<String> cigars = new ArrayList<>(n);
        List<String> names = new ArrayList<>(n);
        List<String> mateChroms = new ArrayList<>(n);
        List<String> chroms = new ArrayList<>(n);
        for (int i = 0; i < n; i++) {
            long pos = (long) i * 150 + 1;
            System.arraycopy(ref, (int) pos - 1, seq, i * len, len);
            seq[i * len + 13] = 'A';
            seq[i * len + 77] = 'T';
            for (int k = 0; k < len; k++) {
                qual[i * len + k] = (byte) (33 + (rng.next() % 40));
            }
            positions[i] = pos;
            mapqs[i] = 60;
            flags[i] = 0;
            offsets[i] = (long) i * len;
            lengths[i] = len;
            matePos[i] = -1;
            tlens[i] = 0;
            cigars.add(len + "M");
            names.add("rd" + i);
            mateChroms.add("");
            chroms.add("chr1");
        }
        Map<String, byte[]> refSeqs = new LinkedHashMap<>();
        refSeqs.put("chr1", ref);
        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS, "m99ref", "ILLUMINA", "M99",
            positions, mapqs, flags, seq, qual, offsets, lengths,
            cigars, names, mateChroms, matePos, tlens, chroms,
            Compression.ZLIB, Map.of(), List.of(), true, refSeqs, null,
            null, false, false, null, 0);
    }

    private String writeBlocksFile(String name, WrittenGenomicRun run,
                                   int blockReads) {
        String path = tempDir.resolve(name).toString();
        SpectralDataset.create(path, "M99", "ISA-M99",
            List.of(), List.of(), List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        try (StorageProvider sp = ProviderRegistry.open(path,
                StorageProvider.Mode.READ_WRITE, "hdf5");
             StorageGroup root = sp.rootGroup();
             StorageGroup study = root.openGroup("study")) {
            try (GenomicStreamWriter w = new GenomicStreamWriter(study,
                    "run", GenomicStreamWriter.Options.fromRun(run)
                        .withBlockPolicy(blockReads, Long.MAX_VALUE))) {
                int n = run.readCount();
                for (int st = 0; st < n; st += 100) {
                    w.appendBatch(GenomicBlocks.sliceRun(
                        run, st, Math.min(st + 100, n)));
                }
            }
        }
        return path;
    }

    private record Snapshot(List<Map<String, Object>> index,
                            byte[] seqBlob, byte[] qualBlob) {}

    private static Snapshot snapshot(String path) {
        try (StorageProvider sp = ProviderRegistry.open(path,
                StorageProvider.Mode.READ, "hdf5");
             StorageGroup root = sp.rootGroup();
             StorageGroup study = root.openGroup("study");
             StorageGroup gRuns = study.openGroup("genomic_runs");
             StorageGroup rg = gRuns.openGroup("run")) {
            List<Map<String, Object>> index;
            try (StorageGroup blocks = rg.openGroup("blocks");
                 StorageDataset ds = blocks.openDataset("index")) {
                index = ds.readRows();
            }
            byte[] seq, qual;
            try (StorageGroup sig = rg.openGroup("signal_channels")) {
                try (StorageDataset ds =
                        sig.openGroup("sequences").openDataset("data")) {
                    seq = (byte[]) ds.readAll();
                }
                try (StorageDataset ds = sig.openDataset("qualities")) {
                    qual = (byte[]) ds.readAll();
                }
            }
            return new Snapshot(index, seq, qual);
        }
    }

    private static boolean flagSet(String path) {
        try (StorageProvider sp = ProviderRegistry.open(path,
                StorageProvider.Mode.READ, "hdf5");
             StorageGroup root = sp.rootGroup()) {
            return FeatureFlags.readFrom(root).features()
                .contains(FeatureFlags.OPT_PER_AU_ENCRYPTION);
        }
    }

    @Test
    void encryptStripsChannelsAndAppendsAus() {
        WrittenGenomicRun run = makeRun(900, 3, 0, false);
        String path = writeBlocksFile("shape.tio", run, 200);
        Snapshot before = snapshot(path);

        PerAUFile.encryptFile(path, key(), false, "hdf5");
        assertTrue(flagSet(path), "opt_per_au_encryption set");

        try (StorageProvider sp = ProviderRegistry.open(path,
                StorageProvider.Mode.READ, "hdf5");
             StorageGroup root = sp.rootGroup();
             StorageGroup study = root.openGroup("study");
             StorageGroup gRuns = study.openGroup("genomic_runs");
             StorageGroup rg = gRuns.openGroup("run");
             StorageGroup sig = rg.openGroup("signal_channels")) {
            assertFalse(sig.hasChild("sequences"),
                "plaintext sequences stripped");
            assertFalse(sig.hasChild("qualities"),
                "plaintext qualities stripped");
            try (StorageGroup blocks = rg.openGroup("blocks");
                 StorageDataset ds = blocks.openDataset("index")) {
                assertEquals(before.index(), ds.readRows(),
                    "block index untouched");
            }
            for (String ch : List.of("sequences", "qualities")) {
                List<PerAUEncryption.ChannelSegment> segs =
                    PerAUFile.readChannelSegments(sig, ch + "_segments");
                assertEquals(900, segs.size(),
                    ch + ": one AU per read across blocks");
                long cum = 0;
                for (int i = 0; i < segs.size(); i++) {
                    assertEquals(cum, segs.get(i).offset(),
                        ch + " segment offsets are global");
                    assertEquals(run.lengths()[i], segs.get(i).length());
                    cum += run.lengths()[i];
                }
            }
        }
    }

    private void roundTrip(String tag, WrittenGenomicRun run,
                           int blockReads) {
        String path = writeBlocksFile(tag + ".tio", run, blockReads);
        Snapshot before = snapshot(path);

        PerAUFile.encryptFile(path, key(), false, "hdf5");
        PerAUFile.decryptFileInPlace(path, key(), "hdf5");
        assertFalse(flagSet(path), tag + ": flag stripped");

        Snapshot after = snapshot(path);
        assertEquals(before.index(), after.index(),
            tag + ": block index byte-identical");
        assertArrayEquals(before.seqBlob(), after.seqBlob(),
            tag + ": sequences blob byte-identical");
        assertArrayEquals(before.qualBlob(), after.qualBlob(),
            tag + ": qualities blob byte-identical");

        try (StorageProvider sp = ProviderRegistry.open(path,
                StorageProvider.Mode.READ, "hdf5");
             StorageGroup root = sp.rootGroup();
             StorageGroup study = root.openGroup("study");
             StorageGroup gRuns = study.openGroup("genomic_runs");
             StorageGroup rg = gRuns.openGroup("run")) {
            GenomicRun rd = GenomicRun.readFrom(rg, "run");
            int n = run.readCount();
            for (int i : new int[]{0, n / 2, n - 1}) {
                AlignedRead r = rd.readAt(i);
                int o = (int) run.offsets()[i];
                int l = run.lengths()[i];
                assertEquals(new String(run.sequences(), o, l,
                        StandardCharsets.US_ASCII), r.sequence(),
                    tag + ": restored read " + i + " sequence");
                assertEquals(run.readNames().get(i), r.readName());
                assertArrayEquals(
                    Arrays.copyOfRange(run.qualities(), o, o + l),
                    r.qualities(),
                    tag + ": restored read " + i + " qualities");
            }
        }
    }

    @Test
    void roundTripPlain() {
        roundTrip("plain", makeRun(900, 7, 0, false), 200);
    }

    @Test
    void roundTripZeroLengthReads() {
        roundTrip("zerolen", makeRun(700, 9, 97, false), 150);
    }

    @Test
    void roundTripCrossChromosomeMates() {
        roundTrip("xmates", makeRun(600, 21, 0, true), 150);
    }

    @Test
    void roundTripRefDiff() {
        roundTrip("refdiff", makeRefDiffRun(), 80);
    }
}
