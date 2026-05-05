/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.importers;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.genomics.WrittenGenomicRun;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
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
        return read(sampleName, "", "", AcquisitionMode.GENOMIC_WGS);
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
        // First pass: collect raw records.
        List<String> readNames = new ArrayList<>();
        List<byte[]> seqs = new ArrayList<>();
        List<byte[]> quals = new ArrayList<>();
        try (InputStream in = FastaReader.openMaybeGzip(path)) {
            iterateRecords(in, (name, seq, qual) -> {
                readNames.add(name);
                seqs.add(seq);
                quals.add(qual);
            });
        }
        if (readNames.isEmpty()) {
            throw new FastqParseException("no FASTQ records found in " + path);
        }

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

    private static void iterateRecords(InputStream in, FastqRecordSink sink) throws IOException {
        BufferedReader br = new BufferedReader(
            new InputStreamReader(in, StandardCharsets.ISO_8859_1)
        );
        int lineNo = 0;
        while (true) {
            String hdr = br.readLine();
            if (hdr == null) return;
            lineNo++;
            if (hdr.isEmpty()) continue;
            if (hdr.charAt(0) != '@') {
                throw new FastqParseException(
                    "line " + lineNo + ": expected '@<name>' header, got "
                        + truncate(hdr, 60)
                );
            }
            // Name = first whitespace-delimited token after '@'.
            int i = 1;
            while (i < hdr.length() && (hdr.charAt(i) == ' ' || hdr.charAt(i) == '\t')) i++;
            int start = i;
            while (i < hdr.length() && hdr.charAt(i) != ' ' && hdr.charAt(i) != '\t') i++;
            String name = hdr.substring(start, i);

            String seqLine = br.readLine();
            lineNo++;
            if (seqLine == null) {
                throw new FastqParseException(
                    "truncated record at line " + lineNo + " (missing sequence)"
                );
            }
            String plus = br.readLine();
            lineNo++;
            if (plus == null || !plus.startsWith("+")) {
                throw new FastqParseException(
                    "line " + lineNo + ": expected '+' separator, got "
                        + (plus == null ? "<EOF>" : truncate(plus, 60))
                );
            }
            String qualLine = br.readLine();
            lineNo++;
            if (qualLine == null) {
                throw new FastqParseException(
                    "truncated record at line " + lineNo + " (missing qualities)"
                );
            }
            byte[] seq = seqLine.getBytes(StandardCharsets.ISO_8859_1);
            byte[] qual = qualLine.getBytes(StandardCharsets.ISO_8859_1);
            if (seq.length != qual.length) {
                throw new FastqParseException(
                    "line " + lineNo + ": SEQ/QUAL length mismatch ("
                        + seq.length + " vs " + qual.length + ") for read '"
                        + name + "'"
                );
            }
            sink.accept(name, seq, qual);
        }
    }

    private static String truncate(String s, int max) {
        if (s.length() <= max) return "'" + s + "'";
        return "'" + s.substring(0, max) + "...'";
    }
}
