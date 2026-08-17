/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import global.thalion.ttio.hdf5.Hdf5File;
import global.thalion.ttio.hdf5.Hdf5Group;
import global.thalion.ttio.providers.StorageDataset;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.List;

/**
 * Resolve a reference chromosome sequence for REF_DIFF decode.
 *
 * <p>Lookup chain (per M93 design Q5c — hard error on miss):
 * <ol>
 *   <li>Embedded {@code /study/references/<uri>/} in the open .tio file.</li>
 *   <li>External FASTA at {@code externalReferencePath} or
 *       {@code REF_PATH} environment variable.</li>
 *   <li>{@link RefMissingException} (no partial decode).</li>
 * </ol>
 *
 * <p>The MD5 attribute on the embedded reference group is verified
 * against the {@code expectedMd5} argument; mismatches raise
 * {@link RefMissingException} rather than silently returning the wrong
 * sequence.
 *
 * <p>Cross-language equivalents:
 * <ul>
 *   <li>Python: {@code ttio.genomic.reference_resolver.ReferenceResolver}</li>
 *   <li>Objective-C: {@code TTIOReferenceResolver}</li>
 * </ul>
 */
public final class ReferenceResolver {

    private final Hdf5File h5File;
    private final Path externalReferencePath;

    /** Construct a resolver bound to an open HDF5 file. The external
     *  reference path defaults to the {@code REF_PATH} env var when
     *  {@code externalReferencePath} is {@code null}. */
    public ReferenceResolver(Hdf5File h5File, Path externalReferencePath) {
        this.h5File = h5File;
        this.externalReferencePath = externalReferencePath != null
            ? externalReferencePath : envPath();
    }

    /** Convenience constructor: external path falls back to
     *  {@code REF_PATH}. */
    public ReferenceResolver(Hdf5File h5File) {
        this(h5File, null);
    }

    private static Path envPath() {
        String p = System.getenv("REF_PATH");
        return (p != null && !p.isEmpty()) ? Path.of(p) : null;
    }

    /** Return the chromosome's reference sequence as uppercase ACGTN
     *  bytes.
     *
     *  @throws RefMissingException when the reference can't be found or
     *      its MD5 doesn't match. */
    public byte[] resolve(String uri, byte[] expectedMd5, String chromosome) {
        // 1. Try embedded.
        if (h5File != null) {
            try (Hdf5Group root = h5File.rootGroup()) {
                if (root.hasChild("study")) {
                    try (Hdf5Group study = root.openGroup("study")) {
                        if (study.hasChild("references")) {
                            try (Hdf5Group refs = study.openGroup("references")) {
                                if (refs.hasChild(uri)) {
                                    return resolveEmbedded(refs, uri,
                                        expectedMd5, chromosome);
                                }
                            }
                        }
                    }
                }
            }
        }

        // 2. Try external FASTA.
        if (externalReferencePath != null
            && Files.exists(externalReferencePath)) {
            byte[] seq = externalChromosome(externalReferencePath, expectedMd5, chromosome);
            if (seq != null) {
                return seq;
            }
        }

        // 3. Hard error.
        String envValue = System.getenv("REF_PATH");
        throw new RefMissingException(
            "reference '" + uri + "' (chromosome '" + chromosome
            + "') not found in file's /study/references/ and not resolvable "
            + "via REF_PATH (" + (envValue == null ? "<unset>" : envValue)
            + "). Provide via externalReferencePath constructor arg or set "
            + "REF_PATH.");
    }

    private static byte[] resolveEmbedded(
        Hdf5Group refs, String uri, byte[] expectedMd5, String chromosome) {
        try (Hdf5Group refGrp = refs.openGroup(uri)) {
            String md5Hex = refGrp.readStringAttribute("md5");
            byte[] embeddedMd5 = hexToBytes(md5Hex);
            if (!java.util.Arrays.equals(embeddedMd5, expectedMd5)) {
                throw new RefMissingException(
                    "MD5 mismatch for embedded reference '" + uri
                    + "': expected " + bytesToHex(expectedMd5)
                    + ", got " + md5Hex);
            }
            if (!refGrp.hasChild("chromosomes")) {
                throw new RefMissingException(
                    "embedded reference '" + uri
                    + "' has no chromosomes/ subgroup");
            }
            try (Hdf5Group chroms = refGrp.openGroup("chromosomes")) {
                if (!chroms.hasChild(chromosome)) {
                    List<String> covered = chroms.childNames();
                    java.util.Collections.sort(covered);
                    throw new RefMissingException(
                        "chromosome '" + chromosome
                        + "' not embedded in reference '" + uri
                        + "' — covered_chromosomes are " + covered);
                }
                try (Hdf5Group chrom = chroms.openGroup(chromosome)) {
                    // Wrap as StorageGroup for the layout dispatch:
                    // data_packed (2-bit + run mask) when present,
                    // legacy raw data otherwise.
                    var adapter = global.thalion.ttio.providers
                        .Hdf5Provider.adapterForGroup(chrom);
                    return global.thalion.ttio.genomics.PackedReference
                        .readChromosomeBytes(adapter);
                }
            }
        }
    }

    /** Tiny FASTA reader — extract a single chromosome's sequence as
     *  bytes. Returns {@code null} if the chromosome is not present.
     *  Matches headers on the first whitespace-delimited token after
     *  {@code >}. */
    private static final java.util.Map<Path, global.thalion.ttio.genomics.LazyReference> LAZY =
        new java.util.concurrent.ConcurrentHashMap<>();
    private static final java.util.Map<Path, byte[]> SET_MD5 =
        new java.util.concurrent.ConcurrentHashMap<>();

    /** Read {@code chromosome} from the external FASTA through its .fai
     *  index and check {@code expectedMd5} against, in order: the md5 of
     *  that chromosome's case-preserved bytes, of its upper-cased bytes
     *  (both the pre-1.9 external check, which only ever matched a
     *  single-contig FASTA), then the reference-set md5 of the whole
     *  FASTA (every chromosome, alphabetic order, case preserved: the
     *  digest the writers record). Returns the upper-cased sequence, or
     *  null when the chromosome is not in the FASTA. */
    private static byte[] externalChromosome(Path path, byte[] expectedMd5, String chromosome) {
        Path key = path.toAbsolutePath();
        global.thalion.ttio.genomics.LazyReference ref =
            LAZY.computeIfAbsent(key, k -> new global.thalion.ttio.genomics.LazyReference(k, 2));
        if (!ref.containsKey(chromosome)) {
            return null;
        }
        byte[] raw = ref.get(chromosome);
        byte[] upper = new byte[raw.length];
        for (int i = 0; i < raw.length; i++) {
            byte b = raw[i];
            upper[i] = (b >= 'a' && b <= 'z') ? (byte) (b - 32) : b;
        }
        if (java.util.Arrays.equals(md5(raw), expectedMd5)
                || java.util.Arrays.equals(md5(upper), expectedMd5)) {
            return upper;
        }
        byte[] setMd5 = SET_MD5.computeIfAbsent(key, k -> ref.setMd5());
        if (java.util.Arrays.equals(setMd5, expectedMd5)) {
            return upper;
        }
        throw new RefMissingException(
            "MD5 mismatch for external reference at " + path + ": expected "
            + bytesToHex(expectedMd5) + ", got " + bytesToHex(setMd5)
            + " for the whole FASTA and " + bytesToHex(md5(raw))
            + " for chromosome " + chromosome);
    }

    private static byte[] md5(byte[] data) {
        try {
            return MessageDigest.getInstance("MD5").digest(data);
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    private static byte[] hexToBytes(String hex) {
        if (hex == null || (hex.length() & 1) != 0) {
            throw new RefMissingException(
                "embedded @md5 attribute is not even-length hex: " + hex);
        }
        byte[] out = new byte[hex.length() / 2];
        for (int i = 0; i < out.length; i++) {
            int hi = Character.digit(hex.charAt(2 * i), 16);
            int lo = Character.digit(hex.charAt(2 * i + 1), 16);
            if (hi < 0 || lo < 0) {
                throw new RefMissingException(
                    "embedded @md5 attribute contains non-hex chars: " + hex);
            }
            out[i] = (byte) ((hi << 4) | lo);
        }
        return out;
    }

    private static String bytesToHex(byte[] buf) {
        StringBuilder sb = new StringBuilder(buf.length * 2);
        for (byte b : buf) sb.append(String.format("%02x", b & 0xFF));
        return sb.toString();
    }
}
