/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.codecs.Quality;
import global.thalion.ttio.codecs.RefDiffV2;
import global.thalion.ttio.genomics.GenomicBlocks;
import global.thalion.ttio.genomics.GenomicRun;
import global.thalion.ttio.genomics.GenomicStreamWriter;
import global.thalion.ttio.genomics.GenomicWriteContext;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.hdf5.Hdf5Dataset;
import global.thalion.ttio.hdf5.Hdf5File;
import global.thalion.ttio.hdf5.Hdf5Group;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIf;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

/**
 * M97 long-read profile: the {@code @read_role} attribute, the
 * QUALITY_BINNED platform guard, and the REF_DIFF_V2
 * {@code slice_bytes} byte budget.
 *
 * <p>Mirrors Python {@code test_m97_long_read_profile.py} and ObjC
 * {@code TestM97LongReadProfile.m}.
 */
final class M97LongReadProfileTest {

    private static final int N = 40;
    private static final int READ_LEN = 10;

    static boolean isNativeAvailable() {
        return RefDiffV2.isAvailable();
    }

    private static byte[] buildReference(int len) {
        byte[] ref = new byte[len];
        byte[] bases = {'A', 'C', 'G', 'T'};
        for (int i = 0; i < len; i++) ref[i] = bases[i % 4];
        return ref;
    }

    /** An aligned 40-read single-chromosome run, 10 bp per read,
     *  positions i*20 + 1, legacy whole-channel layout. */
    private static WrittenGenomicRun buildAlignedRun(String platform) {
        byte[] refSeq = buildReference(10_000);
        long[] positions = new long[N];
        byte[] seq = new byte[N * READ_LEN];
        long[] offsets = new long[N];
        int[] lengths = new int[N];
        byte[] mapqs = new byte[N];
        java.util.Arrays.fill(mapqs, (byte) 60);
        byte[] qual = new byte[N * READ_LEN];
        java.util.Arrays.fill(qual, (byte) 30);
        List<String> cigars = new ArrayList<>(N);
        List<String> readNames = new ArrayList<>(N);
        List<String> chromosomes = new ArrayList<>(N);
        List<String> mateChromosomes = new ArrayList<>(N);
        for (int i = 0; i < N; i++) {
            positions[i] = (long) i * 20 + 1L;
            System.arraycopy(refSeq, i * 20, seq, i * READ_LEN, READ_LEN);
            offsets[i] = (long) i * READ_LEN;
            lengths[i] = READ_LEN;
            cigars.add(READ_LEN + "M");
            readNames.add("r" + i);
            chromosomes.add("22");
            mateChromosomes.add("*");
        }
        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS, "GRCh38.m97_test", platform,
            "HG002",
            positions, mapqs, new int[N], seq, qual, offsets, lengths,
            cigars, readNames, mateChromosomes, new long[N], new int[N],
            chromosomes,
            Compression.ZLIB, Map.of(), List.of(),
            true, Map.of("22", refSeq), null).withOptLegacyWholeChannel(true);
    }

    private static Path writeRun(Path tmp, WrittenGenomicRun run,
                                  String fname) {
        Path file = tmp.resolve(fname);
        SpectralDataset.create(file.toString(), "m97_test", "M97",
            List.of(), List.of(run), List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        return file;
    }

    /** The outer header's n_slices (u32 LE at offset 8). */
    private static int nSlices(byte[] blob) {
        return (blob[8] & 0xFF) | ((blob[9] & 0xFF) << 8)
             | ((blob[10] & 0xFF) << 16) | ((blob[11] & 0xFF) << 24);
    }

    // ── QUALITY_BINNED platform guard ─────────────────────────────

    @Test
    void testBinnedAllowedForPlatform() {
        assertTrue(Quality.binnedAllowedForPlatform(null));
        assertTrue(Quality.binnedAllowedForPlatform(""));
        assertTrue(Quality.binnedAllowedForPlatform("ILLUMINA"));
        // ont only counts as a whole token — IONTORRENT contains it.
        assertTrue(Quality.binnedAllowedForPlatform("IONTORRENT"));
        assertFalse(Quality.binnedAllowedForPlatform("ONT"));
        assertFalse(Quality.binnedAllowedForPlatform("PacBio HiFi"));
        assertFalse(Quality.binnedAllowedForPlatform("HIFI"));
        assertFalse(Quality.binnedAllowedForPlatform("Oxford Nanopore"));
    }

    @Test
    @EnabledIf("isNativeAvailable")
    void testQualityBinnedGuardWriter(@TempDir Path tmp) {
        WrittenGenomicRun ont = buildAlignedRun("ONT")
            .withSignalCodecOverrides(
                Map.of("qualities", Compression.QUALITY_BINNED));
        IllegalArgumentException ex = assertThrows(
            IllegalArgumentException.class,
            () -> writeRun(tmp, ont, "guard.tio"));
        assertTrue(ex.getMessage().contains("QUALITY_BINNED"));

        // Rejected at stream-writer construction, before any write.
        GenomicStreamWriter.Options opts = GenomicStreamWriter.Options
            .fromRun(buildAlignedRun("PacBio HiFi")
                .withSignalCodecOverrides(
                    Map.of("qualities", Compression.QUALITY_BINNED)));
        assertThrows(IllegalArgumentException.class,
            () -> new GenomicStreamWriter(null, "g", opts));

        // The same override on a short-read platform writes fine.
        WrittenGenomicRun ok = buildAlignedRun("ILLUMINA")
            .withSignalCodecOverrides(
                Map.of("qualities", Compression.QUALITY_BINNED));
        assertTrue(writeRun(tmp, ok, "ok.tio").toFile().exists());
    }

    // ── @read_role round-trip ─────────────────────────────────────

    @Test
    @EnabledIf("isNativeAvailable")
    void testReadRoleRoundTrip(@TempDir Path tmp) {
        WrittenGenomicRun run = buildAlignedRun("PacBio HiFi")
            .withReadRole("hifi");
        Path file = writeRun(tmp, run, "role.tio");
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            assertEquals("hifi",
                ds.genomicRuns().get("genomic_0001").getReadRole());
        }

        // Absent attribute (pre-M97 file shape) reads back as null.
        Path plain = writeRun(tmp, buildAlignedRun("ILLUMINA"), "plain.tio");
        try (SpectralDataset ds = SpectralDataset.open(plain.toString())) {
            assertNull(ds.genomicRuns().get("genomic_0001").getReadRole());
        }

        // blocks_v1 path (the default layout) stamps it too.
        WrittenGenomicRun blocksRun = buildAlignedRun("ONT")
            .withOptLegacyWholeChannel(false).withReadRole("ont_ul");
        Path blocks = writeRun(tmp, blocksRun, "blocks.tio");
        try (SpectralDataset ds = SpectralDataset.open(blocks.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertEquals("blocks_v1", gr.layout());
            assertEquals("ont_ul", gr.getReadRole());
        }
    }

    // ── REF_DIFF_V2 slice_bytes — codec level ─────────────────────

    @Test
    @EnabledIf("isNativeAvailable")
    void testSliceBytesCodecByteBudget() {
        // Alternating 20- and 100-base reads so a 200-base budget cuts
        // mid-pattern; mirrors the C invariant test.
        int n = 40;
        byte[] ref = buildReference(4096);
        long[] positions = new long[n];
        long[] offsets = new long[n + 1];
        String[] cigars = new String[n];
        java.io.ByteArrayOutputStream seqs = new java.io.ByteArrayOutputStream();
        for (int r = 0; r < n; r++) {
            int len = (r % 2 == 0) ? 20 : 100;
            positions[r] = (long) r * 60 + 1L;
            byte[] read = java.util.Arrays.copyOfRange(
                ref, r * 60, r * 60 + len);
            read[3] = read[3] == 'A' ? (byte) 'C' : (byte) 'A';
            seqs.writeBytes(read);
            cigars[r] = len + "M";
            offsets[r + 1] = offsets[r] + len;
        }
        byte[] seqArr = seqs.toByteArray();
        long total = offsets[n];
        byte[] md5 = new byte[16];

        byte[] base = RefDiffV2.encode(seqArr, offsets, positions, cigars,
            ref, md5, "m97", 10_000);
        byte[] full = RefDiffV2.encode(seqArr, offsets, positions, cigars,
            ref, md5, "m97", 10_000, total);
        assertArrayEquals(base, full,
            "full budget must be byte-identical to default");

        byte[] budgeted = RefDiffV2.encode(seqArr, offsets, positions,
            cigars, ref, md5, "m97", 10_000, 200L);
        assertTrue(nSlices(budgeted) > 1,
            "byte budget must produce multiple slices");
        assertFalse(java.util.Arrays.equals(base, budgeted));

        // Non-uniform read counts: num_reads is the u32 at index-entry
        // offset 28; the index starts after the 38 + uri-length header.
        int hdr = 38 + "m97".length();
        HashSet<Integer> counts = new HashSet<>();
        int sum = 0;
        for (int s = 0; s < nSlices(budgeted); s++) {
            int off = hdr + 32 * s + 28;
            int c = (budgeted[off] & 0xFF) | ((budgeted[off + 1] & 0xFF) << 8)
                  | ((budgeted[off + 2] & 0xFF) << 16)
                  | ((budgeted[off + 3] & 0xFF) << 24);
            counts.add(c);
            sum += c;
        }
        assertEquals(n, sum);
        assertTrue(counts.size() >= 2, "slice read counts must differ");

        // The unmodified decoder round-trips the non-uniform blob.
        RefDiffV2.Pair out = RefDiffV2.decode(budgeted, positions, cigars,
            ref, n, total);
        assertArrayEquals(seqArr, out.sequences);
        assertArrayEquals(offsets, out.offsets);
    }

    // ── REF_DIFF_V2 slice_bytes — through the writers ─────────────

    @Test
    @EnabledIf("isNativeAvailable")
    void testSliceBytesThroughWriters(@TempDir Path tmp) {
        // Blocks encoder: a 100-base budget over 40 x 10 bp reads makes
        // 4 slices where the default makes 1.
        WrittenGenomicRun plain = buildAlignedRun("PacBio HiFi")
            .withOptLegacyWholeChannel(false);
        GenomicBlocks.BlockBlobs def = GenomicBlocks.encodeBlock(
            plain, GenomicWriteContext.none());
        assertEquals(Compression.REF_DIFF_V2.ordinal(),
            (int) def.codecs().get("sequences"));
        assertEquals(1, nSlices(def.blobs().get("sequences")));

        WrittenGenomicRun budgeted = buildAlignedRun("PacBio HiFi")
            .withOptLegacyWholeChannel(false).withRefDiffSliceBytes(100L);
        GenomicBlocks.BlockBlobs bb = GenomicBlocks.encodeBlock(
            budgeted, GenomicWriteContext.none());
        assertEquals(4, nSlices(bb.blobs().get("sequences")));

        // Legacy whole-channel writeMinimal path: same knob in the
        // emitted HDF5 blob, and the file round-trips.
        WrittenGenomicRun legacy = buildAlignedRun("PacBio HiFi")
            .withRefDiffSliceBytes(100L);
        Path file = writeRun(tmp, legacy, "slice.tio");
        try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group gRuns = study.openGroup("genomic_runs");
             Hdf5Group rg   = gRuns.openGroup("genomic_0001");
             Hdf5Group sc   = rg.openGroup("signal_channels");
             Hdf5Group seqG = sc.openGroup("sequences");
             Hdf5Dataset blobDs = seqG.openDataset("refdiff_v2")) {
            byte[] blob = (byte[]) blobDs.readData();
            assertEquals(4, nSlices(blob),
                "legacy HDF5 blob must carry 4 slices");
        }
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertEquals(N, gr.readCount());
            byte[] refSeq = buildReference(10_000);
            for (int i = 0; i < N; i++) {
                String expect = new String(refSeq, i * 20, READ_LEN,
                    java.nio.charset.StandardCharsets.US_ASCII);
                assertEquals(expect, gr.readAt(i).sequence());
            }
        }
    }
}
