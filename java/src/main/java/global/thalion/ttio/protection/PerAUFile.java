/* TTI-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: LGPL-3.0-or-later */
package global.thalion.ttio.protection;

import global.thalion.ttio.Enums;
import global.thalion.ttio.FeatureFlags;
import global.thalion.ttio.protection.PerAUEncryption.AUHeaderPlaintext;
import global.thalion.ttio.protection.PerAUEncryption.ChannelSegment;
import global.thalion.ttio.protection.PerAUEncryption.GcmResult;
import global.thalion.ttio.protection.PerAUEncryption.HeaderSegment;
import global.thalion.ttio.providers.CompoundField;
import global.thalion.ttio.providers.ProviderRegistry;
import global.thalion.ttio.providers.StorageDataset;
import global.thalion.ttio.providers.StorageGroup;
import global.thalion.ttio.providers.StorageProvider;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * v1.0 file-level per-Access-Unit encryption orchestrator.
 *
 * <p>Reads plaintext {@code <channel>_values} datasets from an
 * TTI-O file, encrypts each spectrum independently with
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
 * {@code ttio.encryption_per_au.encrypt_per_au / decrypt_per_au},
 * Objective-C {@code TTIOPerAUFile}.
 *
 *
 */
public final class PerAUFile {

    private PerAUFile() {}

    /** Result of {@link #decryptFile}: per-run, per-channel plaintext
     *  bytes; optional {@code auHeaders} list when
     *  {@code opt_encrypted_au_headers} is set. M90.11: optional
     *  {@code indexPlain} carries the four genomic_index columns
     *  recovered when the file was encrypted with the reserved
     *  {@code "_headers"} key. M90.12: {@code isGenomic} tags the
     *  run as genomic-uint8 (vs MS-float64) so the CLI can emit the
     *  right MPAD v1 dtype code without having to re-open the file. */
    public record DecryptedRun(Map<String, byte[]> channels,
                                 List<AUHeaderPlaintext> auHeaders,
                                 GenomicIndexPlain indexPlain,
                                 boolean isGenomic) {
        public DecryptedRun(Map<String, byte[]> channels,
                              List<AUHeaderPlaintext> auHeaders) {
            this(channels, auHeaders, null, false);
        }

        public DecryptedRun(Map<String, byte[]> channels,
                              List<AUHeaderPlaintext> auHeaders,
                              GenomicIndexPlain indexPlain) {
            this(channels, auHeaders, indexPlain, false);
        }
    }

    /** M90.11: plaintext genomic_index columns recovered from a file
     *  encrypted with the reserved {@code "_headers"} key. */
    public record GenomicIndexPlain(List<String> chromosomes,
                                      long[] positions,
                                      byte[] mappingQualities,
                                      int[] flags) {}

    /** M90.11: reserved key name in the {@code keyMap} that signals
     *  the caller wants the genomic_index columns encrypted. */
    public static final String HEADERS_KEY_NAME = "_headers";

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

            int datasetId = 1;
            try (StorageGroup study = root.openGroup("study")) {
                if (study.hasChild("ms_runs")) {
                    try (StorageGroup msRuns = study.openGroup("ms_runs")) {
                        for (String runName : runNames(msRuns)) {
                            encryptOneRun(msRuns, runName, datasetId, key,
                                            encryptHeaders);
                            datasetId++;
                        }
                    }
                }
                // M90.1: continue dataset_id_counter into genomic_runs.
                if (study.hasChild("genomic_runs")) {
                    try (StorageGroup gRuns = study.openGroup("genomic_runs")) {
                        for (String runName : runNames(gRuns)) {
                            encryptOneGenomicRun(gRuns, runName, datasetId, key);
                            datasetId++;
                        }
                    }
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

            int datasetId = 1;
            try (StorageGroup study = root.openGroup("study")) {
                if (study.hasChild("ms_runs")) {
                    try (StorageGroup msRuns = study.openGroup("ms_runs")) {
                        for (String runName : runNames(msRuns)) {
                            out.put(runName, decryptOneRun(msRuns, runName,
                                                             datasetId, key,
                                                             headersEncrypted));
                            datasetId++;
                        }
                    }
                }
                // M90.1: dataset_id_counter continues into genomic_runs so
                // AAD reconstruction matches the encrypt path exactly.
                if (study.hasChild("genomic_runs")) {
                    try (StorageGroup gRuns = study.openGroup("genomic_runs")) {
                        for (String runName : runNames(gRuns)) {
                            out.put(runName, decryptOneGenomicRun(
                                gRuns, runName, datasetId, key));
                            datasetId++;
                        }
                    }
                }
            }
            return out;
        } finally {
            sp.close();
        }
    }

    // ─────────────────────────────────────────── M90.4 region encryption

    /** M90.4: encrypt genomic signal channels with a per-chromosome
     *  key map. Reads whose chromosome appears in {@code keyMap} get
     *  AES-256-GCM encrypted with that key; reads on chromosomes not
     *  in the map are stored as clear segments (empty IV/tag,
     *  plaintext rides in the ciphertext slot — see
     *  {@link PerAUEncryption#encryptChannelByRegion}).
     *
     *  <p>MS runs are NOT touched — chromosome is a genomic concept.
     *  Use {@link #encryptFile} for MS encryption.
     *
     *  <p>Sets both {@link FeatureFlags#OPT_PER_AU_ENCRYPTION} and
     *  {@link FeatureFlags#OPT_REGION_KEYED_ENCRYPTION} on the root. */
    public static void encryptByRegion(String path,
                                         Map<String, byte[]> keyMap,
                                         String providerName) {
        for (Map.Entry<String, byte[]> e : keyMap.entrySet()) {
            if (e.getValue().length != 32) {
                throw new IllegalArgumentException(
                    "AES-256-GCM key for chromosome '" + e.getKey()
                    + "' must be 32 bytes, got " + e.getValue().length);
            }
        }
        // M90.11: split off the reserved "_headers" entry. The
        // remaining map drives per-AU signal-channel dispatch.
        Map<String, byte[]> chromosomeKeys = new LinkedHashMap<>();
        byte[] headersKey = null;
        for (Map.Entry<String, byte[]> e : keyMap.entrySet()) {
            if (HEADERS_KEY_NAME.equals(e.getKey())) {
                headersKey = e.getValue();
            } else {
                chromosomeKeys.put(e.getKey(), e.getValue());
            }
        }
        StorageProvider sp = ProviderRegistry.open(path,
            StorageProvider.Mode.READ_WRITE, providerName);
        try {
            StorageGroup root = sp.rootGroup();
            FeatureFlags flags = FeatureFlags.readFrom(root);

            try (StorageGroup study = root.openGroup("study")) {
                if (!study.hasChild("genomic_runs")) {
                    return;  // no genomic data — nothing to encrypt
                }
                // Match the dataset_id_counter convention from the MS
                // path: MS runs occupy 1..N, genomic N+1..N+M. Region
                // encryption only touches genomic, but we still walk MS
                // first to advance the counter.
                int nMs = 0;
                if (study.hasChild("ms_runs")) {
                    try (StorageGroup msRuns = study.openGroup("ms_runs")) {
                        nMs = runNames(msRuns).size();
                    }
                }
                int datasetId = nMs + 1;
                // Signal-channel encryption runs in two cases (M90.11
                // semantics, mirroring Python's run_signal_encrypt):
                //   (a) caller supplied chromosome keys (M90.4 path)
                //   (b) caller supplied an empty key_map (M90.4 no-op)
                // The only path that SKIPS signal-channel encryption
                // is the headers-only case (key_map == {"_headers": K}).
                boolean runSignalEncrypt =
                    !chromosomeKeys.isEmpty() || headersKey == null;
                try (StorageGroup gRuns = study.openGroup("genomic_runs")) {
                    for (String runName : runNames(gRuns)) {
                        encryptOneGenomicRunByRegion(gRuns, runName,
                                                       datasetId,
                                                       chromosomeKeys,
                                                       headersKey,
                                                       runSignalEncrypt);
                        datasetId++;
                    }
                }
            }

            List<String> updatedFeatures = new ArrayList<>(flags.features());
            // Feature-flag set rules (mirror Python):
            //  * OPT_PER_AU_ENCRYPTION — set whenever signal-channel
            //    encryption ran (chromosome keys present OR empty
            //    key_map no-op path) OR when headers_key is provided.
            //  * OPT_REGION_KEYED_ENCRYPTION — only when at least one
            //    chromosome key was provided.
            //  * OPT_ENCRYPTED_AU_HEADERS — set when "_headers" key
            //    was used (M90.11).
            // The two Python predicates collapse: "chromosomeKeys
            // present OR headersKey is null" covers the M90.4 path
            // (incl. empty key_map no-op) and "headersKey != null"
            // covers the M90.11 headers-only path. Their union is
            // always true once we reach this point, so we
            // unconditionally add the flag.
            if (!updatedFeatures.contains(FeatureFlags.OPT_PER_AU_ENCRYPTION)) {
                updatedFeatures.add(FeatureFlags.OPT_PER_AU_ENCRYPTION);
            }
            if (!chromosomeKeys.isEmpty()
                    && !updatedFeatures.contains(FeatureFlags.OPT_REGION_KEYED_ENCRYPTION)) {
                updatedFeatures.add(FeatureFlags.OPT_REGION_KEYED_ENCRYPTION);
            }
            if (headersKey != null
                    && !updatedFeatures.contains(FeatureFlags.OPT_ENCRYPTED_AU_HEADERS)) {
                updatedFeatures.add(FeatureFlags.OPT_ENCRYPTED_AU_HEADERS);
            }
            java.util.Collections.sort(updatedFeatures);
            new FeatureFlags(flags.formatVersion(), updatedFeatures).writeTo(root);
        } finally {
            sp.close();
        }
    }

    /** M90.4: decrypt a region-encrypted file using a per-chromosome
     *  key map. Caller may supply a subset of the keys used at
     *  encryption time — clear segments decode without any key, but
     *  encrypted segments whose chromosome key isn't in {@code keyMap}
     *  raise {@link IllegalStateException}.
     *
     *  <p>Returns {@code {runName -> DecryptedRun}}. The MS runs are
     *  decrypted via the standard single-key path inside this function
     *  iff the file also carries MS encryption under the supplied
     *  key — the M90.4 convention is that MS encryption (if any)
     *  uses the standard {@link #encryptFile} entry point first, and
     *  region encryption layers on top for genomic only. */
    public static Map<String, DecryptedRun> decryptByRegion(String path,
            Map<String, byte[]> keyMap, String providerName) {
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
            // M90.11: when the file carries opt_encrypted_au_headers,
            // decrypt requires the reserved "_headers" key. Without
            // it we can't even reconstruct the chromosomes column
            // needed for per-AU dispatch on signal channels.
            boolean headersEncrypted =
                flags.has(FeatureFlags.OPT_ENCRYPTED_AU_HEADERS);
            byte[] headersKey = keyMap.get(HEADERS_KEY_NAME);
            if (headersEncrypted && headersKey == null) {
                throw new IllegalStateException(
                    "file at " + path + " carries opt_encrypted_au_headers; "
                    + "caller must provide a '_headers' entry in keyMap "
                    + "to decrypt the genomic_index columns");
            }
            Map<String, byte[]> chromosomeKeys = new LinkedHashMap<>();
            for (Map.Entry<String, byte[]> e : keyMap.entrySet()) {
                if (!HEADERS_KEY_NAME.equals(e.getKey())) {
                    chromosomeKeys.put(e.getKey(), e.getValue());
                }
            }

            try (StorageGroup study = root.openGroup("study")) {
                int nMs = 0;
                if (study.hasChild("ms_runs")) {
                    try (StorageGroup msRuns = study.openGroup("ms_runs")) {
                        nMs = runNames(msRuns).size();
                    }
                }
                if (!study.hasChild("genomic_runs")) {
                    return out;
                }
                int datasetId = nMs + 1;
                try (StorageGroup gRuns = study.openGroup("genomic_runs")) {
                    for (String runName : runNames(gRuns)) {
                        out.put(runName, decryptOneGenomicRunByRegion(
                            gRuns, runName, datasetId, chromosomeKeys,
                            headersEncrypted, headersKey));
                        datasetId++;
                    }
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

            int[] lengths = readInts(idx, "lengths");
            // v1.10 #10: offsets is no longer stored on disk by default;
            // synthesize from cumsum(lengths). Pre-v1.10 files have it.
            long[] offsets = idx.hasChild("offsets")
                ? readLongs(idx, "offsets")
                : global.thalion.ttio.genomics.GenomicIndex.offsetsFromLengths(lengths);

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

    // ─────────────────────────────────────── genomic encrypt / decrypt

    /** M90.1: encrypt one {@code /study/genomic_runs/<name>/} subtree.
     *  Sequences and qualities are uint8 (one byte per logical
     *  element), AAD reuses the standard
     *  {@code dataset_id || au_sequence || channel_name} layout. */
    private static void encryptOneGenomicRun(StorageGroup gRuns, String runName,
                                               int datasetId, byte[] key) {
        try (StorageGroup run = gRuns.openGroup(runName);
             StorageGroup sig = run.openGroup("signal_channels");
             StorageGroup idx = run.openGroup("genomic_index")) {

            int[] lengths = readInts(idx, "lengths");
            // v1.10 #10: offsets is no longer stored on disk by default;
            // synthesize from cumsum(lengths). Pre-v1.10 files have it.
            long[] offsets = idx.hasChild("offsets")
                ? readLongs(idx, "offsets")
                : global.thalion.ttio.genomics.GenomicIndex.offsetsFromLengths(lengths);

            for (String cname : new String[]{"sequences", "qualities"}) {
                if (!sig.hasChild(cname)) continue;
                byte[] plaintext;
                try (StorageDataset ds = sig.openDataset(cname)) {
                    plaintext = (byte[]) ds.readAll();
                }
                List<ChannelSegment> segs =
                    PerAUEncryption.encryptChannelToSegments(
                        plaintext, offsets, lengths, datasetId, cname, key, 1);
                writeChannelSegments(sig, cname + "_segments", segs);
                sig.deleteChild(cname);
                sig.setAttribute(cname + "_algorithm", "aes-256-gcm");
            }
        }
    }

    /** M90.1: decrypt one genomic run subtree. Returns a
     *  {@link DecryptedRun} whose {@code channels} map carries
     *  {@code "sequences"} and {@code "qualities"} as flat uint8
     *  byte arrays (no element-width unpacking). */
    private static DecryptedRun decryptOneGenomicRun(StorageGroup gRuns,
            String runName, int datasetId, byte[] key) {
        try (StorageGroup run = gRuns.openGroup(runName);
             StorageGroup sig = run.openGroup("signal_channels")) {
            Map<String, byte[]> channels = new LinkedHashMap<>();
            for (String cname : new String[]{"sequences", "qualities"}) {
                String segName = cname + "_segments";
                if (!sig.hasChild(segName)) continue;
                List<ChannelSegment> segs = readChannelSegments(sig, segName);
                channels.put(cname,
                    PerAUEncryption.decryptChannelFromSegments(
                        segs, datasetId, cname, key, 1));
            }
            return new DecryptedRun(channels, null, null, /* isGenomic */ true);
        }
    }

    /** M90.4 + M90.11: encrypt one genomic run with per-chromosome
     *  dispatch on signal channels and optional reserved-{@code "_headers"}
     *  encryption of the genomic_index columns.
     *
     *  <p>{@code runSignalEncrypt} is {@code false} only in the
     *  M90.11 headers-only case (key_map == {"_headers": K}) where
     *  the caller wants the index columns encrypted but the signal
     *  channels left untouched. */
    private static void encryptOneGenomicRunByRegion(StorageGroup gRuns,
            String runName, int datasetId,
            Map<String, byte[]> chromosomeKeys,
            byte[] headersKey,
            boolean runSignalEncrypt) {
        try (StorageGroup run = gRuns.openGroup(runName);
             StorageGroup sig = run.openGroup("signal_channels");
             StorageGroup idx = run.openGroup("genomic_index")) {

            int[] lengths = readInts(idx, "lengths");
            // v1.10 #10: offsets is no longer stored on disk by default;
            // synthesize from cumsum(lengths). Pre-v1.10 files have it.
            long[] offsets = idx.hasChild("offsets")
                ? readLongs(idx, "offsets")
                : global.thalion.ttio.genomics.GenomicIndex.offsetsFromLengths(lengths);
            List<String> chromosomes = readChromosomes(idx);

            if (runSignalEncrypt) {
                for (String cname : new String[]{"sequences", "qualities"}) {
                    if (!sig.hasChild(cname)) continue;
                    byte[] plaintext;
                    try (StorageDataset ds = sig.openDataset(cname)) {
                        plaintext = (byte[]) ds.readAll();
                    }
                    List<ChannelSegment> segs =
                        PerAUEncryption.encryptChannelByRegion(
                            plaintext, offsets, lengths, chromosomes,
                            datasetId, cname, chromosomeKeys);
                    writeChannelSegments(sig, cname + "_segments", segs);
                    sig.deleteChild(cname);
                    sig.setAttribute(cname + "_algorithm",
                                      "aes-256-gcm-by-region");
                }
            }

            // M90.11: encrypt genomic_index columns under the
            // reserved _headers key.
            if (headersKey != null) {
                encryptGenomicIndex(idx, datasetId, headersKey, chromosomes);
            }
        }
    }

    /** M90.4 + M90.11: decrypt one region-encrypted genomic run. */
    private static DecryptedRun decryptOneGenomicRunByRegion(
            StorageGroup gRuns, String runName, int datasetId,
            Map<String, byte[]> chromosomeKeys,
            boolean headersEncrypted, byte[] headersKey) {
        try (StorageGroup run = gRuns.openGroup(runName);
             StorageGroup sig = run.openGroup("signal_channels");
             StorageGroup idx = run.openGroup("genomic_index")) {
            // M90.11: decrypt the genomic_index columns first so the
            // per-AU signal-channel dispatch (which needs chromosomes)
            // can proceed even when the source columns were encrypted.
            List<String> chromosomes;
            GenomicIndexPlain indexPlain = null;
            if (headersEncrypted) {
                indexPlain = decryptGenomicIndex(idx, datasetId, headersKey);
                chromosomes = indexPlain.chromosomes();
            } else {
                chromosomes = readChromosomes(idx);
            }
            Map<String, byte[]> channels = new LinkedHashMap<>();
            for (String cname : new String[]{"sequences", "qualities"}) {
                String segName = cname + "_segments";
                if (!sig.hasChild(segName)) continue;
                List<ChannelSegment> segs = readChannelSegments(sig, segName);
                channels.put(cname,
                    PerAUEncryption.decryptChannelByRegion(
                        segs, chromosomes, datasetId, cname, chromosomeKeys));
            }
            return new DecryptedRun(channels, null, indexPlain,
                                      /* isGenomic */ true);
        }
    }

    /** M90.11: encrypt the four genomic_index columns
     *  (chromosomes, positions, mapping_qualities, flags) and replace
     *  the plaintext datasets with {@code <column>_encrypted} blobs
     *  containing {@code iv || tag || ciphertext}. {@code offsets} /
     *  {@code lengths} stay plaintext (structural framing).
     *
     *  <p>Per-column AES-GCM with AAD =
     *  {@code "genomic_headers:" + datasetId + ":" + column_name}.
     *  Chromosomes (a VL compound) is JSON-serialised before
     *  encryption to match Python's
     *  {@code json.dumps(chromosomes).encode("utf-8")} byte form. */
    private static void encryptGenomicIndex(StorageGroup idx, int datasetId,
                                              byte[] key,
                                              List<String> chromosomes) {
        long[] positions = readLongs(idx, "positions");
        byte[] mapqs;
        try (StorageDataset ds = idx.openDataset("mapping_qualities")) {
            mapqs = (byte[]) ds.readAll();
        }
        int[] flags = readInts(idx, "flags");

        Map<String, byte[]> columns = new LinkedHashMap<>();
        columns.put("chromosomes",
            chromosomesJson(chromosomes).getBytes(StandardCharsets.UTF_8));
        columns.put("positions", longsToLeBytes(positions));
        columns.put("mapping_qualities", mapqs.clone());
        columns.put("flags", intsToLeBytes(flags));

        for (Map.Entry<String, byte[]> e : columns.entrySet()) {
            String colName = e.getKey();
            byte[] plaintext = e.getValue();
            byte[] aad = ("genomic_headers:" + datasetId + ":" + colName)
                .getBytes(StandardCharsets.US_ASCII);
            GcmResult r = PerAUEncryption.encryptWithAad(plaintext, key, aad, null);
            byte[] blob = new byte[r.iv().length + r.tag().length
                                     + r.ciphertext().length];
            System.arraycopy(r.iv(), 0, blob, 0, r.iv().length);
            System.arraycopy(r.tag(), 0, blob, r.iv().length, r.tag().length);
            System.arraycopy(r.ciphertext(), 0, blob,
                              r.iv().length + r.tag().length,
                              r.ciphertext().length);
            if (idx.hasChild(colName)) {
                idx.deleteChild(colName);
            }
            // L1 (Task #82 Phase B.1): the on-disk chromosomes column
            // is now decomposed into chromosome_ids + chromosome_names
            // — also delete those when encrypting the logical
            // "chromosomes" column.
            if ("chromosomes".equals(colName)) {
                if (idx.hasChild("chromosome_ids")) {
                    idx.deleteChild("chromosome_ids");
                }
                if (idx.hasChild("chromosome_names")) {
                    idx.deleteChild("chromosome_names");
                }
            }
            String encName = colName + "_encrypted";
            if (idx.hasChild(encName)) {
                idx.deleteChild(encName);
            }
            try (StorageDataset out = idx.createDataset(encName,
                    Enums.Precision.UINT8, blob.length, 0,
                    Enums.Compression.NONE, 0)) {
                out.writeAll(blob);
            }
        }
    }

    /** M90.11: inverse of {@link #encryptGenomicIndex}. Returns the
     *  four plaintext columns. */
    private static GenomicIndexPlain decryptGenomicIndex(
            StorageGroup idx, int datasetId, byte[] key) {
        List<String> chromosomes = null;
        long[] positions = null;
        byte[] mapqs = null;
        int[] flags = null;
        for (String colName : new String[]{
                "chromosomes", "positions", "mapping_qualities", "flags"}) {
            String encName = colName + "_encrypted";
            if (!idx.hasChild(encName)) {
                throw new IllegalStateException(
                    "genomic_index/" + encName + " missing — file does not "
                    + "appear to carry M90.11 encrypted headers");
            }
            byte[] blob;
            try (StorageDataset ds = idx.openDataset(encName)) {
                blob = (byte[]) ds.readAll();
            }
            if (blob.length < 12 + 16) {
                throw new IllegalStateException(
                    "genomic_index/" + encName + " too short for IV+TAG");
            }
            byte[] iv = Arrays.copyOfRange(blob, 0, 12);
            byte[] tag = Arrays.copyOfRange(blob, 12, 28);
            byte[] ciphertext = Arrays.copyOfRange(blob, 28, blob.length);
            byte[] aad = ("genomic_headers:" + datasetId + ":" + colName)
                .getBytes(StandardCharsets.US_ASCII);
            byte[] plain = PerAUEncryption.decryptWithAad(iv, tag, ciphertext,
                                                            key, aad);
            switch (colName) {
                case "chromosomes":
                    chromosomes = chromosomesFromJson(
                        new String(plain, StandardCharsets.UTF_8));
                    break;
                case "positions":
                    positions = leBytesToLongs(plain);
                    break;
                case "mapping_qualities":
                    mapqs = plain;
                    break;
                case "flags":
                    flags = leBytesToInts(plain);
                    break;
            }
        }
        return new GenomicIndexPlain(chromosomes, positions, mapqs, flags);
    }

    /** Match Python {@code json.dumps(list_of_str)} with default
     *  separators ({@code ", "} between items). */
    static String chromosomesJson(List<String> chromosomes) {
        StringBuilder sb = new StringBuilder();
        sb.append('[');
        for (int i = 0; i < chromosomes.size(); i++) {
            if (i > 0) sb.append(", ");
            sb.append('"');
            // Chromosome names are simple ASCII identifiers (chr1,
            // chr6, chrX, ...) — no escaping needed in practice. We
            // still escape backslash + double-quote for safety.
            String s = chromosomes.get(i);
            for (int j = 0; j < s.length(); j++) {
                char c = s.charAt(j);
                if (c == '"' || c == '\\') sb.append('\\');
                sb.append(c);
            }
            sb.append('"');
        }
        sb.append(']');
        return sb.toString();
    }

    /** Tiny JSON parser for the chromosomes column — accepts the
     *  flat string-array shape produced by {@link #chromosomesJson}
     *  or by Python's {@code json.dumps}. */
    static List<String> chromosomesFromJson(String json) {
        List<String> out = new ArrayList<>();
        int n = json.length();
        int i = 0;
        // Skip leading whitespace and the opening '['.
        while (i < n && Character.isWhitespace(json.charAt(i))) i++;
        if (i >= n || json.charAt(i) != '[') {
            throw new IllegalStateException(
                "chromosomes JSON must start with '[': " + json);
        }
        i++;
        while (i < n) {
            while (i < n && (Character.isWhitespace(json.charAt(i))
                              || json.charAt(i) == ',')) i++;
            if (i >= n) break;
            char c = json.charAt(i);
            if (c == ']') break;
            if (c != '"') {
                throw new IllegalStateException(
                    "chromosomes JSON expected '\"' at " + i + ": " + json);
            }
            i++;  // past opening quote
            StringBuilder sb = new StringBuilder();
            while (i < n) {
                char ch = json.charAt(i);
                if (ch == '\\' && i + 1 < n) {
                    sb.append(json.charAt(i + 1));
                    i += 2;
                    continue;
                }
                if (ch == '"') {
                    i++;
                    break;
                }
                sb.append(ch);
                i++;
            }
            out.add(sb.toString());
        }
        return out;
    }

    /** Read the genomic_index chromosome columns into a
     *  {@code List<String>}. L1 (Task #82 Phase B.1, 2026-05-01):
     *  chromosomes are stored as {@code chromosome_ids} (uint16) +
     *  {@code chromosome_names} (compound) instead of a single
     *  VL-string compound. */
    @SuppressWarnings("unchecked")
    private static List<String> readChromosomes(StorageGroup idx) {
        short[] ids;
        try (StorageDataset ds = idx.openDataset("chromosome_ids")) {
            ids = (short[]) ds.readAll();
        }
        List<Object[]> nameRows;
        try (StorageDataset ds = idx.openDataset("chromosome_names")) {
            nameRows = (List<Object[]>) ds.readAll();
        }
        List<String> nameTable = new ArrayList<>(nameRows.size());
        for (Object[] r : nameRows) {
            Object v = r[0];
            if (v == null) {
                nameTable.add("");
            } else if (v instanceof byte[] b) {
                nameTable.add(new String(b, java.nio.charset.StandardCharsets.UTF_8));
            } else {
                nameTable.add(v.toString());
            }
        }
        List<String> out = new ArrayList<>(ids.length);
        for (short id : ids) {
            int idx2 = Short.toUnsignedInt(id);
            out.add(idx2 < nameTable.size() ? nameTable.get(idx2) : "");
        }
        return out;
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

    private static byte[] longsToLeBytes(long[] v) {
        ByteBuffer bb = ByteBuffer.allocate(v.length * 8).order(ByteOrder.LITTLE_ENDIAN);
        for (long l : v) bb.putLong(l);
        return bb.array();
    }

    private static byte[] intsToLeBytes(int[] v) {
        ByteBuffer bb = ByteBuffer.allocate(v.length * 4).order(ByteOrder.LITTLE_ENDIAN);
        for (int i : v) bb.putInt(i);
        return bb.array();
    }

    private static long[] leBytesToLongs(byte[] b) {
        if ((b.length & 7) != 0) {
            throw new IllegalStateException(
                "leBytesToLongs: length " + b.length + " not multiple of 8");
        }
        ByteBuffer bb = ByteBuffer.wrap(b).order(ByteOrder.LITTLE_ENDIAN);
        long[] out = new long[b.length / 8];
        for (int i = 0; i < out.length; i++) out[i] = bb.getLong();
        return out;
    }

    private static int[] leBytesToInts(byte[] b) {
        if ((b.length & 3) != 0) {
            throw new IllegalStateException(
                "leBytesToInts: length " + b.length + " not multiple of 4");
        }
        ByteBuffer bb = ByteBuffer.wrap(b).order(ByteOrder.LITTLE_ENDIAN);
        int[] out = new int[b.length / 4];
        for (int i = 0; i < out.length; i++) out[i] = bb.getInt();
        return out;
    }
}
