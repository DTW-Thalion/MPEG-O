/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.importers;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.genomics.ReferenceImport;
import global.thalion.ttio.genomics.WrittenGenomicRun;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.zip.GZIPInputStream;

/**
 * FASTA importer. Parses FASTA files into either a
 * {@link ReferenceImport} (reference genome paired with BAM/CRAM
 * input) or an unaligned {@link WrittenGenomicRun} (panel / target
 * list / quality-stripped reads).
 *
 * <p>Gzip-compressed input is auto-detected via the {@code 1f 8b}
 * magic bytes regardless of file extension.</p>
 *
 * <p>FASTA records are header-line {@code ">name [desc]"} followed
 * by one or more sequence lines until the next header or EOF. Header
 * description (anything after the first whitespace) is dropped.</p>
 *
 * <p><b>Cross-language equivalents:</b> Python
 * {@code ttio.importers.fasta.FastaReader}, Objective-C
 * {@code TTIOFastaReader}.</p>
 */
public class FastaReader {

    /** SAM unmapped sentinels — match BamReader's "QUAL absent" path. */
    static final int  UNMAPPED_FLAG       = 4;
    static final String UNMAPPED_CHROM    = "*";
    static final long UNMAPPED_POS        = 0L;
    static final byte UNMAPPED_MAPQ       = (byte) 0xFF;
    static final String UNMAPPED_CIGAR    = "*";
    static final byte QUAL_UNKNOWN_BYTE   = (byte) 0xFF;

    private final Path path;

    public FastaReader(Path path) {
        this.path = path;
        if (!Files.exists(path)) {
            throw new IllegalArgumentException(
                "FASTA file not found: " + path
            );
        }
    }

    public Path path() { return path; }

    /**
     * Parse the file as a reference genome.
     *
     * @param uri reference URI to record on the result; if
     *            {@code null}, derived from the file's stem.
     * @return populated {@link ReferenceImport}.
     */
    public ReferenceImport readReference(String uri) throws IOException {
        List<String> names = new ArrayList<>();
        List<byte[]> seqs  = new ArrayList<>();
        try (InputStream in = openMaybeGzip(path)) {
            iterateRecords(in, (name, seq) -> {
                names.add(name);
                seqs.add(seq);
            });
        }
        if (names.isEmpty()) {
            throw new FastaParseException(
                "no FASTA records found in " + path
            );
        }
        String effectiveUri = (uri != null) ? uri : deriveUri(path);
        return new ReferenceImport(effectiveUri, names, seqs);
    }

    /** Convenience overload that derives the URI from the filename. */
    public ReferenceImport readReference() throws IOException {
        return readReference(null);
    }

    /**
     * Parse the file as a set of unaligned reads.
     *
     * <p>Each FASTA record becomes one read with SAM-unmapped sentinel
     * values. Qualities are filled with {@code 0xFF} (matching
     * {@link BamReader}'s "QUAL absent" convention).</p>
     */
    public WrittenGenomicRun readUnaligned(
        String sampleName, String platform, String referenceUri,
        AcquisitionMode acquisitionMode
    ) throws IOException {
        List<String> readNames = new ArrayList<>();
        ByteArrayOutputStream seqBuf  = new ByteArrayOutputStream();
        ByteArrayOutputStream qualBuf = new ByteArrayOutputStream();
        List<Long> offsetsL = new ArrayList<>();
        List<Integer> lengthsL = new ArrayList<>();
        long[] running = { 0L };
        try (InputStream in = openMaybeGzip(path)) {
            iterateRecords(in, (name, seq) -> {
                readNames.add(name);
                offsetsL.add(running[0]);
                lengthsL.add(seq.length);
                try {
                    seqBuf.write(seq);
                } catch (IOException ioe) {
                    throw new RuntimeException(ioe);
                }
                byte[] qualSentinel = new byte[seq.length];
                Arrays.fill(qualSentinel, QUAL_UNKNOWN_BYTE);
                try {
                    qualBuf.write(qualSentinel);
                } catch (IOException ioe) {
                    throw new RuntimeException(ioe);
                }
                running[0] += seq.length;
            });
        }
        if (readNames.isEmpty()) {
            throw new FastaParseException(
                "no FASTA records found in " + path
            );
        }
        return buildUnalignedRun(
            readNames, seqBuf.toByteArray(), qualBuf.toByteArray(),
            offsetsL, lengthsL,
            sampleName, platform, referenceUri, acquisitionMode
        );
    }

    /** Convenience overload with no platform / reference URI. */
    public WrittenGenomicRun readUnaligned(String sampleName) throws IOException {
        return readUnaligned(sampleName, "", "", AcquisitionMode.GENOMIC_WGS);
    }

    // ------------------------------------------------------------------
    // Shared helpers
    // ------------------------------------------------------------------

    /**
     * Open {@code path} for reading, transparently decompressing if
     * the file starts with the {@code 1f 8b} gzip magic.
     */
    static InputStream openMaybeGzip(Path path) throws IOException {
        BufferedInputStream bis = new BufferedInputStream(Files.newInputStream(path));
        bis.mark(2);
        int b1 = bis.read();
        int b2 = bis.read();
        bis.reset();
        if (b1 == 0x1f && b2 == 0x8b) {
            return new GZIPInputStream(bis);
        }
        return bis;
    }

    @FunctionalInterface
    interface RecordSink {
        void accept(String name, byte[] seq);
    }

    /**
     * Iterate FASTA records, emitting (name, sequence_bytes) for each.
     * Header description (anything after the first whitespace) is
     * stripped. Sequence is the concatenation of all body lines (each
     * with trailing CR/LF removed).
     */
    static void iterateRecords(InputStream in, RecordSink sink) throws IOException {
        ByteArrayOutputStream lineBuf = new ByteArrayOutputStream();
        String currentName = null;
        ByteArrayOutputStream seqBuf = new ByteArrayOutputStream();
        int b;
        while ((b = in.read()) != -1) {
            if (b == '\n') {
                processLine(lineBuf, sink, currentName, seqBuf);
                if (lineBuf.size() > 0 && lineBuf.toByteArray()[0] == '>') {
                    currentName = parseHeader(lineBuf.toByteArray());
                    seqBuf.reset();
                }
                lineBuf.reset();
            } else if (b == '\r') {
                // Skip CR; LF will trigger line completion.
            } else {
                lineBuf.write(b);
            }
        }
        // Final line without trailing newline.
        if (lineBuf.size() > 0) {
            processLine(lineBuf, sink, currentName, seqBuf);
            if (lineBuf.size() > 0 && lineBuf.toByteArray()[0] == '>') {
                currentName = parseHeader(lineBuf.toByteArray());
                seqBuf.reset();
            }
        }
        // Flush the trailing record.
        if (currentName != null) {
            sink.accept(currentName, seqBuf.toByteArray());
        }
    }

    private static void processLine(
        ByteArrayOutputStream lineBuf, RecordSink sink,
        String currentName, ByteArrayOutputStream seqBuf
    ) throws IOException {
        if (lineBuf.size() == 0) return;
        byte[] line = lineBuf.toByteArray();
        if (line[0] == '>') {
            // Emit any in-progress record before resetting.
            if (currentName != null) {
                sink.accept(currentName, seqBuf.toByteArray());
            }
            // Caller resets seqBuf and parses header after this returns.
        } else {
            if (currentName == null) {
                throw new FastaParseException(
                    "FASTA sequence bytes encountered before any header line"
                );
            }
            seqBuf.write(line);
        }
    }

    private static String parseHeader(byte[] line) {
        // line starts with '>' — grab the first whitespace-delimited
        // token after that.
        int i = 1;
        while (i < line.length && (line[i] == ' ' || line[i] == '\t')) i++;
        int start = i;
        while (i < line.length && line[i] != ' ' && line[i] != '\t') i++;
        if (i == start) {
            throw new FastaParseException(
                "FASTA header missing a name token (line starts with '>')"
            );
        }
        return new String(line, start, i - start, StandardCharsets.UTF_8);
    }

    static String deriveUri(Path path) {
        String name = path.getFileName().toString();
        String lower = name.toLowerCase();
        if (lower.endsWith(".gz")) {
            name = name.substring(0, name.length() - 3);
            lower = name.toLowerCase();
        }
        for (String ext : new String[]{".fasta", ".fastq", ".fna", ".fa", ".fq"}) {
            if (lower.endsWith(ext)) {
                name = name.substring(0, name.length() - ext.length());
                break;
            }
        }
        return name;
    }

    static WrittenGenomicRun buildUnalignedRun(
        List<String> readNames, byte[] sequences, byte[] qualities,
        List<Long> offsetsL, List<Integer> lengthsL,
        String sampleName, String platform, String referenceUri,
        AcquisitionMode acquisitionMode
    ) {
        int n = readNames.size();
        long[] positions = new long[n];
        byte[] mapq = new byte[n];
        int[]  flags = new int[n];
        long[] offsets = new long[n];
        int[]  lengths = new int[n];
        long[] matePositions = new long[n];
        int[]  templateLengths = new int[n];
        List<String> chromosomes = new ArrayList<>(n);
        List<String> cigars = new ArrayList<>(n);
        List<String> mateChromosomes = new ArrayList<>(n);
        for (int i = 0; i < n; i++) {
            positions[i] = UNMAPPED_POS;
            mapq[i] = UNMAPPED_MAPQ;
            flags[i] = UNMAPPED_FLAG;
            offsets[i] = offsetsL.get(i);
            lengths[i] = lengthsL.get(i);
            matePositions[i] = -1L;
            templateLengths[i] = 0;
            chromosomes.add(UNMAPPED_CHROM);
            cigars.add(UNMAPPED_CIGAR);
            mateChromosomes.add(UNMAPPED_CHROM);
        }
        return new WrittenGenomicRun(
            acquisitionMode,
            referenceUri == null ? "" : referenceUri,
            platform == null ? "" : platform,
            sampleName == null ? "" : sampleName,
            positions, mapq, flags,
            sequences, qualities,
            offsets, lengths,
            cigars, readNames, mateChromosomes,
            matePositions, templateLengths,
            chromosomes,
            Compression.ZLIB
        );
    }
}
