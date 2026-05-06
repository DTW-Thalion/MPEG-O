/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.conformance;

import global.thalion.ttio.Enums;
import global.thalion.ttio.FeatureFlags;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.providers.Hdf5Provider;
import global.thalion.ttio.providers.StorageDataset;
import global.thalion.ttio.providers.StorageGroup;
import global.thalion.ttio.providers.StorageProvider;

import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * tio-browser Phase 0 Task 0.6 — standalone CLI helper that writes the
 * canonical embedded-reference fixture to a single {@code .tio} file
 * via the same direct-graft pattern the Python {@code _seed_references}
 * and ObjC {@code seedReferences} test helpers use.
 *
 * <p>Direct-graft (rather than the production writer's
 * {@code embedReferencesForRuns} path through
 * {@link SpectralDataset#create}) keeps this tool runnable in CI
 * without the JNI rANS / FQZCOMP_NX16_Z native library: the production
 * writer always traverses the genomic-run subtree's quality codec,
 * which currently requires {@code libttio_rans} for any non-empty
 * run. Direct-graft writes the {@code /study/references/<uri>/}
 * subtree byte-identically to what {@code embedReferencesForRuns}
 * produces (sorted chromosome names, {@code @md5} as 32-char lowercase
 * hex, {@code @reference_uri}, per-chromosome {@code @length}, UINT8
 * {@code data} dataset).
 *
 * <p>Usage: {@code java ... RefXLangWriter <out.tio>}.
 */
public final class RefXLangWriter {

    private RefXLangWriter() {}

    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            System.err.println("usage: RefXLangWriter <out.tio>");
            System.exit(2);
        }
        String outPath = args[0];

        // 1. Write a runs-empty .tio. No genomic runs → no FQZCOMP path.
        SpectralDataset.create(outPath, "xlang", "XLANG001",
            List.of(), List.of(),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();

        // 2. Direct-graft /study/references/<uri>/ into the canonical layout.
        Map<String, byte[]> refSeqs = new LinkedHashMap<>();
        refSeqs.put("chr1", "ACGTACGTACGT".getBytes());
        refSeqs.put("chr2", "TTTTAAAACCCC".getBytes());
        seedReferences(outPath, "xlang-test-v1", refSeqs);
    }

    /** Direct-graft the canonical {@code /study/references/<uri>/}
     *  layout. Mirrors {@code SpectralDataset.embedReferencesForRuns}
     *  exactly so the on-disk shape — including the {@code @md5}
     *  attribute — is byte-identical to what the production writer
     *  emits. */
    static void seedReferences(String path, String uri,
                               Map<String, byte[]> chromSeqs)
            throws Exception {
        List<String> sortedNames = new ArrayList<>(chromSeqs.keySet());
        Collections.sort(sortedNames);
        // Production writer ({@code SpectralDataset.referenceMd5ForRun}
        // / Python's {@code _reference_md5_for_run} / ObjC's
        // {@code _TTIO_M93_ReferenceMD5ForRun}) uses the
        // sequence-concat-only form sorted by chromosome name, NOT the
        // public-API {@code ReferenceImport.computeMd5}'s name+0x0A
        // +seq+0x0A canonical form. We mirror the writer exactly so a
        // file produced by this helper is byte-equal to one produced
        // by the production writer (when its native gate is satisfied).
        MessageDigest md = MessageDigest.getInstance("MD5");
        for (String n : sortedNames) md.update(chromSeqs.get(n));
        byte[] md5 = md.digest();
        String md5Hex = bytesToHex(md5);

        try (StorageProvider provider = new Hdf5Provider()
                .open(path, StorageProvider.Mode.READ_WRITE)) {
            StorageGroup root = provider.rootGroup();
            try (StorageGroup study = root.openGroup("study")) {
                StorageGroup refsGrp;
                if (study.hasChild("references")) {
                    refsGrp = study.openGroup("references");
                } else {
                    refsGrp = study.createGroup("references");
                }
                try (var ignored = refsGrp;
                     StorageGroup refGrp = refsGrp.createGroup(uri)) {
                    refGrp.setAttribute("md5", md5Hex);
                    refGrp.setAttribute("reference_uri", uri);
                    try (StorageGroup chromsGrp = refGrp.createGroup("chromosomes")) {
                        for (String chromName : sortedNames) {
                            byte[] seq = chromSeqs.get(chromName);
                            try (StorageGroup c = chromsGrp.createGroup(chromName)) {
                                c.setAttribute("length", (long) seq.length);
                                StorageDataset ds;
                                try {
                                    ds = c.createDataset("data",
                                        Enums.Precision.UINT8, seq.length,
                                        65536, Enums.Compression.ZLIB, 6);
                                } catch (UnsupportedOperationException e) {
                                    ds = c.createDataset("data",
                                        Enums.Precision.UINT8, seq.length,
                                        0, Enums.Compression.NONE, 0);
                                }
                                try (var dsClose = ds) {
                                    dsClose.writeAll(seq);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static String bytesToHex(byte[] bytes) {
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            int v = b & 0xff;
            sb.append(Character.forDigit((v >>> 4) & 0xf, 16));
            sb.append(Character.forDigit(v & 0xf, 16));
        }
        return sb.toString();
    }
}
