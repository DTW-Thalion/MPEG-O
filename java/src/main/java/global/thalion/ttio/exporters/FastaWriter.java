/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.exporters;

import global.thalion.ttio.genomics.ReferenceImport;
import global.thalion.ttio.genomics.WrittenGenomicRun;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.zip.GZIPOutputStream;

/**
 * FASTA exporter.
 *
 * <p>Writes a {@link ReferenceImport} or a {@link WrittenGenomicRun}
 * to a FASTA file with optional gzip and a samtools-compatible
 * {@code .fai} index.</p>
 *
 * <p><b>Cross-language byte-equality:</b> for uncompressed output,
 * three guarantees hold across Python, ObjC, and Java: header is
 * {@code ">name\n"}, sequence is wrapped at {@code lineWidth} bytes
 * verbatim case, line endings are LF only.</p>
 *
 * <p><b>Cross-language equivalents:</b> Python
 * {@code ttio.exporters.fasta.FastaWriter}, Objective-C
 * {@code TTIOFastaWriter}.</p>
 */
public final class FastaWriter {

    public static final int DEFAULT_LINE_WIDTH = 60;

    private FastaWriter() {}

    /**
     * Write a reference import to a FASTA file.
     *
     * @param reference   source reference
     * @param path        destination path; {@code .gz} extension auto-
     *                    enables gzip when {@code gzipOutput} is null.
     * @param lineWidth   sequence wrap width in bytes (>= 1).
     * @param gzipOutput  force gzip on/off; null = derive from extension.
     * @param writeFai    when true (default), emit a samtools-style
     *                    {@code <path>.fai} index; skipped silently for
     *                    gzip output.
     */
    public static void writeReference(
        ReferenceImport reference, Path path,
        int lineWidth, Boolean gzipOutput, boolean writeFai
    ) throws IOException {
        List<Record> records = new ArrayList<>();
        for (int i = 0; i < reference.chromosomes().size(); i++) {
            records.add(new Record(
                reference.chromosomes().get(i),
                reference.sequences().get(i)
            ));
        }
        writeRecords(records, path, lineWidth, gzipOutput, writeFai);
    }

    public static void writeReference(ReferenceImport reference, Path path) throws IOException {
        writeReference(reference, path, DEFAULT_LINE_WIDTH, null, true);
    }

    /**
     * Write a genomic run to a FASTA file.
     *
     * <p>Each read becomes one FASTA record; quality bytes are
     * discarded (use {@link FastqWriter} to preserve them).</p>
     */
    public static void writeRun(
        WrittenGenomicRun run, Path path,
        int lineWidth, Boolean gzipOutput, boolean writeFai
    ) throws IOException {
        List<Record> records = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        for (int i = 0; i < run.readNames().size(); i++) {
            int off = (int) run.offsets()[i];
            int len = run.lengths()[i];
            byte[] seq = new byte[len];
            System.arraycopy(run.sequences(), off, seq, 0, len);
            String name = run.readNames().get(i);
            if (seen.contains(name)) name = name + "#" + i;
            seen.add(name);
            records.add(new Record(name, seq));
        }
        writeRecords(records, path, lineWidth, gzipOutput, writeFai);
    }

    public static void writeRun(WrittenGenomicRun run, Path path) throws IOException {
        writeRun(run, path, DEFAULT_LINE_WIDTH, null, true);
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    private record Record(String name, byte[] seq) {}

    private static void writeRecords(
        List<Record> records, Path path,
        int lineWidth, Boolean gzipOutput, boolean writeFai
    ) throws IOException {
        if (lineWidth < 1) {
            throw new IllegalArgumentException(
                "lineWidth must be >= 1 (got " + lineWidth + ")"
            );
        }
        boolean gz = gzipOutput != null
            ? gzipOutput
            : path.getFileName().toString().toLowerCase().endsWith(".gz");

        ByteArrayOutputStream buf = new ByteArrayOutputStream();
        List<String> faiLines = new ArrayList<>();
        for (Record r : records) {
            String hdr = ">" + r.name() + "\n";
            buf.write(hdr.getBytes(StandardCharsets.UTF_8));
            int seqOffset = buf.size();
            int length = r.seq().length;
            int start = 0;
            while (start < length) {
                int end = Math.min(start + lineWidth, length);
                buf.write(r.seq(), start, end - start);
                buf.write('\n');
                start = end;
            }
            faiLines.add(
                r.name() + "\t" + length + "\t" + seqOffset
                    + "\t" + lineWidth + "\t" + (lineWidth + 1)
            );
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

        if (writeFai && !gz) {
            Path fai = path.resolveSibling(path.getFileName().toString() + ".fai");
            StringBuilder sb = new StringBuilder();
            for (String ln : faiLines) {
                sb.append(ln).append('\n');
            }
            Files.writeString(fai, sb.toString(), StandardCharsets.US_ASCII);
        }
    }
}
