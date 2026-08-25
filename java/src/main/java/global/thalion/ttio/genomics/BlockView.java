/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.genomics;

import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.Enums.Precision;
import global.thalion.ttio.providers.CompoundField;
import global.thalion.ttio.providers.MemoryProvider;
import global.thalion.ttio.providers.StorageDataset;
import global.thalion.ttio.providers.StorageGroup;
import global.thalion.ttio.providers.StorageProvider;

import java.util.ArrayList;
import java.util.List;
import java.util.Set;

/**
 * Read-side support for {@code blocks_v1}: one block materialised as a
 * v1.8-shaped run group in a memory provider (the block's blobs with
 * their attributes, the matching slice of the index arrays and the
 * run-level name tables) so the whole-channel {@link GenomicRun} decode
 * runs over it unchanged. Python: {@code ttio.genomic._block_view}.
 */
public final class BlockView {

    /** The materialised group and the memory store it lives in. */
    public record Handle(StorageGroup group, String storeUrl) {
        public void discard() { MemoryProvider.discardStore(storeUrl); }
    }

    private static final String[][] INDEX_ARRAYS = {
        {"lengths", "UINT32"}, {"positions", "INT64"}, {"mapping_qualities", "UINT8"},
        {"flags", "UINT32"}, {"chromosome_ids", "UINT16"},
    };
    private static final Set<String> RUN_ATTRS_SKIPPED = Set.of("layout", "block_policy", "base_count");

    private BlockView() {}

    /** Materialise block {@code b} of {@code runGroup}. */
    public static Handle materialise(StorageGroup runGroup, BlockTable t, int b,
                              List<String> chromNames, List<String> mateChromNames) {
        return materialise(runGroup, t, b, chromNames, mateChromNames, Set.of());
    }

    /** As above, leaving out the blob channels named in
     *  {@code skipChannels} — the per-AU decrypt walker (M99) skips
     *  the encrypted (deleted) channels and injects their decrypted
     *  raw bytes itself. */
    public static Handle materialise(StorageGroup runGroup, BlockTable t, int b,
                              List<String> chromNames, List<String> mateChromNames,
                              Set<String> skipChannels) {
        String url = "memory://ttio-block-view-" + System.identityHashCode(runGroup)
                   + "-" + b + "-" + System.nanoTime();
        StorageProvider mem = new MemoryProvider().open(url, StorageProvider.Mode.CREATE);
        StorageGroup view = mem.rootGroup().createGroup("run");
        for (String k : runGroup.attributeNames()) {
            if (RUN_ATTRS_SKIPPED.contains(k)) continue;
            view.setAttribute(k, runGroup.getAttribute(k));
        }
        long r0 = t.readStart[b];
        int n = t.nReads[b];
        view.setAttribute("read_count", (long) n);

        StorageGroup srcIdx = runGroup.openGroup("genomic_index");
        StorageGroup dstIdx = view.createGroup("genomic_index");
        for (String[] a : INDEX_ARRAYS) {
            try (StorageDataset src = srcIdx.openDataset(a[0])) {
                Object arr = src.readSlice(r0, n);
                StorageDataset dst = dstIdx.createDataset(a[0], Precision.valueOf(a[1]), n, 0,
                        Compression.NONE, 0);
                dst.writeAll(arr);
                copyAttrs(src, dst);
            }
        }
        writeNames(dstIdx, "chromosome_names", chromNames);

        StorageGroup srcSc = runGroup.openGroup("signal_channels");
        StorageGroup dstSc = view.createGroup("signal_channels");
        for (String ch : GenomicBlocks.BLOCK_CHANNELS) {
            if (skipChannels.contains(ch)) continue;
            long off = t.off.get(ch)[b], ln = t.len.get(ch)[b];
            if (ln == 0) continue;
            Integer codec = t.codec != null ? t.codec.get(ch)[b] : null;
            StorageDataset src;
            StorageGroup dstParent;
            String dstName;
            if (ch.equals("sequences")) {
                src = srcSc.openGroup("sequences").openDataset("data");
                if (codec == null) codec = ((Number) src.getAttribute("compression")).intValue();
                if (codec == Compression.REF_DIFF_V2.ordinal()) {
                    dstParent = dstSc.createGroup("sequences");
                    dstName = "refdiff_v2";
                } else {
                    dstParent = dstSc;
                    dstName = "sequences";
                }
            } else if (ch.equals("mate_info")) {
                src = srcSc.openGroup("mate_info").openDataset("inline_v2");
                dstParent = dstSc.createGroup("mate_info");
                dstName = "inline_v2";
            } else {
                src = srcSc.openDataset(ch);
                dstParent = dstSc;
                dstName = ch;
            }
            StorageDataset dst = dstParent.createDataset(dstName, Precision.UINT8, ln, 0,
                    Compression.NONE, 0);
            dst.writeAll(src.readSlice(off, ln));
            copyAttrs(src, dst);
            if (codec != null) dst.setAttribute("compression", codec);
            src.close();
        }
        if (srcSc.hasChild("mate_info")) {
            StorageGroup mate = dstSc.hasChild("mate_info")
                ? dstSc.openGroup("mate_info") : dstSc.createGroup("mate_info");
            writeNames(mate, "chrom_names", mateChromNames);
        }
        return new Handle(view, url);
    }

    private static void copyAttrs(StorageDataset src, StorageDataset dst) {
        for (String k : src.attributeNames()) dst.setAttribute(k, src.getAttribute(k));
    }

    private static void writeNames(StorageGroup g, String name, List<String> names) {
        List<CompoundField> fields = List.of(new CompoundField("name", CompoundField.Kind.VL_STRING));
        List<Object[]> rows = new ArrayList<>(names.size());
        for (String n : names) rows.add(new Object[]{ n });
        try (StorageDataset ds = g.createCompoundDataset(name, fields, rows.size())) {
            ds.writeAll(rows);
        }
    }

    /** The {@code name} column of a one-column name table. */
    public static List<String> readNames(StorageGroup g, String name) {
        List<String> out = new ArrayList<>();
        if (!g.hasChild(name)) return out;
        try (StorageDataset ds = g.openDataset(name)) {
            for (var row : ds.readRows()) {
                Object v = row.get("name");
                if (v instanceof byte[] bytes) {
                    out.add(new String(bytes, java.nio.charset.StandardCharsets.UTF_8));
                } else {
                    out.add(v == null ? "" : v.toString());
                }
            }
        }
        return out;
    }
}
