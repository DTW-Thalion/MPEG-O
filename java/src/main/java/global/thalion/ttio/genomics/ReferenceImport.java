/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.genomics;

import global.thalion.ttio.providers.StorageDataset;
import global.thalion.ttio.providers.StorageGroup;

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
 * order-invariant), then concatenates each
 * {@code name_utf8 + 0x0A + sequence_bytes + 0x0A} and digests the
 * result. Cross-language byte-equal.</p>
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
     * algorithm sorts by name (order-invariant), then writes
     * {@code utf8(name) + 0x0A + sequence + 0x0A} for each entry into
     * an MD5 digest.
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
                md.update(name.getBytes(java.nio.charset.StandardCharsets.UTF_8));
                md.update((byte) 0x0A);
                md.update(indexByName.get(name));
                md.update((byte) 0x0A);
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
