/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.exporters;

import global.thalion.ttio.genomics.AlignedRead;
import global.thalion.ttio.genomics.GenomicRun;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.io.ProgressSink;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.zip.GZIPOutputStream;

/**
 * FASTQ exporter.
 *
 * <p>Writes a {@link WrittenGenomicRun} to a FASTQ file with optional
 * gzip. Each read becomes a 4-line record:</p>
 *
 * <pre>
 *   &#64;read_name
 *   SEQUENCE
 *   +
 *   QUALITIES
 * </pre>
 *
 * <p>Internal {@code 0xFF} "qualities unknown" sentinel bytes are
 * mapped to Phred 0 (ASCII {@code !}) on output so the result is
 * always a parseable FASTQ.</p>
 *
 * <p><b>Cross-language equivalents:</b> Python
 * {@code ttio.exporters.fastq.FastqWriter}, Objective-C
 * {@code TTIOFastqWriter}.</p>
 */
public final class FastqWriter {

    private static final int QUAL_UNKNOWN_BYTE = 0xFF;
    private static final byte PHRED33_FILL = (byte) '!';

    /** Stage D: emit-every-N cadence for {@link ProgressSink} callbacks
     *  during FASTQ record serialisation. Mirrors
     *  {@code FastqReader.PROGRESS_INTERVAL_READS = 1000}. */
    public static final int PROGRESS_INTERVAL_READS = 1000;

    private FastqWriter() {}

    public static void write(WrittenGenomicRun run, Path path) throws IOException {
        write(run, path, null, 33, ProgressSink.discard());
    }

    /**
     * @param run          source run
     * @param path         destination; {@code .gz} extension auto-
     *                     enables gzip when {@code gzipOutput} is null.
     * @param gzipOutput   force gzip on/off; null = derive from extension.
     * @param phredOffset  {@code 33} (default) or {@code 64}.
     */
    public static void write(
        WrittenGenomicRun run, Path path,
        Boolean gzipOutput, int phredOffset
    ) throws IOException {
        write(run, path, gzipOutput, phredOffset, ProgressSink.discard());
    }

    /**
     * Stage D overload of
     * {@link #write(WrittenGenomicRun, Path, Boolean, int)} that fires
     * {@code progress.onProgress(readsDone, totalReads)} every
     * {@link #PROGRESS_INTERVAL_READS} records and a final fire once
     * the buffer is flushed to disk.
     *
     * @since 1.5.0
     */
    public static void write(
        WrittenGenomicRun run, Path path,
        Boolean gzipOutput, int phredOffset, ProgressSink progress
    ) throws IOException {
        if (phredOffset != 33 && phredOffset != 64) {
            throw new IllegalArgumentException(
                "phredOffset must be 33 or 64 (got " + phredOffset + ")"
            );
        }
        if (progress == null) progress = ProgressSink.discard();
        boolean gz = gzipOutput != null
            ? gzipOutput
            : path.getFileName().toString().toLowerCase().endsWith(".gz");

        ByteArrayOutputStream buf = new ByteArrayOutputStream();
        Set<String> seen = new HashSet<>();
        int nRecs = run.readNames().size();
        long total = nRecs;
        for (int i = 0; i < nRecs; i++) {
            int off = (int) run.offsets()[i];
            int len = run.lengths()[i];
            byte[] seq = new byte[len];
            System.arraycopy(run.sequences(), off, seq, 0, len);
            byte[] qual;
            if (run.qualities().length >= off + len) {
                qual = new byte[len];
                System.arraycopy(run.qualities(), off, qual, 0, len);
            } else {
                qual = new byte[0];
            }
            // Map sentinel 0xFF -> Phred 0 ('!') in Phred+33 space.
            for (int j = 0; j < qual.length; j++) {
                if ((qual[j] & 0xFF) == QUAL_UNKNOWN_BYTE) {
                    qual[j] = PHRED33_FILL;
                }
            }
            // If qual is empty (SAM seq-absent case) but seq is not,
            // pad with Phred 0 to keep the record parseable.
            if (qual.length == 0 && seq.length > 0) {
                qual = new byte[seq.length];
                java.util.Arrays.fill(qual, PHRED33_FILL);
            }
            if (phredOffset == 64) {
                for (int j = 0; j < qual.length; j++) {
                    qual[j] = (byte) ((qual[j] & 0xFF) + 31);
                }
            }
            String name = run.readNames().get(i);
            if (seen.contains(name)) name = name + "#" + i;
            seen.add(name);
            buf.write('@');
            buf.write(name.getBytes(StandardCharsets.UTF_8));
            buf.write('\n');
            buf.write(seq);
            buf.write('\n');
            buf.write('+');
            buf.write('\n');
            buf.write(qual);
            buf.write('\n');
            long done = (long) (i + 1);
            if (done % PROGRESS_INTERVAL_READS == 0 && done < total) {
                progress.onProgress(done, total);
            }
        }
        byte[] body = buf.toByteArray();

        if (gz) {
            try (OutputStream out = new GZIPOutputStream(Files.newOutputStream(path))) {
                out.write(body);
            }
        } else {
            try (OutputStream out = Files.newOutputStream(path)) {
                out.write(body);
            }
        }
        progress.onProgress(total, total);
    }

    /**
     * Write a read-side {@link GenomicRun} to FASTQ.
     *
     * <p>Used by the FASTQ-from-{@code .tio} export path: open a
     * {@link global.thalion.ttio.SpectralDataset SpectralDataset}, pull
     * the {@link GenomicRun} out of
     * {@link global.thalion.ttio.SpectralDataset#genomicRuns()
     * genomicRuns()}, then re-serialise to FASTQ.</p>
     */
    public static void write(
        GenomicRun run, Path path,
        Boolean gzipOutput, int phredOffset
    ) throws IOException {
        write(run, path, gzipOutput, phredOffset, ProgressSink.discard());
    }

    /**
     * Stage D overload of
     * {@link #write(GenomicRun, Path, Boolean, int)} that fires
     * {@code progress.onProgress(readsDone, totalReads)} every
     * {@link #PROGRESS_INTERVAL_READS} records and a final fire once
     * the buffer is flushed to disk.
     *
     * @since 1.5.0
     */
    public static void write(
        GenomicRun run, Path path,
        Boolean gzipOutput, int phredOffset, ProgressSink progress
    ) throws IOException {
        if (phredOffset != 33 && phredOffset != 64) {
            throw new IllegalArgumentException(
                "phredOffset must be 33 or 64 (got " + phredOffset + ")"
            );
        }
        if (progress == null) progress = ProgressSink.discard();
        boolean gz = gzipOutput != null
            ? gzipOutput
            : path.getFileName().toString().toLowerCase().endsWith(".gz");

        // Pre-fetch the whole sequences + qualities byte arrays + the
        // read_names list once, then slice in-memory per record.
        // Skips the per-read AlignedRead materialisation (which would
        // also decode cigar / mate triple — fields FASTQ does not
        // need). Mirrors the 24× speedup the Python FastqWriter saw
        // from this same pattern.
        int n = run.readCount();
        long total = n;
        byte[] seqAll = n > 0 ? run.sequencesFull() : new byte[0];
        byte[] qualAll = n > 0 ? run.qualitiesFull() : new byte[0];
        List<String> namesAll = run.readNamesAll();

        ByteArrayOutputStream buf = new ByteArrayOutputStream();
        Set<String> seen = new HashSet<>();
        for (int i = 0; i < n; i++) {
            int off = (int) run.index().offsetAt(i);
            int len = run.index().lengthAt(i);
            byte[] seq = new byte[len];
            System.arraycopy(seqAll, off, seq, 0, len);
            byte[] qual;
            if (qualAll.length >= off + len) {
                qual = new byte[len];
                System.arraycopy(qualAll, off, qual, 0, len);
            } else {
                qual = new byte[0];
            }
            for (int j = 0; j < qual.length; j++) {
                if ((qual[j] & 0xFF) == QUAL_UNKNOWN_BYTE) {
                    qual[j] = PHRED33_FILL;
                }
            }
            if (qual.length == 0 && seq.length > 0) {
                qual = new byte[seq.length];
                java.util.Arrays.fill(qual, PHRED33_FILL);
            }
            if (phredOffset == 64) {
                for (int j = 0; j < qual.length; j++) {
                    qual[j] = (byte) ((qual[j] & 0xFF) + 31);
                }
            }
            String name = namesAll.get(i);
            if (seen.contains(name)) name = name + "#" + i;
            seen.add(name);
            buf.write('@');
            buf.write(name.getBytes(StandardCharsets.UTF_8));
            buf.write('\n');
            buf.write(seq);
            buf.write('\n');
            buf.write('+');
            buf.write('\n');
            buf.write(qual);
            buf.write('\n');
            long done = (long) (i + 1);
            if (done % PROGRESS_INTERVAL_READS == 0 && done < total) {
                progress.onProgress(done, total);
            }
        }
        byte[] body = buf.toByteArray();

        if (gz) {
            try (OutputStream out = new GZIPOutputStream(Files.newOutputStream(path))) {
                out.write(body);
            }
        } else {
            try (OutputStream out = Files.newOutputStream(path)) {
                out.write(body);
            }
        }
        progress.onProgress(total, total);
    }

    public static void write(GenomicRun run, Path path) throws IOException {
        write(run, path, null, 33, ProgressSink.discard());
    }
}
