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
     *  {@code parent.createGroup("genomic_index")}). The mathematically
     *  redundant {@code offsets} column is omitted; readers synthesize
     *  it from {@code cumsum(lengths)}.
     */
    public void writeTo(StorageGroup idxGroup) {
        writeInts (idxGroup, "lengths",          Precision.UINT32, lengths);
        writeLongs(idxGroup, "positions",        Precision.INT64,  positions);
        writeBytes(idxGroup, "mapping_qualities", Precision.UINT8, mappingQualities);
        writeInts (idxGroup, "flags",            Precision.UINT32, flags);

        // L1 (Task #82 Phase B.1, 2026-05-01): chromosomes are stored
        // as `chromosome_ids` (uint16) + `chromosome_names` (compound)
        // instead of a single VL-string compound. The old layout cost
        // 42 MB of HDF5 fractal-heap overhead per chr22 .tio file
        // (one heap block per chunk × 432 chunks) just to repeat one
        // byte-string 1.77M times. Encounter-order id assignment —
        // first occurrence gets the next unused id; cross-language
        // byte-exact contract.
        java.util.LinkedHashMap<String, Integer> nameToId = new java.util.LinkedHashMap<>();
        short[] ids = new short[chromosomes.size()];
        for (int i = 0; i < chromosomes.size(); i++) {
            String name = chromosomes.get(i);
            Integer slot = nameToId.get(name);
            if (slot == null) {
                if (nameToId.size() > 65535) {
                    throw new IllegalStateException(
                        "genomic_index: > 65,535 unique chromosome names; "
                        + "uint16 chromosome_ids would overflow.");
                }
                slot = nameToId.size();
                nameToId.put(name, slot);
            }
            ids[i] = slot.shortValue();
        }
        // Write chromosome_ids as uint16 (Java has no unsigned short,
        // so we pass the ids array via the StorageDataset writeAll
        // path which interprets the raw 16-bit pattern).
        StorageDataset cids;
        try {
            cids = idxGroup.createDataset(
                "chromosome_ids", Precision.UINT16, ids.length,
                CHUNK_SIZE, Compression.ZLIB, COMPRESSION_LEVEL);
        } catch (UnsupportedOperationException e) {
            cids = idxGroup.createDataset(
                "chromosome_ids", Precision.UINT16, ids.length,
                0, Compression.NONE, 0);
        }
        try (StorageDataset closeMe = cids) {
            closeMe.writeAll(ids);
        }
        // Write chromosome_names as compound[(name, VL_str)].
        List<CompoundField> nameFields = List.of(
            new CompoundField("name", CompoundField.Kind.VL_STRING));
        List<Object[]> nameRows = new ArrayList<>(nameToId.size());
        for (String n : nameToId.keySet()) nameRows.add(new Object[]{ n });
        try (StorageDataset ds = idxGroup.createCompoundDataset(
                "chromosome_names", nameFields, nameRows.size())) {
            ds.writeAll(nameRows);
        }
    }

    /** Read a {@link GenomicIndex} from an existing {@code genomic_index/}
     *  group (typically opened via {@code parent.openGroup("genomic_index")}).
     *
     *  <p>v1.10 #10 (2026-05-04): {@code offsets} is no longer stored
     *  on disk by default — it's mathematically derivable from
     *  {@code cumsum(lengths)}. Reader handles both layouts: pre-v1.10
     *  files have the column on disk (read directly); v1.10+ files
     *  synthesize it from lengths. Always uint64.</p>
     */
    @SuppressWarnings("unchecked")
    public static GenomicIndex readFrom(StorageGroup idxGroup) {
        int[]   lengths   = readInts (idxGroup, "lengths");
        long[]  offsets   = idxGroup.hasChild("offsets")
            ? readLongs(idxGroup, "offsets")
            : offsetsFromLengths(lengths);
        long[]  positions = readLongs(idxGroup, "positions");
        byte[]  mapqs     = readBytes(idxGroup, "mapping_qualities");
        int[]   flags     = readInts (idxGroup, "flags");

        // L1: read chromosome_ids (uint16) + chromosome_names
        // (compound) and materialise back to a List<String> so the
        // GenomicIndex API surface stays unchanged for callers.
        short[] ids;
        try (StorageDataset ds = idxGroup.openDataset("chromosome_ids")) {
            ids = (short[]) ds.readAll();
        }
        List<Object[]> nameRows;
        try (StorageDataset ds = idxGroup.openDataset("chromosome_names")) {
            nameRows = (List<Object[]>) ds.readAll();
        }
        List<String> nameTable = new ArrayList<>(nameRows.size());
        for (Object[] row : nameRows) {
            Object v = row[0];
            if (v instanceof byte[] b) {
                nameTable.add(new String(b, java.nio.charset.StandardCharsets.UTF_8));
            } else {
                nameTable.add(v == null ? "" : v.toString());
            }
        }
        List<String> chroms = new ArrayList<>(ids.length);
        for (short id : ids) {
            int idx = Short.toUnsignedInt(id);
            chroms.add(idx < nameTable.size() ? nameTable.get(idx) : "");
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

    /**
     * v1.10 #10 helper: synthesize per-record byte offsets from a
     * lengths array. {@code offsets[i] = sum(lengths[0..i])}, returned
     * as a {@code long[]} (i.e. uint64) to avoid the >4 GB overflow
     * cliff on deep WGS even though the input lengths are uint32.
     *
     * <p>Empty input returns {@code new long[0]}.</p>
     */
    public static long[] offsetsFromLengths(int[] lengths) {
        long[] out = new long[lengths.length];
        if (lengths.length == 0) return out;
        out[0] = 0L;
        long acc = 0L;
        for (int i = 1; i < lengths.length; i++) {
            // Mask up the int to its uint32 value before adding to long.
            acc += ((long) lengths[i - 1]) & 0xFFFFFFFFL;
            out[i] = acc;
        }
        return out;
    }
}
