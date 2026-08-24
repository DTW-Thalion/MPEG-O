/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.importers;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.genomics.ReferenceImport;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.io.ProgressSink;

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
import java.util.Iterator;
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

    /** Default emit-every-N cadence for the
     *  {@link #readUnaligned(String, String, String, AcquisitionMode, ProgressSink)}
     *  {@link ProgressSink}. Same default as {@link FastqReader}. */
    public static final int PROGRESS_INTERVAL_READS = 1000;

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
            iterateRecords(unescapeLiteralNewlines(in, path), (name, seq) -> {
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
        return readUnaligned(sampleName, platform, referenceUri,
            acquisitionMode, ProgressSink.discard());
    }

    /**
     * Parse the file as a set of unaligned reads, emitting per-read
     * {@link ProgressSink} callbacks.
     *
     * <p>Fires {@code progress.onProgress(done, -1L)} every
     * {@link #PROGRESS_INTERVAL_READS} records during the parse phase
     * (total is unknown until the trailing record flushes) and a final
     * {@code onProgress(total, total)} once the count is known.</p>
     *
     * @since 1.5.0
     */
    public WrittenGenomicRun readUnaligned(
        String sampleName, String platform, String referenceUri,
        AcquisitionMode acquisitionMode, ProgressSink progress
    ) throws IOException {
        final ProgressSink sink =
            (progress != null) ? progress : ProgressSink.discard();
        List<String> readNames = new ArrayList<>();
        ByteArrayOutputStream seqBuf  = new ByteArrayOutputStream();
        ByteArrayOutputStream qualBuf = new ByteArrayOutputStream();
        List<Long> offsetsL = new ArrayList<>();
        List<Integer> lengthsL = new ArrayList<>();
        long[] running = { 0L };
        try (InputStream in = openMaybeGzip(path)) {
            iterateRecords(unescapeLiteralNewlines(in, path), (name, seq) -> {
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
                long done = readNames.size();
                if (done % PROGRESS_INTERVAL_READS == 0) {
                    sink.onProgress(done, -1L);
                }
            });
        }
        if (readNames.isEmpty()) {
            throw new FastaParseException(
                "no FASTA records found in " + path
            );
        }
        sink.onProgress(readNames.size(), readNames.size());
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

    /** Convenience overload with no platform / reference URI that
     *  accepts a {@link ProgressSink}. */
    public WrittenGenomicRun readUnaligned(String sampleName,
                                           ProgressSink progress)
            throws IOException {
        return readUnaligned(sampleName, "", "", AcquisitionMode.GENOMIC_WGS,
            progress);
    }

    // ------------------------------------------------------------------
    // Streaming batches
    // ------------------------------------------------------------------

    /** Reads per streamed batch. */
    public static final int DEFAULT_BATCH_READS = 100_000;

    /** Decoded sequence + quality bytes per streamed batch by default
     *  (64 MiB). Bytes are the primary batch limit: a read count is
     *  blind to read length. */
    public static final long DEFAULT_BATCH_BYTES = 64L << 20;

    /** Batches of {@code batchReads} reads as unaligned
     *  {@link WrittenGenomicRun}s, each record carrying the
     *  SAM-unmapped sentinels of {@link #readUnaligned}. The iterator
     *  closes the input at EOF. */
    public Iterator<WrittenGenomicRun> iterBatches(
            String sampleName, String platform, String referenceUri,
            AcquisitionMode acquisitionMode, int batchReads) throws IOException {
        return iterBatches(sampleName, platform, referenceUri, acquisitionMode, batchReads, 0L);
    }

    /** As above with an explicit byte limit; a batch cuts at whichever
     *  of {@code batchReads} / {@code batchBytes} is hit first
     *  (0 = the default for each). */
    public Iterator<WrittenGenomicRun> iterBatches(
            String sampleName, String platform, String referenceUri,
            AcquisitionMode acquisitionMode, int batchReads, long batchBytesIn) throws IOException {
        if (batchReads < 1) throw new IllegalArgumentException("batchReads must be >= 1");
        final long batchBytes = batchBytesIn > 0 ? batchBytesIn : DEFAULT_BATCH_BYTES;
        InputStream in = openMaybeGzip(path);
        final RecordCursor cursor = new RecordCursor(unescapeLiteralNewlines(in, path));
        return new Iterator<>() {
            final List<String> names = new ArrayList<>();
            final List<byte[]> seqs = new ArrayList<>();
            WrittenGenomicRun next;
            boolean done;

            @Override public boolean hasNext() {
                if (next != null) return true;
                if (done) return false;
                try {
                    long pendingBytes = 0L;
                    while (names.size() < batchReads && pendingBytes < batchBytes) {
                        FastaRecord rec = cursor.next();
                        if (rec == null) break;
                        names.add(rec.name());
                        seqs.add(rec.seq());
                        pendingBytes += (long) rec.seq().length * 2L;
                    }
                } catch (IOException e) {
                    throw new java.io.UncheckedIOException(e);
                }
                if (names.isEmpty()) {
                    finish();
                    return false;
                }
                next = batch();
                names.clear(); seqs.clear();
                return true;
            }

            @Override public WrittenGenomicRun next() {
                if (!hasNext()) throw new java.util.NoSuchElementException();
                WrittenGenomicRun r = next;
                next = null;
                return r;
            }

            private void finish() {
                if (done) return;
                done = true;
                try { in.close(); } catch (IOException ignored) { }
            }

            private WrittenGenomicRun batch() {
                List<Long> offsetsL = new ArrayList<>(names.size());
                List<Integer> lengthsL = new ArrayList<>(names.size());
                ByteArrayOutputStream seqBuf = new ByteArrayOutputStream();
                ByteArrayOutputStream qualBuf = new ByteArrayOutputStream();
                long running = 0L;
                for (byte[] s : seqs) {
                    offsetsL.add(running);
                    lengthsL.add(s.length);
                    seqBuf.write(s, 0, s.length);
                    byte[] qualSentinel = new byte[s.length];
                    Arrays.fill(qualSentinel, QUAL_UNKNOWN_BYTE);
                    qualBuf.write(qualSentinel, 0, qualSentinel.length);
                    running += s.length;
                }
                return buildUnalignedRun(new ArrayList<>(names), seqBuf.toByteArray(),
                    qualBuf.toByteArray(), offsetsL, lengthsL, sampleName, platform,
                    referenceUri, acquisitionMode);
            }
        };
    }

    /** {@link #iterBatches} as a {@link GenomicStreamSource}. */
    public GenomicStreamSource stream(String name, String sampleName, int batchReads) {
        return stream(name, sampleName, batchReads, 0L);
    }

    /** As above with the byte limit of
     *  {@link #iterBatches(String, String, String, AcquisitionMode, int, long)}. */
    public GenomicStreamSource stream(String name, String sampleName, int batchReads, long batchBytes) {
        return new GenomicStreamSource(name, () -> {
            try {
                return iterBatches(sampleName, "", "", AcquisitionMode.GENOMIC_WGS,
                    batchReads, batchBytes);
            } catch (IOException e) {
                throw new java.io.UncheckedIOException(e);
            }
        }, null, false, null, null, false);
    }

    /** Default batch of 100 000 reads. */
    public GenomicStreamSource stream(String name, String sampleName) {
        return stream(name, sampleName, DEFAULT_BATCH_READS);
    }

    /** One parsed FASTA record. */
    private record FastaRecord(String name, byte[] seq) { }

    /** Pull-style counterpart of {@link #iterateRecords}: same line
     *  handling (CR dropped, blank lines skipped, header description
     *  stripped, sequence bytes before any header rejected), delivered
     *  one record per {@link #next} call instead of through a
     *  {@link RecordSink}. */
    private static final class RecordCursor {
        private final InputStream in;
        private String pendingName;
        private boolean eof;

        RecordCursor(InputStream in) { this.in = in; }

        /** The next record, or {@code null} at end of input. */
        FastaRecord next() throws IOException {
            if (eof && pendingName == null) return null;
            ByteArrayOutputStream lineBuf = new ByteArrayOutputStream();
            ByteArrayOutputStream seqBuf = new ByteArrayOutputStream();
            String currentName = pendingName;
            pendingName = null;
            int b;
            while (!eof) {
                b = in.read();
                if (b == -1) { eof = true; break; }
                if (b == '\n') {
                    byte[] line = lineBuf.toByteArray();
                    lineBuf.reset();
                    if (line.length == 0) continue;
                    if (line[0] == '>') {
                        String newName = parseHeader(line);
                        if (currentName != null) {
                            pendingName = newName;
                            return new FastaRecord(currentName, seqBuf.toByteArray());
                        }
                        currentName = newName;
                        seqBuf.reset();
                    } else {
                        if (currentName == null) {
                            throw new FastaParseException(
                                "FASTA sequence bytes encountered before any header line");
                        }
                        seqBuf.write(line);
                    }
                } else if (b != '\r') {
                    lineBuf.write(b);
                }
            }
            // Final line without trailing newline.
            byte[] line = lineBuf.toByteArray();
            if (line.length > 0) {
                if (line[0] == '>') {
                    String newName = parseHeader(line);
                    if (currentName != null) {
                        pendingName = newName;
                        return new FastaRecord(currentName, seqBuf.toByteArray());
                    }
                    currentName = newName;
                    seqBuf.reset();
                } else {
                    if (currentName == null) {
                        throw new FastaParseException(
                            "FASTA sequence bytes encountered before any header line");
                    }
                    seqBuf.write(line);
                }
            }
            if (currentName != null) {
                return new FastaRecord(currentName, seqBuf.toByteArray());
            }
            return null;
        }
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

    /**
     * Wrap {@code src} so any literal {@code 0x5C 0x6E} byte pair
     * (backslash + ASCII 'n') is transparently emitted as a single
     * 0x0A newline. Defends against FASTA files produced by buggy
     * TSV-to-FASTA converters or shell scripts that embedded
     * {@code \n} as a two-character separator between header and
     * sequence body instead of a real line break — without the
     * unescape, every record parses as an empty-sequence header
     * line and downstream encoding silently produces an empty
     * dataset with O(N) HDF5 overhead and zero real data.
     *
     * <p>Lone backslashes (not followed by ASCII 'n') are preserved
     * verbatim. Logs a one-line WARNING per file on first detection
     * so the user knows their input is malformed.</p>
     *
     * @since 1.3.0
     */
    static InputStream unescapeLiteralNewlines(InputStream src, Path path) {
        return new LiteralNewlineUnescapingInputStream(src, path);
    }

    private static final class LiteralNewlineUnescapingInputStream
            extends InputStream {

        private final InputStream src;
        private final Path path;
        private int pushback = -1;
        private boolean warned = false;

        LiteralNewlineUnescapingInputStream(InputStream src, Path path) {
            this.src  = src;
            this.path = path;
        }

        @Override
        public int read() throws IOException {
            if (pushback != -1) {
                int b = pushback;
                pushback = -1;
                return b;
            }
            int b = src.read();
            if (b != '\\') return b;
            int next = src.read();
            if (next == 'n') {
                if (!warned) {
                    warned = true;
                    java.util.logging.Logger
                        .getLogger(FastaReader.class.getName())
                        .warning("FASTA " + path + " contains literal "
                            + "'\\n' byte pairs inside record lines; "
                            + "treating each as a newline. This file is "
                            + "malformed — regenerate with real LF "
                            + "separators if you can.");
                }
                return '\n';
            }
            if (next != -1) pushback = next;
            return '\\';
        }

        @Override
        public int read(byte[] buf, int off, int len) throws IOException {
            if (len <= 0) return 0;
            int n = 0;
            int b;
            while (n < len && (b = read()) != -1) {
                buf[off + n++] = (byte) b;
            }
            return n == 0 ? -1 : n;
        }

        @Override
        public void close() throws IOException { src.close(); }
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
