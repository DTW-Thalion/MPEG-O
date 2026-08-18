/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.genomics;

import htsjdk.samtools.reference.FastaSequenceIndex;
import htsjdk.samtools.reference.FastaSequenceIndexCreator;
import htsjdk.samtools.reference.FastaSequenceIndexEntry;
import htsjdk.samtools.reference.IndexedFastaSequenceFile;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.AbstractMap;
import java.util.AbstractSet;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

/**
 * Chromosome name to sequence bytes over an indexed FASTA that loads a
 * chromosome on first access and keeps only a few in memory, so a
 * whole-genome reference is never resident at once. Suits the streaming
 * importers as the {@code referenceChromSeqs} of a
 * {@link WrittenGenomicRun}. Python: {@code ttio.genomic.LazyReference}.
 */
public final class LazyReference extends AbstractMap<String, byte[]> {

    private final Path fasta;
    private final IndexedFastaSequenceFile file;
    private final LinkedHashMap<String, Long> lengths = new LinkedHashMap<>();
    private final int cacheChroms;
    private final LinkedHashMap<String, byte[]> cache;
    private byte[] setMd5;

    /** Two chromosomes cached. */
    public LazyReference(Path fasta) { this(fasta, 2); }

    /** {@code cacheChroms} chromosomes cached, least recently used out.
     *  Creates {@code <fasta>.fai} when absent. */
    public LazyReference(Path fasta, int cacheChroms) {
        this.fasta = fasta;
        this.cacheChroms = Math.max(1, cacheChroms);
        if (!Files.exists(fasta)) {
            throw new UncheckedIOException(new IOException("reference FASTA not found: " + fasta));
        }
        Path fai = fasta.resolveSibling(fasta.getFileName() + ".fai");
        try {
            if (!Files.exists(fai)) {
                FastaSequenceIndexCreator.create(fasta, false);
            }
            this.file = new IndexedFastaSequenceFile(fasta, new FastaSequenceIndex(fai));
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
        for (FastaSequenceIndexEntry e : file.getIndex()) {
            lengths.put(e.getContig(), e.getSize());
        }
        this.cache = new LinkedHashMap<>(16, 0.75f, true) {
            @Override protected boolean removeEldestEntry(Map.Entry<String, byte[]> eldest) {
                return size() > LazyReference.this.cacheChroms;
            }
        };
    }

    /** The FASTA path. */
    public Path path() { return fasta; }

    /** MD5 of the concatenated case-preserved sequences of every
     *  chromosome in alphabetic order of name: the reference-set digest
     *  every writer records (format spec section 10.10). Streams one
     *  chromosome at a time. */
    public byte[] setMd5() {
        if (setMd5 != null) return setMd5.clone();
        Path sidecar = fasta.resolveSibling(fasta.getFileName() + ".ttio-md5");
        String stamp;
        try {
            stamp = Files.size(fasta) + " " + (Files.getLastModifiedTime(fasta).toMillis() / 1000L);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
        // Cached in <fasta>.ttio-md5 as "<hex> <size> <mtime_s>", the same
        // sidecar the Python and ObjC readers use; trusted while size and
        // mtime match, rewritten otherwise, skipped when not writable.
        try {
            String[] parts = Files.readString(sidecar).trim().split("\\s+");
            if (parts.length == 3 && parts[0].length() == 32 && (parts[1] + " " + parts[2]).equals(stamp)) {
                setMd5 = java.util.HexFormat.of().parseHex(parts[0]);
                return setMd5.clone();
            }
        } catch (IOException | IllegalArgumentException ignored) {
            // no usable sidecar
        }
        try {
            java.security.MessageDigest md = java.security.MessageDigest.getInstance("MD5");
            java.util.List<String> names = new java.util.ArrayList<>(lengths.keySet());
            java.util.Collections.sort(names);
            for (String n : names) {
                md.update(file.getSequence(n).getBases());
            }
            setMd5 = md.digest();
        } catch (java.security.NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
        try {
            Files.writeString(sidecar, java.util.HexFormat.of().formatHex(setMd5) + " " + stamp + "\n");
        } catch (IOException ignored) {
            // read-only location: the in-process cache still applies
        }
        return setMd5.clone();
    }

    /** Length of {@code name} from the index, without loading it. */
    public long lengthOf(String name) {
        Long n = lengths.get(name);
        if (n == null) throw new IllegalArgumentException("no chromosome " + name);
        return n;
    }

    @Override public int size() { return lengths.size(); }
    @Override public boolean containsKey(Object key) { return lengths.containsKey(key); }
    @Override public Set<String> keySet() { return java.util.Collections.unmodifiableSet(lengths.keySet()); }

    @Override
    public byte[] get(Object key) {
        if (!(key instanceof String name) || !lengths.containsKey(name)) return null;
        byte[] seq = cache.get(name);
        if (seq != null) return seq;
        seq = file.getSequence(name).getBases();
        cache.put(name, seq);
        return seq;
    }

    /** Entries load their value on {@code getValue()}. */
    @Override
    public Set<Map.Entry<String, byte[]>> entrySet() {
        return new AbstractSet<>() {
            @Override public int size() { return lengths.size(); }
            @Override public Iterator<Map.Entry<String, byte[]>> iterator() {
                Iterator<String> names = lengths.keySet().iterator();
                return new Iterator<>() {
                    @Override public boolean hasNext() { return names.hasNext(); }
                    @Override public Map.Entry<String, byte[]> next() {
                        String n = names.next();
                        return new Map.Entry<>() {
                            @Override public String getKey() { return n; }
                            @Override public byte[] getValue() { return get(n); }
                            @Override public byte[] setValue(byte[] v) { throw new UnsupportedOperationException(); }
                        };
                    }
                };
            }
        };
    }
}
