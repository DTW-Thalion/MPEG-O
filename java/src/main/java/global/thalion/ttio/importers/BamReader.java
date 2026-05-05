/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.importers;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.ProvenanceRecord;
import global.thalion.ttio.genomics.WrittenGenomicRun;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * SAM/BAM importer — M87.
 *
 * <p>Wraps the user-installed {@code samtools} binary as a subprocess to
 * read SAM and BAM (Sequence Alignment/Map) files into
 * {@link WrittenGenomicRun} instances. No htslib source is linked or
 * consulted; SAM/BAM format parsing is from the public SAMv1
 * specification (https://samtools.github.io/hts-specs).</p>
 *
 * <p>The subprocess approach mirrors the M53 Bruker timsTOF importer
 * pattern. {@code samtools} is a runtime dependency only — the
 * {@code BamReader} class is loadable on systems without samtools; only
 * {@link #toGenomicRun(String, String, String)} requires the binary on
 * PATH ().</p>
 *
 * <p>samtools auto-detects SAM vs BAM format from magic bytes; one
 * parser handles both. The companion {@link SamReader} exists as a
 * discoverable convenience alias.</p>
 *
 * <p><b>Cross-language equivalents:</b> Python {@code ttio.importers.bam.BamReader},
 * Objective-C {@code TTIOBamReader}.</p>
 *
 * (M87)
 */
public class BamReader {

    private static final String INSTALL_HELP =
        "samtools is required by global.thalion.ttio.importers.BamReader "
        + "but was not found on PATH. Install it via your platform's "
        + "package manager:\n"
        + "  Debian/Ubuntu: apt install samtools\n"
        + "  macOS:         brew install samtools\n"
        + "  Conda:         conda install -c bioconda samtools\n"
        + "Then re-run.";

    /** Raised at first use when samtools is missing or unusable. */
    public static final class SamtoolsNotFoundException extends IOException {
        private static final long serialVersionUID = 1L;
        public SamtoolsNotFoundException(String msg) { super(msg); }
        public SamtoolsNotFoundException(String msg, Throwable cause) {
            super(msg, cause);
        }
    }

    private final Path path;
    private List<ProvenanceRecord> lastProvenance = List.of();

    public BamReader(Path path) {
        this.path = path;
    }

    /** @return the path passed at construction time. */
    public Path path() { return path; }

    /**
     * @return the {@code @PG}-derived provenance records from the most
     *         recent {@link #toGenomicRun} call (empty before any call).
     *         {@link WrittenGenomicRun} does not carry provenance, so
     *         this side channel exposes it for the cross-language
     *         conformance dump and for callers that need it.
     */
    public List<ProvenanceRecord> lastProvenance() { return lastProvenance; }

    /** Default name {@code "genomic_0001"}, no region filter, no sample override. */
    public WrittenGenomicRun toGenomicRun(String name) throws IOException {
        return toGenomicRun(name, null, null);
    }

    /** No sample override. */
    public WrittenGenomicRun toGenomicRun(String name, String region)
            throws IOException {
        return toGenomicRun(name, region, null);
    }

    /**
     * Read the BAM/SAM and return a {@link WrittenGenomicRun}.
     *
     * @param name        run name (becomes {@code /study/genomic_runs/<name>}).
     * @param region      optional region filter passed verbatim to
     *                    {@code samtools view} ({@code "chr1:1000-2000"},
     *                    {@code "*"}, etc.).
     * @param sampleName  optional override for {@code sample_name};
     *                    {@code null} means "use first @RG SM:".
     * @throws SamtoolsNotFoundException if samtools is not on PATH at first call.
     * @throws IOException                if the file is missing, samtools
     *                                    exits non-zero, or a SAM line is malformed.
     */
    public WrittenGenomicRun toGenomicRun(String name, String region,
                                          String sampleName) throws IOException {
        checkSamtools();
        if (!Files.exists(path)) {
            throw new IOException("BAM/SAM file not found: " + path);
        }

        List<String> cmd = buildSamtoolsViewCommand(region);

        long fileMtime;
        try {
            fileMtime = Files.getLastModifiedTime(path).toInstant().getEpochSecond();
        } catch (IOException e) {
            fileMtime = System.currentTimeMillis() / 1000L;
        }

        ProcessBuilder pb = new ProcessBuilder(cmd);
        Process proc = pb.start();

        // Header state
        List<String> sqNames = new ArrayList<>();
        String rgSample = "";
        String rgPlatform = "";
        List<ProvenanceRecord> provenance = new ArrayList<>();

        // Per-read accumulators
        List<String> readNames = new ArrayList<>();
        List<String> chromosomes = new ArrayList<>();
        List<Long> positionsL = new ArrayList<>();
        List<Integer> mappingQualitiesL = new ArrayList<>();
        List<Integer> flagsL = new ArrayList<>();
        List<String> cigars = new ArrayList<>();
        List<String> mateChromosomes = new ArrayList<>();
        List<Long> matePositionsL = new ArrayList<>();
        List<Integer> templateLengthsL = new ArrayList<>();
        List<Long> offsetsL = new ArrayList<>();
        List<Integer> lengthsL = new ArrayList<>();
        List<byte[]> seqChunks = new ArrayList<>();
        List<byte[]> qualChunks = new ArrayList<>();
        long runningOffset = 0L;

        try (BufferedReader br = new BufferedReader(
                new InputStreamReader(proc.getInputStream(),
                                      StandardCharsets.ISO_8859_1))) {
            String line;
            int lineNo = 0;
            while ((line = br.readLine()) != null) {
                lineNo++;
                if (line.isEmpty()) continue;
                if (line.charAt(0) == '@') {
                    if (line.startsWith("@SQ")) {
                        Map<String, String> fields = parseHeaderFields(line);
                        String sn = fields.get("SN");
                        if (sn != null && !sn.isEmpty()) {
                            sqNames.add(sn);
                        }
                    } else if (line.startsWith("@RG")) {
                        Map<String, String> fields = parseHeaderFields(line);
                        String sm = fields.getOrDefault("SM", "");
                        String pl = fields.getOrDefault("PL", "");
                        if (rgSample.isEmpty() && !sm.isEmpty()) rgSample = sm;
                        if (rgPlatform.isEmpty() && !pl.isEmpty()) rgPlatform = pl;
                    } else if (line.startsWith("@PG")) {
                        Map<String, String> fields = parseHeaderFields(line);
                        String program = fields.getOrDefault("PN", "");
                        Map<String, String> params = new LinkedHashMap<>();
                        String cl = fields.get("CL");
                        if (cl != null) params.put("CL", cl);
                        for (String k : new String[]{"ID", "VN", "PP"}) {
                            if (fields.containsKey(k)) {
                                params.put(k, fields.get(k));
                            }
                        }
                        provenance.add(new ProvenanceRecord(
                            fileMtime, program, params,
                            List.of(), List.of()));
                    }
                    continue;
                }

                // Alignment record. Parse columns 1-11 only (Gotcha §152).
                String[] cols = line.split("\t", 12);
                if (cols.length < 11) {
                    throw new IOException(
                        "Malformed SAM alignment at line " + lineNo
                        + ": expected >=11 tab-separated fields, got "
                        + cols.length + " — "
                        + line.substring(0, Math.min(120, line.length())));
                }
                String qname  = cols[0];
                String flagS  = cols[1];
                String rname  = cols[2];
                String posS   = cols[3];
                String mapqS  = cols[4];
                String cigar  = cols[5];
                String rnext  = cols[6];
                String pnextS = cols[7];
                String tlenS  = cols[8];
                String seq    = cols[9];
                String qual   = cols[10];

                int flag, mapq;
                long pos, pnext;
                int tlen;
                try {
                    flag  = Integer.parseInt(flagS);
                    pos   = Long.parseLong(posS);
                    mapq  = Integer.parseInt(mapqS);
                    pnext = Long.parseLong(pnextS);
                    tlen  = Integer.parseInt(tlenS);
                } catch (NumberFormatException e) {
                    throw new IOException(
                        "Malformed SAM numeric field at line " + lineNo
                        + ": " + e.getMessage() + " — "
                        + line.substring(0, Math.min(120, line.length())), e);
                }

                // RNEXT '=' expansion ().
                if ("=".equals(rnext)) rnext = rname;

                readNames.add(qname);
                flagsL.add(flag);
                chromosomes.add(rname);
                positionsL.add(pos);
                mappingQualitiesL.add(mapq);
                cigars.add(cigar);
                mateChromosomes.add(rnext);
                matePositionsL.add(pnext);
                templateLengthsL.add(tlen);

                // SEQ / QUAL handling — Python parity.
                byte[] seqBytes;
                if ("*".equals(seq)) {
                    seqBytes = new byte[0];
                } else {
                    seqBytes = seq.getBytes(StandardCharsets.US_ASCII);
                }
                byte[] qualBytes;
                if ("*".equals(qual)) {
                    if ("*".equals(seq)) {
                        qualBytes = new byte[0];
                    } else {
                        qualBytes = new byte[seqBytes.length];
                        java.util.Arrays.fill(qualBytes, (byte) 0xFF);
                    }
                } else {
                    qualBytes = qual.getBytes(StandardCharsets.US_ASCII);
                }

                if (qualBytes.length != seqBytes.length) {
                    if ("*".equals(seq)) {
                        qualBytes = new byte[0];
                    } else if (!"*".equals(qual)) {
                        throw new IOException(
                            "SEQ/QUAL length mismatch at line " + lineNo
                            + ": SEQ=" + seqBytes.length
                            + " QUAL=" + qualBytes.length);
                    }
                }

                int length = seqBytes.length;
                offsetsL.add(runningOffset);
                lengthsL.add(length);
                seqChunks.add(seqBytes);
                qualChunks.add(qualBytes);
                runningOffset += length;
            }
        } catch (IOException e) {
            String stderrText = readStderrSafely(proc);
            try { proc.waitFor(); } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
            }
            throw new IOException(e.getMessage()
                + (stderrText.isEmpty() ? "" : " (stderr: " + stderrText + ")"), e);
        }

        int exitCode;
        try {
            exitCode = proc.waitFor();
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
            proc.destroy();
            throw new IOException("interrupted while waiting for samtools", ie);
        }
        if (exitCode != 0) {
            String stderrText = readStderrSafely(proc);
            throw new IOException("samtools view exited " + exitCode
                + " for " + path + ": " + stderrText.trim());
        }

        // sample_name override ().
        String effectiveSample = sampleName != null ? sampleName : rgSample;

        // reference_uri: first @SQ wins
        String referenceUri = sqNames.isEmpty() ? "" : sqNames.get(0);

        int n = readNames.size();
        long[] positions = new long[n];
        byte[] mappingQualities = new byte[n];
        int[] flags = new int[n];
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        long[] matePositions = new long[n];
        int[] templateLengths = new int[n];
        int totalSeqBytes = 0;
        int totalQualBytes = 0;
        for (int i = 0; i < n; i++) {
            positions[i]        = positionsL.get(i);
            mappingQualities[i] = (byte) (mappingQualitiesL.get(i) & 0xFF);
            flags[i]            = flagsL.get(i);
            offsets[i]          = offsetsL.get(i);
            lengths[i]          = lengthsL.get(i);
            matePositions[i]    = matePositionsL.get(i);
            templateLengths[i]  = templateLengthsL.get(i);
            totalSeqBytes      += seqChunks.get(i).length;
            totalQualBytes     += qualChunks.get(i).length;
        }

        byte[] sequences = new byte[totalSeqBytes];
        byte[] qualities = new byte[totalQualBytes];
        int seqOff = 0, qualOff = 0;
        for (int i = 0; i < n; i++) {
            byte[] s = seqChunks.get(i);
            byte[] q = qualChunks.get(i);
            System.arraycopy(s, 0, sequences, seqOff, s.length);
            seqOff += s.length;
            System.arraycopy(q, 0, qualities, qualOff, q.length);
            qualOff += q.length;
        }

        this.lastProvenance = List.copyOf(provenance);

        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS,
            referenceUri,
            rgPlatform,
            effectiveSample,
            positions,
            mappingQualities,
            flags,
            sequences,
            qualities,
            offsets,
            lengths,
            cigars,
            readNames,
            mateChromosomes,
            matePositions,
            templateLengths,
            chromosomes,
            Compression.ZLIB
        );
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    /**
     * Build the {@code samtools view -h ...} command for this reader.
     *
     * <p>Subclasses ({@code CramReader} in M88) override to inject
     * {@code --reference <fasta>} so reference-compressed CRAM bytes
     * can be reconstituted. Default implementation emits the bare
     * BAM/SAM read invocation with an optional region filter.</p>
     *
     * @param region optional region filter passed verbatim to
     *               {@code samtools view} ({@code "chr1:1000-2000"},
     *               {@code "*"}, etc.); {@code null} means no filter.
     * @return mutable list of command tokens (caller may further
     *         mutate before {@link ProcessBuilder} invocation).
     */
    protected List<String> buildSamtoolsViewCommand(String region) {
        List<String> cmd = new ArrayList<>();
        cmd.add("samtools");
        cmd.add("view");
        cmd.add("-h");
        cmd.add(path.toAbsolutePath().toString());
        if (region != null) {
            cmd.add(region);
        }
        return cmd;
    }

    private static Map<String, String> parseHeaderFields(String line) {
        Map<String, String> fields = new LinkedHashMap<>();
        String[] tokens = line.split("\t");
        for (int i = 1; i < tokens.length; i++) {
            String token = tokens[i];
            int colon = token.indexOf(':');
            if (colon < 0) continue;
            fields.put(token.substring(0, colon), token.substring(colon + 1));
        }
        return fields;
    }

    private static String readStderrSafely(Process proc) {
        try {
            byte[] data = proc.getErrorStream().readAllBytes();
            return new String(data, StandardCharsets.UTF_8);
        } catch (IOException e) {
            return "";
        }
    }

    /**
     * First-call samtools availability probe ().
     *
     * <p>We deliberately do NOT memoise a "missing" result: if samtools
     * was missing on a previous call but later installed, the next
     * call should succeed. We only memoise the positive case.</p>
     */
    private static volatile boolean samtoolsConfirmedPresent = false;

    private static void checkSamtools() throws SamtoolsNotFoundException {
        if (samtoolsConfirmedPresent) return;
        try {
            ProcessBuilder pb = new ProcessBuilder("samtools", "--version");
            pb.redirectErrorStream(true);
            Process proc = pb.start();
            try (var in = proc.getInputStream()) {
                in.readAllBytes();
            }
            int exit;
            try {
                exit = proc.waitFor();
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
                throw new SamtoolsNotFoundException(
                    INSTALL_HELP + "\n(interrupted while invoking samtools --version)");
            }
            if (exit != 0) {
                throw new SamtoolsNotFoundException(
                    INSTALL_HELP + "\n(samtools --version exited " + exit + ")");
            }
            samtoolsConfirmedPresent = true;
        } catch (IOException e) {
            if (e instanceof SamtoolsNotFoundException) throw (SamtoolsNotFoundException) e;
            throw new SamtoolsNotFoundException(
                INSTALL_HELP + "\n(invocation failed: " + e.getMessage() + ")", e);
        }
    }

    /**
     * Public probe used by tests' {@code Assumptions.assumeTrue(...)}
     * skip-when-missing pattern. Does not throw; returns {@code false}
     * if samtools is not callable for any reason.
     */
    public static boolean isSamtoolsAvailable() {
        try {
            checkSamtools();
            return true;
        } catch (IOException e) {
            return false;
        }
    }
}
