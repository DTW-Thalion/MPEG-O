/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.genomics;

import global.thalion.ttio.Enums;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.providers.StorageDataset;
import global.thalion.ttio.providers.StorageGroup;
import global.thalion.ttio.providers.StorageProvider;

import java.io.ByteArrayOutputStream;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/**
 * Reference-FASTA value class staged for embedding into a {@code .tio}
 * container.
 *
 * <p>A {@code ReferenceImport} is the parsed result of a reference-FASTA
 * file (many short or long chromosome records, no quality scores). It
 * carries the chromosome names, per-chromosome sequence bytes, and a
 * content-MD5 suitable for the {@code @md5} attribute on
 * {@code /study/references/<uri>/} groups.</p>
 *
 * <p><b>Cross-language equivalents:</b> Python
 * {@code ttio.genomic.reference_import.ReferenceImport}, Objective-C
 * {@code TTIOReferenceImport}.</p>
 *
 * <p>The MD5 algorithm sorts chromosomes by name (so the digest is
 * order-invariant), then concatenates the per-chromosome
 * {@code sequence_bytes} verbatim (case-preserving, no framing) and
 * digests the result. Cross-language byte-equal. Unified in v1.1.0
 * with the REF_DIFF_V2 auto-embed writer's stamp; the previous
 * name-framed form is gone.</p>
 */
public final class ReferenceImport {

    private final String uri;
    private final List<String> chromosomes;
    private final List<byte[]> sequences;
    private final byte[] md5;

    /**
     * Construct a reference import. Computes MD5 from the chromosome
     * set if {@code md5} is {@code null}.
     *
     * @param uri          reference URI (e.g. {@code "GRCh38.p14"}).
     * @param chromosomes  chromosome names in FASTA file order.
     * @param sequences    per-chromosome sequence bytes (case-preserving).
     * @param md5          16-byte content MD5, or {@code null} to compute.
     */
    public ReferenceImport(
        String uri, List<String> chromosomes, List<byte[]> sequences, byte[] md5
    ) {
        this.uri = Objects.requireNonNull(uri, "uri");
        Objects.requireNonNull(chromosomes, "chromosomes");
        Objects.requireNonNull(sequences, "sequences");
        if (chromosomes.size() != sequences.size()) {
            throw new IllegalArgumentException(
                "chromosomes / sequences length mismatch: "
                    + chromosomes.size() + " vs " + sequences.size()
            );
        }
        this.chromosomes = List.copyOf(chromosomes);
        // sequences kept as a read-only view of the originals; copy
        // the list but not the byte arrays.
        this.sequences = Collections.unmodifiableList(new ArrayList<>(sequences));
        if (md5 == null) {
            this.md5 = computeMd5(this.chromosomes, this.sequences);
        } else {
            if (md5.length != 16) {
                throw new IllegalArgumentException(
                    "md5 must be 16 bytes, got " + md5.length
                );
            }
            this.md5 = md5.clone();
        }
    }

    /** Convenience constructor that always computes the MD5 from the
     *  chromosome set. */
    public ReferenceImport(
        String uri, List<String> chromosomes, List<byte[]> sequences
    ) {
        this(uri, chromosomes, sequences, null);
    }

    /**
     * Compute the canonical content-MD5 over a chromosome set. The
     * algorithm sorts by name (order-invariant), then concatenates
     * the per-chromosome sequence bytes verbatim (case-preserving,
     * no framing) into an MD5 digest. Matches the REF_DIFF_V2
     * auto-embed writer's stamp byte-for-byte (unified in v1.1.0).
     */
    public static byte[] computeMd5(List<String> chromosomes, List<byte[]> sequences) {
        if (chromosomes.size() != sequences.size()) {
            throw new IllegalArgumentException(
                "chromosomes / sequences length mismatch: "
                    + chromosomes.size() + " vs " + sequences.size()
            );
        }
        // Build a (name, seq) list and sort by name.
        Map<String, byte[]> indexByName = new LinkedHashMap<>();
        for (int i = 0; i < chromosomes.size(); i++) {
            indexByName.put(chromosomes.get(i), sequences.get(i));
        }
        List<String> sortedNames = new ArrayList<>(indexByName.keySet());
        Collections.sort(sortedNames);
        try {
            MessageDigest md = MessageDigest.getInstance("MD5");
            for (String name : sortedNames) {
                md.update(indexByName.get(name));
            }
            return md.digest();
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("MD5 unavailable on this JVM", e);
        }
    }

    /** Reference URI. */
    public String uri() { return uri; }

    /** Chromosome names in FASTA file order. */
    public List<String> chromosomes() { return chromosomes; }

    /**
     * Per-chromosome sequence bytes (case-preserving). Returned in
     * FASTA file order; positionally aligned with
     * {@link #chromosomes()}.
     */
    public List<byte[]> sequences() { return sequences; }

    /** 16-byte content MD5. Returns a defensive copy. */
    public byte[] md5() { return md5.clone(); }

    /** Sum of sequence lengths across all chromosomes. */
    public long totalBases() {
        long n = 0;
        for (byte[] s : sequences) n += s.length;
        return n;
    }

    /**
     * Look up a chromosome's sequence by name.
     *
     * @throws java.util.NoSuchElementException if not present.
     */
    public byte[] chromosome(String name) {
        for (int i = 0; i < chromosomes.size(); i++) {
            if (chromosomes.get(i).equals(name)) {
                return sequences.get(i);
            }
        }
        List<String> known = new ArrayList<>(chromosomes);
        Collections.sort(known);
        throw new java.util.NoSuchElementException(
            "chromosome '" + name + "' not present in reference '"
                + uri + "' (known: " + known + ")"
        );
    }

    /** Returns the lowercase-hex form of the content MD5. */
    public String md5Hex() {
        StringBuilder sb = new StringBuilder(32);
        for (byte b : md5) {
            sb.append(String.format("%02x", b));
        }
        return sb.toString();
    }

    /**
     * Read an embedded reference from {@code /study/references/<uri>/}.
     *
     * <p>Layout (matches the writer in
     * {@code SpectralDataset.embedReferencesForRuns}):</p>
     * <ul>
     *   <li>{@code refGroup} attribute {@code reference_uri} = the
     *       reference URI; falls back to {@code refGroup.name()}.</li>
     *   <li>{@code refGroup} attribute {@code md5} = lowercase-hex
     *       content MD5; preserved verbatim into the returned
     *       {@code ReferenceImport} so byte-for-byte round-trip is
     *       maintained.</li>
     *   <li>{@code refGroup/chromosomes/} = sub-group containing one
     *       child per chromosome.</li>
     *   <li>{@code refGroup/chromosomes/<name>/data} = UINT8 dataset of
     *       sequence bytes (case-preserving).</li>
     * </ul>
     *
     * <p>Chromosomes are returned in the order
     * {@link StorageGroup#childNames()} reports them — the writer
     * sorts alphabetically before persisting, so for any file written
     * by this library the order is alphabetic.</p>
     *
     * @param refGroup the {@code /study/references/<uri>/} group
     * @return a fully-populated {@code ReferenceImport}
     * @since 1.1.0
     */
    public static ReferenceImport readFromGroup(StorageGroup refGroup) {
        Objects.requireNonNull(refGroup, "refGroup");

        // URI: prefer @reference_uri, fall back to the group name.
        String uri;
        if (refGroup.hasAttribute("reference_uri")) {
            Object v = refGroup.getAttribute("reference_uri");
            uri = v != null ? v.toString() : refGroup.name();
        } else {
            uri = refGroup.name();
        }

        // MD5: preserve verbatim from @md5 (lowercase hex) when
        // present, so the read-back ReferenceImport carries the same
        // digest bytes as the writer used.
        byte[] md5 = null;
        if (refGroup.hasAttribute("md5")) {
            Object v = refGroup.getAttribute("md5");
            if (v != null) {
                md5 = parseHexLocal(v.toString());
            }
        }

        List<String> chromNames = new ArrayList<>();
        List<byte[]> seqs = new ArrayList<>();
        try (StorageGroup chromsGrp = refGroup.openGroup("chromosomes")) {
            for (String name : chromsGrp.childNames()) {
                try (StorageGroup chromGrp = chromsGrp.openGroup(name)) {
                    try (StorageDataset ds = chromGrp.openDataset("data")) {
                        byte[] bytes = (byte[]) ds.readAll();
                        chromNames.add(name);
                        seqs.add(bytes);
                    }
                }
            }
        }

        return new ReferenceImport(uri, chromNames, seqs, md5);
    }

    /**
     * Embed this reference at {@code /study/references/<uri>/} inside
     * {@code dataset}'s open storage backing.
     *
     * <p>Layout (cross-language byte-equal — matches Python's
     * {@code ReferenceImport.write_to_dataset} and the canonical
     * embed-helper writer used by {@code embedReference=true}
     * runs):</p>
     *
     * <ul>
     *   <li>{@code /study/references/<uri>/} group with
     *       {@code @md5} (32-char lowercase hex) and
     *       {@code @reference_uri} attributes.</li>
     *   <li>{@code chromosomes/<name>/} sub-group per chromosome,
     *       in alphabetic order, with an {@code @length} (int64)
     *       attribute.</li>
     *   <li>{@code chromosomes/<name>/data} UINT8 ZLIB-compressed
     *       dataset of sequence bytes.</li>
     * </ul>
     *
     * <p>If a reference with the same {@code uri} is already
     * embedded and {@code overwrite} is {@code false}, throws
     * {@link IllegalStateException} (mirrors Python's
     * {@code FileExistsError}). When {@code overwrite} is
     * {@code true}, the existing group is deleted first.</p>
     *
     * @param dataset   open dataset; must expose a writable
     *                  {@link StorageProvider} via
     *                  {@link SpectralDataset#provider()}.
     * @param overwrite if {@code true}, replace any existing
     *                  reference under the same URI.
     * @throws IllegalStateException if {@code overwrite=false} and a
     *         reference with the same URI is already embedded, or if
     *         the dataset has no open writable provider.
     * @since 1.1.0
     */
    public void writeToDataset(SpectralDataset dataset, boolean overwrite) {
        Objects.requireNonNull(dataset, "dataset");
        StorageProvider provider = dataset.provider();
        if (provider == null || !provider.isOpen()) {
            throw new IllegalStateException(
                "ReferenceImport.writeToDataset requires an open dataset "
                + "with a writable provider; got "
                + (provider == null ? "null provider" : "closed provider")
                + ".");
        }
        try (StorageGroup root = provider.rootGroup()) {
            StorageGroup study;
            if (root.hasChild("study")) {
                study = root.openGroup("study");
            } else {
                study = root.createGroup("study");
            }
            try (StorageGroup ignoredStudy = study) {
                StorageGroup refsGrp;
                if (study.hasChild("references")) {
                    refsGrp = study.openGroup("references");
                } else {
                    refsGrp = study.createGroup("references");
                }
                try (StorageGroup ignoredRefs = refsGrp) {
                    if (refsGrp.hasChild(uri)) {
                        if (!overwrite) {
                            throw new IllegalStateException(
                                "reference '" + uri + "' already embedded "
                                + "at /study/references/" + uri + "; "
                                + "pass overwrite=true to replace.");
                        }
                        refsGrp.deleteChild(uri);
                    }
                    try (StorageGroup refGrp = refsGrp.createGroup(uri)) {
                        refGrp.setAttribute("md5", md5Hex());
                        refGrp.setAttribute("reference_uri", uri);
                        try (StorageGroup chromsGrp = refGrp.createGroup("chromosomes")) {
                            // Build a (name -> seq) map and sort by
                            // name so the on-disk child order matches
                            // the canonical embed-helper writer
                            // byte-for-byte.
                            Map<String, byte[]> byName = new LinkedHashMap<>();
                            for (int i = 0; i < chromosomes.size(); i++) {
                                byName.put(chromosomes.get(i), sequences.get(i));
                            }
                            List<String> sortedNames = new ArrayList<>(byName.keySet());
                            Collections.sort(sortedNames);
                            for (String chromName : sortedNames) {
                                byte[] seq = byName.get(chromName);
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
                                    try (StorageDataset closeMe = ds) {
                                        closeMe.writeAll(seq);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /**
     * Convenience overload for {@link #writeToDataset(SpectralDataset, boolean)}
     * that defaults {@code overwrite} to {@code false}, mirroring
     * Python's keyword-only default.
     *
     * @since 1.1.0
     */
    public void writeToDataset(SpectralDataset dataset) {
        writeToDataset(dataset, false);
    }

    /** Local hex-decoder for the {@code @md5} attribute. Returns
     *  {@code null} if the input is not a 32-char hex string (so the
     *  4-arg constructor falls back to recomputing). */
    private static byte[] parseHexLocal(String hex) {
        if (hex == null || hex.length() != 32) return null;
        byte[] out = new byte[16];
        for (int i = 0; i < 16; i++) {
            int hi = Character.digit(hex.charAt(i * 2), 16);
            int lo = Character.digit(hex.charAt(i * 2 + 1), 16);
            if (hi < 0 || lo < 0) return null;
            out[i] = (byte) ((hi << 4) | lo);
        }
        return out;
    }
}
