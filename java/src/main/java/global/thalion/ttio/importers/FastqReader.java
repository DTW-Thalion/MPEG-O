/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.importers;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.io.ProgressSink;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;

/**
 * FASTQ importer. Parses FASTQ files into unaligned
 * {@link WrittenGenomicRun} instances.
 *
 * <p>Each four-line record ({@code @name}, sequence, {@code +},
 * qualities) becomes one read; SAM unmapped sentinels are written
 * ({@code flags=4}, {@code chrom="*"}, {@code pos=0},
 * {@code mapq=255}, {@code cigar="*"}).</p>
 *
 * <p>Phred encoding is auto-detected; pass {@link #FastqReader(Path,Integer)}
 * with an explicit {@code 33} or {@code 64} to override. Internal
 * storage is always Phred+33 ASCII.</p>
 *
 * <p><b>Cross-language equivalents:</b> Python
 * {@code ttio.importers.fastq.FastqReader}, Objective-C
 * {@code TTIOFastqReader}.</p>
 */
public class FastqReader {

    /** Default emit-every-N cadence for {@link ProgressSink} callbacks.
     *  Small enough that even small input files get visible updates,
     *  large enough that the per-callback overhead stays well below 1%
     *  of parse time. */
    public static final int PROGRESS_INTERVAL_READS = 1000;

    private final Path path;
    private final Integer forcedPhred;
    private Integer detectedPhred = null;

    public FastqReader(Path path) { this(path, null); }

    public FastqReader(Path path, Integer forcedPhred) {
        this.path = path;
        if (forcedPhred != null && forcedPhred != 33 && forcedPhred != 64) {
            throw new IllegalArgumentException(
                "forcedPhred must be 33 or 64 (got " + forcedPhred + ")"
            );
        }
        this.forcedPhred = forcedPhred;
        if (!java.nio.file.Files.exists(path)) {
            throw new IllegalArgumentException(
                "FASTQ file not found: " + path
            );
        }
    }

    public Path path() { return path; }

    /**
     * Phred offset (33 or 64) actually applied to the most recent
     * {@link #read(String,String,String,AcquisitionMode)} call.
     *
     * @throws IllegalStateException if {@link #read} hasn't run yet.
     */
    public int detectedPhredOffset() {
        if (detectedPhred == null) {
            throw new IllegalStateException("call FastqReader.read() first");
        }
        return detectedPhred;
    }

    /**
     * Heuristic Phred-offset detection over a quality-bytes sample.
     *
     * <p>Rule:
     * <ul>
     *   <li>any byte {@code b < 59} => Phred+33 (Phred+64 starts at
     *       {@code b == 64}).
     *   <li>else if every byte is in {@code [64, 104]} => Phred+64.
     *   <li>else => Phred+33 (default).
     * </ul>
     */
    public static int detectPhredOffset(byte[] qualities) {
        if (qualities.length == 0) return 33;
        int lo = 256, hi = -1;
        for (byte b : qualities) {
            int v = b & 0xFF;
            if (v < lo) lo = v;
            if (v > hi) hi = v;
        }
        if (lo < 59) return 33;
        if (lo >= 64 && hi <= 104) return 64;
        return 33;
    }

    public WrittenGenomicRun read(String sampleName) throws IOException {
        return read(sampleName, "", "", AcquisitionMode.GENOMIC_WGS,
            ProgressSink.discard());
    }

    /**
     * Parse the file and return an unaligned {@link WrittenGenomicRun}.
     *
     * <p>Quality bytes are normalised to Phred+33 internally
     * (verbatim ASCII storage). The detected source offset is
     * recorded on {@link #detectedPhredOffset()}.</p>
     */
    public WrittenGenomicRun read(
        String sampleName, String platform, String referenceUri,
        AcquisitionMode acquisitionMode
    ) throws IOException {
        return read(sampleName, platform, referenceUri, acquisitionMode,
            ProgressSink.discard());
    }

    /** Convenience overload mirroring {@link #read(String)} that accepts
     *  a {@link ProgressSink}. */
    public WrittenGenomicRun read(String sampleName, ProgressSink progress)
            throws IOException {
        return read(sampleName, "", "", AcquisitionMode.GENOMIC_WGS, progress);
    }

    /**
     * Parse the file and return an unaligned {@link WrittenGenomicRun},
     * firing {@code progress.onProgress(readsDone, -1L)} every
     * {@link #PROGRESS_INTERVAL_READS} records during the parse phase
     * and a final {@code onProgress(total, total)} once the record
     * count is known.
     *
     * <p>Total is reported as {@code -1L} mid-parse because FASTQ
     * gives no record-count up front; the final fire stamps both
     * {@code done} and {@code total} with the true count so listeners
     * can switch from indeterminate to determinate display.</p>
     *
     * @since 1.5.0
     */
    public WrittenGenomicRun read(
        String sampleName, String platform, String referenceUri,
        AcquisitionMode acquisitionMode, ProgressSink progress
    ) throws IOException {
        if (progress == null) progress = ProgressSink.discard();
        // First pass: collect raw records.
        List<String> readNames = new ArrayList<>();
        List<byte[]> seqs = new ArrayList<>();
        List<byte[]> quals = new ArrayList<>();
        final ProgressSink sink = progress;
        final long[] counter = { 0L };
        try (InputStream in = FastaReader.openMaybeGzip(path)) {
            iterateRecords(in, (name, seq, qual) -> {
                readNames.add(name);
                seqs.add(seq);
                quals.add(qual);
                counter[0]++;
                if (counter[0] % PROGRESS_INTERVAL_READS == 0) {
                    sink.onProgress(counter[0], -1L);
                }
            });
        }
        if (readNames.isEmpty()) {
            throw new FastqParseException("no FASTQ records found in " + path);
        }
        // Final fire — total is now known.
        sink.onProgress(counter[0], counter[0]);

        int offset;
        if (forcedPhred != null) {
            offset = forcedPhred;
        } else {
            ByteArrayOutputStream concat = new ByteArrayOutputStream();
            for (byte[] q : quals) concat.write(q, 0, q.length);
            offset = detectPhredOffset(concat.toByteArray());
        }
        this.detectedPhred = offset;

        if (offset == 64) {
            for (int i = 0; i < quals.size(); i++) {
                byte[] q = quals.get(i);
                byte[] q33 = new byte[q.length];
                for (int j = 0; j < q.length; j++) {
                    q33[j] = (byte) ((q[j] & 0xFF) - 31);
                }
                quals.set(i, q33);
            }
        }

        // Build offsets/lengths and concat.
        List<Long> offsetsL = new ArrayList<>();
        List<Integer> lengthsL = new ArrayList<>();
        ByteArrayOutputStream seqBuf = new ByteArrayOutputStream();
        ByteArrayOutputStream qualBuf = new ByteArrayOutputStream();
        long running = 0L;
        for (int i = 0; i < readNames.size(); i++) {
            byte[] s = seqs.get(i);
            byte[] q = quals.get(i);
            offsetsL.add(running);
            lengthsL.add(s.length);
            seqBuf.write(s, 0, s.length);
            qualBuf.write(q, 0, q.length);
            running += s.length;
        }

        return FastaReader.buildUnalignedRun(
            readNames, seqBuf.toByteArray(), qualBuf.toByteArray(),
            offsetsL, lengthsL,
            sampleName, platform, referenceUri, acquisitionMode
        );
    }

    @FunctionalInterface
    private interface FastqRecordSink {
        void accept(String name, byte[] seq, byte[] qual);
    }

    /** Reads per streamed batch. */
    public static final int DEFAULT_BATCH_READS = 100_000;

    /** Batches of {@code batchReads} reads as unaligned
     *  {@link WrittenGenomicRun}s. The Phred offset is the forced one or
     *  detected on the first batch. The iterator implements
     *  {@link AutoCloseable} and closes the input at EOF. */
    public Iterator<WrittenGenomicRun> iterBatches(
            String sampleName, String platform, String referenceUri,
            AcquisitionMode acquisitionMode, int batchReads) throws IOException {
        return iterBatches(sampleName, platform, referenceUri, acquisitionMode, batchReads, 0L);
    }

    /** Decoded sequence + quality bytes per streamed batch by default
     *  (64 MiB). Bytes are the primary batch limit: a read count is
     *  blind to read length. */
    public static final long DEFAULT_BATCH_BYTES = 64L << 20;

    /** As above with an explicit byte limit; a batch cuts at whichever
     *  of {@code batchReads} / {@code batchBytes} is hit first
     *  (0 = the default for each). */
    public Iterator<WrittenGenomicRun> iterBatches(
            String sampleName, String platform, String referenceUri,
            AcquisitionMode acquisitionMode, int batchReads, long batchBytesIn) throws IOException {
        if (batchReads < 1) throw new IllegalArgumentException("batchReads must be >= 1");
        final long batchBytes = batchBytesIn > 0 ? batchBytesIn : DEFAULT_BATCH_BYTES;
        InputStream in = FastaReader.openMaybeGzip(path);
        BufferedReader br = new BufferedReader(new InputStreamReader(in, StandardCharsets.ISO_8859_1));
        return new Iterator<>() {
            final List<String> names = new ArrayList<>();
            final List<byte[]> seqs = new ArrayList<>();
            final List<byte[]> quals = new ArrayList<>();
            final int[] lineNo = {0};
            WrittenGenomicRun next;
            boolean done;

            @Override public boolean hasNext() {
                if (next != null) return true;
                if (done) return false;
                try {
                    long pendingBytes = 0L;
                    while (names.size() < batchReads && pendingBytes < batchBytes) {
                        String[] rec = readRecord(br, lineNo);
                        if (rec == null) break;
                        names.add(rec[0]);
                        byte[] sq = rec[1].getBytes(StandardCharsets.ISO_8859_1);
                        seqs.add(sq);
                        quals.add(rec[2].getBytes(StandardCharsets.ISO_8859_1));
                        pendingBytes += (long) sq.length * 2L;
                    }
                } catch (IOException e) {
                    throw new java.io.UncheckedIOException(e);
                }
                if (names.isEmpty()) {
                    finish();
                    return false;
                }
                next = batch();
                names.clear(); seqs.clear(); quals.clear();
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
                try { br.close(); } catch (IOException ignored) { }
                if (detectedPhred == null) detectedPhred = forcedPhred != null ? forcedPhred : 33;
            }

            private WrittenGenomicRun batch() {
                if (detectedPhred == null) {
                    if (forcedPhred != null) {
                        detectedPhred = forcedPhred;
                    } else {
                        ByteArrayOutputStream concat = new ByteArrayOutputStream();
                        for (byte[] q : quals) concat.write(q, 0, q.length);
                        detectedPhred = detectPhredOffset(concat.toByteArray());
                    }
                }
                List<Long> offsetsL = new ArrayList<>(names.size());
                List<Integer> lengthsL = new ArrayList<>(names.size());
                ByteArrayOutputStream seqBuf = new ByteArrayOutputStream();
                ByteArrayOutputStream qualBuf = new ByteArrayOutputStream();
                long running = 0L;
                for (int i = 0; i < names.size(); i++) {
                    byte[] s = seqs.get(i), q = quals.get(i);
                    if (detectedPhred == 64) {
                        byte[] q33 = new byte[q.length];
                        for (int j = 0; j < q.length; j++) q33[j] = (byte) ((q[j] & 0xFF) - 31);
                        q = q33;
                    }
                    offsetsL.add(running);
                    lengthsL.add(s.length);
                    seqBuf.write(s, 0, s.length);
                    qualBuf.write(q, 0, q.length);
                    running += s.length;
                }
                return FastaReader.buildUnalignedRun(new ArrayList<>(names), seqBuf.toByteArray(),
                    qualBuf.toByteArray(), offsetsL, lengthsL, sampleName, platform, referenceUri,
                    acquisitionMode);
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
        int streamThreads = global.thalion.ttio.Threads.resolve(null);
        if (streamThreads > 1) {
            return new GenomicStreamSource(name, () ->
                FastqParallelProducer.pipeline(path, sampleName, batchReads, batchBytes,
                                               streamThreads, null),
                null, false, null, null, false);
        }
        return new GenomicStreamSource(name, () -> {
            try {
                return iterBatches(sampleName, "", "", AcquisitionMode.GENOMIC_WGS, batchReads, batchBytes);
            } catch (IOException e) {
                throw new java.io.UncheckedIOException(e);
            }
        }, null, false, null, null, false);
    }

    /** Default batch of 100 000 reads. */
    public GenomicStreamSource stream(String name, String sampleName) {
        return stream(name, sampleName, DEFAULT_BATCH_READS);
    }

    /** One record as {@code {name, seq, qual}}, or {@code null} at EOF. */
    private static String[] readRecord(BufferedReader br, int[] lineNo) throws IOException {
        String hdr;
        do {
            hdr = br.readLine();
            if (hdr == null) return null;
            lineNo[0]++;
        } while (hdr.isEmpty());
        if (hdr.charAt(0) != '@') {
            throw new FastqParseException(
                "line " + lineNo[0] + ": expected '@<name>' header, got " + truncate(hdr, 60));
        }
        int i = 1;
        while (i < hdr.length() && (hdr.charAt(i) == ' ' || hdr.charAt(i) == '\t')) i++;
        int start = i;
        while (i < hdr.length() && hdr.charAt(i) != ' ' && hdr.charAt(i) != '\t') i++;
        String name = hdr.substring(start, i);
        String seqLine = br.readLine();
        lineNo[0]++;
        if (seqLine == null) {
            throw new FastqParseException("truncated record at line " + lineNo[0] + " (missing sequence)");
        }
        String plus = br.readLine();
        lineNo[0]++;
        if (plus == null || !plus.startsWith("+")) {
            throw new FastqParseException("line " + lineNo[0] + ": expected '+' separator, got "
                + (plus == null ? "<EOF>" : truncate(plus, 60)));
        }
        String qualLine = br.readLine();
        lineNo[0]++;
        if (qualLine == null) {
            throw new FastqParseException("truncated record at line " + lineNo[0] + " (missing qualities)");
        }
        if (seqLine.length() != qualLine.length()) {
            throw new FastqParseException("line " + lineNo[0] + ": SEQ/QUAL length mismatch ("
                + seqLine.length() + " vs " + qualLine.length() + ") for read '" + name + "'");
        }
        return new String[]{ name, seqLine, qualLine };
    }

    private static void iterateRecords(InputStream in, FastqRecordSink sink) throws IOException {
        BufferedReader br = new BufferedReader(
            new InputStreamReader(in, StandardCharsets.ISO_8859_1)
        );
        int[] lineNo = {0};
        while (true) {
            String[] rec = readRecord(br, lineNo);
            if (rec == null) return;
            sink.accept(rec[0], rec[1].getBytes(StandardCharsets.ISO_8859_1),
                rec[2].getBytes(StandardCharsets.ISO_8859_1));
        }
    }

    private static String truncate(String s, int max) {
        if (s.length() <= max) return "'" + s + "'";
        return "'" + s.substring(0, max) + "...'";
    }
}
