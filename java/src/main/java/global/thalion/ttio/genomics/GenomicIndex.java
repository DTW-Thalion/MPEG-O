/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.genomics;

import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.Enums.Precision;
import global.thalion.ttio.providers.CompoundField;
import global.thalion.ttio.providers.StorageDataset;
import global.thalion.ttio.providers.StorageGroup;

import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

/**
 * Per-read offsets, lengths, positions, mapping qualities, flags, and
 * chromosome strings for one {@link GenomicRun}. Held in memory as
 * parallel arrays; loaded eagerly when the run is opened.
 *
 * <p>Genomic analogue of {@link global.thalion.ttio.SpectrumIndex}.</p>
 *
 * <p><b>API status:</b> Stable (v0.11 M82.3).</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOGenomicIndex}, Python {@code ttio.genomic_index.GenomicIndex}.</p>
 */
public final class GenomicIndex {

    private static final int CHUNK_SIZE = 65536;
    private static final int COMPRESSION_LEVEL = 6;

    private final long[]   offsets;          // uint64 — byte offset into sequence channel
    private final int[]    lengths;          // uint32 — read length in bases
    private final List<String> chromosomes;  // one per read
    private final long[]   positions;        // int64 — 0-based mapping position
    private final byte[]   mappingQualities; // uint8
    private final int[]    flags;            // uint32

    public GenomicIndex(long[] offsets, int[] lengths,
                         List<String> chromosomes, long[] positions,
                         byte[] mappingQualities, int[] flags) {
        Objects.requireNonNull(offsets);
        Objects.requireNonNull(lengths);
        Objects.requireNonNull(chromosomes);
        Objects.requireNonNull(positions);
        Objects.requireNonNull(mappingQualities);
        Objects.requireNonNull(flags);
        if (lengths.length != offsets.length
                || chromosomes.size() != offsets.length
                || positions.length != offsets.length
                || mappingQualities.length != offsets.length
                || flags.length != offsets.length) {
            throw new IllegalArgumentException(
                "GenomicIndex column lengths must match");
        }
        this.offsets = offsets;
        this.lengths = lengths;
        this.chromosomes = List.copyOf(chromosomes);
        this.positions = positions;
        this.mappingQualities = mappingQualities;
        this.flags = flags;
    }

    /** Number of reads. */
    public int count() { return offsets.length; }

    /** Byte offset of read {@code i} in the sequences/qualities channels. */
    public long offsetAt(int i) { return offsets[i]; }
    /** Length of read {@code i} in bases. */
    public int lengthAt(int i) { return lengths[i]; }
    /** 0-based mapping position of read {@code i}. */
    public long positionAt(int i) { return positions[i]; }
    /** Phred-scaled mapping quality of read {@code i}, unsigned (0–255). */
    public int mappingQualityAt(int i) { return mappingQualities[i] & 0xFF; }
    /** SAM flags of read {@code i}. */
    public int flagsAt(int i) { return flags[i]; }
    /** Reference sequence name of read {@code i}. */
    public String chromosomeAt(int i) { return chromosomes.get(i); }

    /** Read indices on {@code chromosome} with {@code start <= position < end}. */
    public List<Integer> indicesForRegion(String chromosome, long start, long end) {
        List<Integer> out = new ArrayList<>();
        for (int i = 0; i < count(); i++) {
            if (chromosomes.get(i).equals(chromosome)
                    && positions[i] >= start && positions[i] < end) {
                out.add(i);
            }
        }
        return out;
    }

    /** Read indices where {@code (flags & 0x4) != 0}. */
    public List<Integer> indicesForUnmapped() { return indicesForFlag(0x4); }

    /** Read indices where {@code (flags & flagMask) != 0}. */
    public List<Integer> indicesForFlag(int flagMask) {
        List<Integer> out = new ArrayList<>();
        for (int i = 0; i < count(); i++) {
            if ((flags[i] & flagMask) != 0) out.add(i);
        }
        return out;
    }

    // ── Disk I/O via the StorageGroup protocol ─────────────────────

    /** Write this index into {@code idxGroup} (typically created via
     *  {@code parent.createGroup("genomic_index")}). */
    public void writeTo(StorageGroup idxGroup) {
        writeLongs(idxGroup, "offsets",          Precision.UINT64, offsets);
        writeInts (idxGroup, "lengths",          Precision.UINT32, lengths);
        writeLongs(idxGroup, "positions",        Precision.INT64,  positions);
        writeBytes(idxGroup, "mapping_qualities", Precision.UINT8, mappingQualities);
        writeInts (idxGroup, "flags",            Precision.UINT32, flags);

        // chromosomes: compound with single VL_BYTES field (Java JHI5
        // can't round-trip VL_STRING compounds; VL_BYTES works). Bytes
        // are UTF-8 encoded; readers decode back to String.
        // CROSS-LANGUAGE NOTE: Python and ObjC write VL_STRING here.
        // Java↔others compound interop for genomic VL strings is the
        // M82.4 cross-language matrix concern; M82.3 ships with Java
        // round-trip working via VL_BYTES.
        List<CompoundField> fields = List.of(
            new CompoundField("value", CompoundField.Kind.VL_BYTES));
        List<Object[]> rows = new ArrayList<>(chromosomes.size());
        for (String c : chromosomes) {
            rows.add(new Object[]{ c.getBytes(java.nio.charset.StandardCharsets.UTF_8) });
        }
        try (StorageDataset ds = idxGroup.createCompoundDataset(
                "chromosomes", fields, rows.size())) {
            ds.writeAll(rows);
        }
    }

    /** Read a {@link GenomicIndex} from an existing {@code genomic_index/}
     *  group (typically opened via {@code parent.openGroup("genomic_index")}). */
    @SuppressWarnings("unchecked")
    public static GenomicIndex readFrom(StorageGroup idxGroup) {
        long[]  offsets   = readLongs(idxGroup, "offsets");
        int[]   lengths   = readInts (idxGroup, "lengths");
        long[]  positions = readLongs(idxGroup, "positions");
        byte[]  mapqs     = readBytes(idxGroup, "mapping_qualities");
        int[]   flags     = readInts (idxGroup, "flags");

        List<Object[]> chromRows;
        try (StorageDataset ds = idxGroup.openDataset("chromosomes")) {
            chromRows = (List<Object[]>) ds.readAll();
        }
        List<String> chroms = new ArrayList<>(chromRows.size());
        for (Object[] row : chromRows) {
            Object v = row[0];
            // VL_BYTES (Java write path) → byte[]; VL_STRING (Python/ObjC
            // write path) → String, but readback returns "" due to the
            // JHI5 limitation. Falling back to "" preserves the contract;
            // cross-language fix is M82.4 territory.
            if (v instanceof byte[] b) {
                chroms.add(new String(b, java.nio.charset.StandardCharsets.UTF_8));
            } else {
                chroms.add(v == null ? "" : v.toString());
            }
        }

        return new GenomicIndex(offsets, lengths, chroms, positions, mapqs, flags);
    }

    // ── Typed-channel helpers (chunked + zlib, falling back to raw) ─

    private static void writeLongs(StorageGroup g, String name, Precision p, long[] data) {
        StorageDataset ds;
        try {
            ds = g.createDataset(name, p, data.length, CHUNK_SIZE,
                    Compression.ZLIB, COMPRESSION_LEVEL);
        } catch (UnsupportedOperationException e) {
            ds = g.createDataset(name, p, data.length, 0, Compression.NONE, 0);
        }
        try (StorageDataset closeMe = ds) { closeMe.writeAll(data); }
    }

    private static void writeInts(StorageGroup g, String name, Precision p, int[] data) {
        StorageDataset ds;
        try {
            ds = g.createDataset(name, p, data.length, CHUNK_SIZE,
                    Compression.ZLIB, COMPRESSION_LEVEL);
        } catch (UnsupportedOperationException e) {
            ds = g.createDataset(name, p, data.length, 0, Compression.NONE, 0);
        }
        try (StorageDataset closeMe = ds) { closeMe.writeAll(data); }
    }

    private static void writeBytes(StorageGroup g, String name, Precision p, byte[] data) {
        StorageDataset ds;
        try {
            ds = g.createDataset(name, p, data.length, CHUNK_SIZE,
                    Compression.ZLIB, COMPRESSION_LEVEL);
        } catch (UnsupportedOperationException e) {
            ds = g.createDataset(name, p, data.length, 0, Compression.NONE, 0);
        }
        try (StorageDataset closeMe = ds) { closeMe.writeAll(data); }
    }

    private static long[] readLongs(StorageGroup g, String name) {
        try (StorageDataset ds = g.openDataset(name)) {
            return (long[]) ds.readAll();
        }
    }

    private static int[] readInts(StorageGroup g, String name) {
        try (StorageDataset ds = g.openDataset(name)) {
            return (int[]) ds.readAll();
        }
    }

    private static byte[] readBytes(StorageGroup g, String name) {
        try (StorageDataset ds = g.openDataset(name)) {
            return (byte[]) ds.readAll();
        }
    }
}
