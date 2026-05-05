/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.exporters;

import global.thalion.ttio.genomics.WrittenGenomicRun;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashSet;
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

    private FastqWriter() {}

    public static void write(WrittenGenomicRun run, Path path) throws IOException {
        write(run, path, null, 33);
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
        if (phredOffset != 33 && phredOffset != 64) {
            throw new IllegalArgumentException(
                "phredOffset must be 33 or 64 (got " + phredOffset + ")"
            );
        }
        boolean gz = gzipOutput != null
            ? gzipOutput
            : path.getFileName().toString().toLowerCase().endsWith(".gz");

        ByteArrayOutputStream buf = new ByteArrayOutputStream();
        Set<String> seen = new HashSet<>();
        for (int i = 0; i < run.readNames().size(); i++) {
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
    }
}
