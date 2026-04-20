/* MPEG-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: LGPL-3.0-or-later */
package com.dtwthalion.mpgo.protection;

import com.dtwthalion.mpgo.FeatureFlags;
import com.dtwthalion.mpgo.protection.PerAUEncryption.AUHeaderPlaintext;
import com.dtwthalion.mpgo.protection.PerAUEncryption.ChannelSegment;
import com.dtwthalion.mpgo.protection.PerAUEncryption.HeaderSegment;
import com.dtwthalion.mpgo.providers.CompoundField;
import com.dtwthalion.mpgo.providers.ProviderRegistry;
import com.dtwthalion.mpgo.providers.StorageDataset;
import com.dtwthalion.mpgo.providers.StorageGroup;
import com.dtwthalion.mpgo.providers.StorageProvider;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * v1.0 file-level per-Access-Unit encryption orchestrator.
 *
 * <p>Reads plaintext {@code <channel>_values} datasets from an
 * MPEG-O file, encrypts each spectrum independently with
 * {@link PerAUEncryption}, and rewrites the file's
 * {@code signal_channels} groups with the
 * {@code <channel>_segments} compound layout from
 * {@code docs/format-spec.md} §9.1. Routes through the
 * {@link StorageProvider} abstraction so any backend supporting
 * VL_BYTES compound fields (HDF5 + Memory today) works.
 *
 * <p>When {@code encryptHeaders} is true, also encrypts the six
 * semantic index arrays into {@code spectrum_index/au_header_segments}
 * and deletes the plaintext children. Offsets + lengths stay
 * plaintext (structural framing, not semantic PHI).
 *
 * <p>Sets {@code opt_per_au_encryption} (and
 * {@code opt_encrypted_au_headers} when applicable) on the root
 * group.
 *
 * <p><b>Cross-language equivalents:</b> Python
 * {@code mpeg_o.encryption_per_au.encrypt_per_au / decrypt_per_au},
 * Objective-C {@code MPGOPerAUFile}.
 *
 * @since 1.0
 */
public final class PerAUFile {

    private PerAUFile() {}

    /** Result of {@link #decryptFile}: per-run, per-channel plaintext
     *  float64 LE bytes; optional {@code auHeaders} list when
     *  {@code opt_encrypted_au_headers} is set. */
    public record DecryptedRun(Map<String, byte[]> channels,
                                 List<AUHeaderPlaintext> auHeaders) {}

    /** Encrypt {@code path} in place. */
    public static void encryptFile(String path, byte[] key,
                                     boolean encryptHeaders,
                                     String providerName) {
        if (key.length != 32) {
            throw new IllegalArgumentException(
                "AES-256-GCM key must be 32 bytes, got " + key.length);
        }
        StorageProvider sp = ProviderRegistry.open(path,
            StorageProvider.Mode.READ_WRITE, providerName);
        try {
            StorageGroup root = sp.rootGroup();
            FeatureFlags flags = FeatureFlags.readFrom(root);

            try (StorageGroup study = root.openGroup("study");
                 StorageGroup msRuns = study.openGroup("ms_runs")) {
                int datasetId = 1;
                for (String runName : runNames(msRuns)) {
                    encryptOneRun(msRuns, runName, datasetId, key, encryptHeaders);
                    datasetId++;
                }
            }

            List<String> updatedFeatures = new ArrayList<>(flags.features());
            if (!updatedFeatures.contains(FeatureFlags.OPT_PER_AU_ENCRYPTION)) {
                updatedFeatures.add(FeatureFlags.OPT_PER_AU_ENCRYPTION);
            }
            if (encryptHeaders
                    && !updatedFeatures.contains(FeatureFlags.OPT_ENCRYPTED_AU_HEADERS)) {
                updatedFeatures.add(FeatureFlags.OPT_ENCRYPTED_AU_HEADERS);
            }
            java.util.Collections.sort(updatedFeatures);
            new FeatureFlags(flags.formatVersion(), updatedFeatures).writeTo(root);
        } finally {
            sp.close();
        }
    }

    /** Read-only decrypt. Returns a map keyed by run name. */
    public static Map<String, DecryptedRun> decryptFile(String path, byte[] key,
                                                          String providerName) {
        if (key.length != 32) {
            throw new IllegalArgumentException(
                "AES-256-GCM key must be 32 bytes, got " + key.length);
        }
        Map<String, DecryptedRun> out = new LinkedHashMap<>();
        StorageProvider sp = ProviderRegistry.open(path,
            StorageProvider.Mode.READ, providerName);
        try {
            StorageGroup root = sp.rootGroup();
            FeatureFlags flags = FeatureFlags.readFrom(root);
            if (!flags.has(FeatureFlags.OPT_PER_AU_ENCRYPTION)) {
                throw new IllegalStateException(
                    "file at " + path + " does not carry opt_per_au_encryption");
            }
            boolean headersEncrypted = flags.has(FeatureFlags.OPT_ENCRYPTED_AU_HEADERS);

            try (StorageGroup study = root.openGroup("study");
                 StorageGroup msRuns = study.openGroup("ms_runs")) {
                int datasetId = 1;
                for (String runName : runNames(msRuns)) {
                    out.put(runName, decryptOneRun(msRuns, runName, datasetId, key,
                                                     headersEncrypted));
                    datasetId++;
                }
            }
            return out;
        } finally {
            sp.close();
        }
    }

    // ────────────────────────────────────────────────── encrypt helpers

    private static void encryptOneRun(StorageGroup msRuns, String runName,
                                        int datasetId, byte[] key,
                                        boolean encryptHeaders) {
        try (StorageGroup run = msRuns.openGroup(runName);
             StorageGroup sig = run.openGroup("signal_channels");
             StorageGroup idx = run.openGroup("spectrum_index")) {

            long[] offsets = readLongs(idx, "offsets");
            int[] lengths = readInts(idx, "lengths");

            String rawNames = (String) sig.getAttribute("channel_names");
            List<String> channelNames = splitNames(rawNames);

            for (String cname : channelNames) {
                String valuesName = cname + "_values";
                if (!sig.hasChild(valuesName)) continue;
                double[] values;
                try (StorageDataset ds = sig.openDataset(valuesName)) {
                    values = (double[]) ds.readAll();
                }
                byte[] bytes = doublesToLeBytes(values);
                List<ChannelSegment> segs = PerAUEncryption.encryptChannelToSegments(
                    bytes, offsets, lengths, datasetId, cname, key);
                writeChannelSegments(sig, cname + "_segments", segs);
                sig.deleteChild(valuesName);
                sig.setAttribute(cname + "_algorithm", "aes-256-gcm");
            }

            if (encryptHeaders) {
                int acqMode = ((Number) getAttrOr(run, "acquisition_mode", 0L)).intValue();
                double[] rts = readDoubles(idx, "retention_times");
                int[] msLevels = readInts(idx, "ms_levels");
                int[] pols = readInts(idx, "polarities");
                double[] pmzs = readDoubles(idx, "precursor_mzs");
                int[] pcs = readInts(idx, "precursor_charges");
                double[] bpis = readDoubles(idx, "base_peak_intensities");

                List<AUHeaderPlaintext> rows = new ArrayList<>(rts.length);
                for (int i = 0; i < rts.length; i++) {
                    rows.add(new AUHeaderPlaintext(acqMode, msLevels[i], pols[i],
                                                     rts[i], pmzs[i], pcs[i], 0.0,
                                                     bpis[i]));
                }
                List<HeaderSegment> segs =
                    PerAUEncryption.encryptHeaderSegments(rows, datasetId, key);
                writeHeaderSegments(idx, "au_header_segments", segs);

                for (String name : new String[]{"retention_times", "ms_levels",
                                                  "polarities", "precursor_mzs",
                                                  "precursor_charges",
                                                  "base_peak_intensities"}) {
                    if (idx.hasChild(name)) idx.deleteChild(name);
                }
            }
        }
    }

    // ────────────────────────────────────────────────── decrypt helpers

    private static DecryptedRun decryptOneRun(StorageGroup msRuns, String runName,
                                                int datasetId, byte[] key,
                                                boolean headersEncrypted) {
        try (StorageGroup run = msRuns.openGroup(runName);
             StorageGroup sig = run.openGroup("signal_channels");
             StorageGroup idx = run.openGroup("spectrum_index")) {
            Map<String, byte[]> channels = new LinkedHashMap<>();
            String rawNames = (String) sig.getAttribute("channel_names");
            for (String cname : splitNames(rawNames)) {
                String segName = cname + "_segments";
                if (!sig.hasChild(segName)) continue;
                List<ChannelSegment> segs = readChannelSegments(sig, segName);
                channels.put(cname,
                    PerAUEncryption.decryptChannelFromSegments(segs, datasetId,
                                                                  cname, key));
            }

            List<AUHeaderPlaintext> auHeaders = null;
            if (headersEncrypted && idx.hasChild("au_header_segments")) {
                List<HeaderSegment> segs = readHeaderSegments(idx,
                                                                "au_header_segments");
                auHeaders = PerAUEncryption.decryptHeaderSegments(segs, datasetId,
                                                                     key);
            }
            return new DecryptedRun(channels, auHeaders);
        }
    }

    // ────────────────────────────────────────────── compound I/O helpers

    private static final List<CompoundField> CHANNEL_SEG_FIELDS = List.of(
        new CompoundField("offset", CompoundField.Kind.INT64),
        new CompoundField("length", CompoundField.Kind.UINT32),
        new CompoundField("iv", CompoundField.Kind.VL_BYTES),
        new CompoundField("tag", CompoundField.Kind.VL_BYTES),
        new CompoundField("ciphertext", CompoundField.Kind.VL_BYTES));

    private static final List<CompoundField> HEADER_SEG_FIELDS = List.of(
        new CompoundField("iv", CompoundField.Kind.VL_BYTES),
        new CompoundField("tag", CompoundField.Kind.VL_BYTES),
        new CompoundField("ciphertext", CompoundField.Kind.VL_BYTES));

    static void writeChannelSegments(StorageGroup parent, String name,
                                      List<ChannelSegment> segments) {
        if (parent.hasChild(name)) parent.deleteChild(name);
        List<Object[]> rows = new ArrayList<>(segments.size());
        for (ChannelSegment s : segments) {
            rows.add(new Object[]{ s.offset(), s.length(),
                                    s.iv(), s.tag(), s.ciphertext() });
        }
        try (StorageDataset ds = parent.createCompoundDataset(name,
                CHANNEL_SEG_FIELDS, rows.size())) {
            ds.writeAll(rows);
        }
    }

    @SuppressWarnings("unchecked")
    static List<ChannelSegment> readChannelSegments(StorageGroup parent,
                                                      String name) {
        try (StorageDataset ds = parent.openDataset(name)) {
            List<Object[]> rows = (List<Object[]>) ds.readAll();
            List<ChannelSegment> out = new ArrayList<>(rows.size());
            for (Object[] r : rows) {
                out.add(new ChannelSegment(
                    ((Number) r[0]).longValue(),
                    ((Number) r[1]).intValue(),
                    (byte[]) r[2], (byte[]) r[3], (byte[]) r[4]));
            }
            return out;
        }
    }

    static void writeHeaderSegments(StorageGroup parent, String name,
                                     List<HeaderSegment> segments) {
        if (parent.hasChild(name)) parent.deleteChild(name);
        List<Object[]> rows = new ArrayList<>(segments.size());
        for (HeaderSegment s : segments) {
            rows.add(new Object[]{ s.iv(), s.tag(), s.ciphertext() });
        }
        try (StorageDataset ds = parent.createCompoundDataset(name,
                HEADER_SEG_FIELDS, rows.size())) {
            ds.writeAll(rows);
        }
    }

    @SuppressWarnings("unchecked")
    static List<HeaderSegment> readHeaderSegments(StorageGroup parent,
                                                    String name) {
        try (StorageDataset ds = parent.openDataset(name)) {
            List<Object[]> rows = (List<Object[]>) ds.readAll();
            List<HeaderSegment> out = new ArrayList<>(rows.size());
            for (Object[] r : rows) {
                out.add(new HeaderSegment((byte[]) r[0], (byte[]) r[1],
                                            (byte[]) r[2]));
            }
            return out;
        }
    }

    // ─────────────────────────────────────────────────────── misc helpers

    private static List<String> runNames(StorageGroup msRuns) {
        List<String> out = new ArrayList<>();
        for (String n : msRuns.childNames()) {
            if (!n.startsWith("_") && msRuns.hasChild(n)) out.add(n);
        }
        return out;
    }

    private static List<String> splitNames(String raw) {
        if (raw == null || raw.isEmpty()) return List.of();
        String[] parts = raw.split(",");
        List<String> out = new ArrayList<>(parts.length);
        for (String p : parts) {
            String t = p.strip();
            if (!t.isEmpty()) out.add(t);
        }
        return out;
    }

    private static Object getAttrOr(StorageGroup g, String name, Object fallback) {
        if (!g.hasAttribute(name)) return fallback;
        Object v = g.getAttribute(name);
        return v == null ? fallback : v;
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

    private static double[] readDoubles(StorageGroup g, String name) {
        try (StorageDataset ds = g.openDataset(name)) {
            return (double[]) ds.readAll();
        }
    }

    private static byte[] doublesToLeBytes(double[] v) {
        ByteBuffer bb = ByteBuffer.allocate(v.length * 8).order(ByteOrder.LITTLE_ENDIAN);
        for (double d : v) bb.putDouble(d);
        return bb.array();
    }
}
