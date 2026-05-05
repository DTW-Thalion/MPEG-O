/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.exporters;

import global.thalion.ttio.ProvenanceRecord;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.importers.BamReader;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Objects;
import java.util.Set;

/**
 * BAM exporter — M88.
 *
 * <p>Writes a {@link WrittenGenomicRun} to BAM by formatting the in-
 * memory parallel-array representation as SAM text and piping that
 * text via stdin to the user-installed {@code samtools} binary
 * ({@code samtools view -bS -}, optionally piped through
 * {@code samtools sort -O bam}). Subprocess-only — no htslib
 * linkage; SAM line layout follows the public SAMv1 specification.</p>
 *
 * <h2>Quality byte encoding</h2>
 * <p>M87's {@link BamReader} stores SAM's QUAL field bytes verbatim
 * into {@link WrittenGenomicRun#qualities()} — i.e. the buffer holds
 * <b>ASCII Phred+33</b> characters (so a Phred-40 score is stored as
 * the byte value 73, the ASCII code for {@code 'I'}). This writer
 * mirrors that convention: each {@code qualities[i]} byte is written
 * directly as the SAM QUAL character with no arithmetic adjustment.
 * The pair is therefore lossless byte-for-byte across the M87 read /
 * M88 write round trip.</p>
 *
 * <p>Cross-language note: the Python and Objective-C implementations
 * adopt the same convention so cross-language conformance dumps
 * match.</p>
 *
 * <p><b>Cross-language equivalents:</b> Python
 * {@code ttio.exporters.bam.BamWriter},
 * Objective-C {@code TTIOBamWriter}.</p>
 *
 * (M88)
 */
public class BamWriter {

    /**
     * Default {@code @SQ LN:} length when the writer doesn't know the
     * true reference length. SAM requires {@code LN:} on every
     * {@code @SQ}; we pick INT32_MAX so the emitted header is valid
     * for any plausible coordinate. Matches the Python reference's
     * {@code _DEFAULT_SQ_LENGTH} and the ObjC writer's constant for
     * cross-language byte-equality on the unsorted code path.
     */
    protected static final long DEFAULT_SQ_LENGTH = 2147483647L;

    /** Subprocess timeout for samtools invocations (seconds). */
    private static final int SAMTOOLS_TIMEOUT_SECONDS = 120;

    private final Path path;

    /**
     * Construct a {@code BamWriter}.
     *
     * @param path output BAM file path. The {@code .bam} extension is
     *             honoured by samtools' file-format auto-detection
     *             (HANDOFF Gotcha §165).
     */
    public BamWriter(Path path) {
        this.path = Objects.requireNonNull(path);
    }

    /** @return the output path passed at construction time. */
    public Path path() { return path; }

    // ------------------------------------------------------------------
    // Public API
    // ------------------------------------------------------------------

    /**
     * Serialise {@code run} to the configured output path.
     *
     * @param run        the genomic-run container to write.
     * @param provenance optional provenance records to inject as
     *                   {@code @PG} header lines. Pass an empty list
     *                   for none; the M87/M88 cross-language
     *                   convention is "writer accepts provenance
     *                   explicitly because the Java/ObjC
     *                   {@code WrittenGenomicRun} analogues don't
     *                   carry it".
     * @param sort       when {@code true} (
     *                   default), pipe the SAM text through
     *                   {@code samtools sort -O bam} so the output
     *                   BAM is coordinate-sorted (precondition most
     *                   downstream tools expect — IGV, GATK,
     *                   {@code samtools index}). When {@code false},
     *                   output is written in input read order and
     *                   {@code @HD SO:} is set to {@code unsorted}.
     * @throws IOException if samtools is missing, exits non-zero, or
     *                     a piping I/O error occurs.
     */
    public void write(WrittenGenomicRun run, List<ProvenanceRecord> provenance,
                      boolean sort) throws IOException {
        Objects.requireNonNull(run, "run");
        if (provenance == null) provenance = List.of();
        // First-use samtools probe (via BamReader's static).
        if (!BamReader.isSamtoolsAvailable()) {
            throw new BamReader.SamtoolsNotFoundException(
                "samtools is required by global.thalion.ttio.exporters.BamWriter "
                + "but was not found on PATH. Install via apt/brew/conda then re-run.");
        }
        String samText = buildSamText(run, provenance, sort);
        invokeSamtools(samText, sort);
    }

    // ------------------------------------------------------------------
    // SAM text assembly
    // ------------------------------------------------------------------

    /**
     * Build the full SAM text (header + alignment lines) for
     * {@code run}. Exposed at package-private visibility for
     * {@link CramWriter} reuse and for the
     * {@code test_mate_collapse_to_equals} harness which inspects
     * the pre-samtools SAM stream directly.
     */
    String buildSamText(WrittenGenomicRun run,
                        List<ProvenanceRecord> provenance, boolean sort) {
        StringBuilder sb = new StringBuilder();
        appendHeader(sb, run, provenance, sort);
        appendAlignments(sb, run);
        return sb.toString();
    }

    private static void appendHeader(StringBuilder sb,
                                     WrittenGenomicRun run,
                                     List<ProvenanceRecord> provenance,
                                     boolean sort) {
        String so = sort ? "coordinate" : "unsorted";
        sb.append("@HD\tVN:1.6\tSO:").append(so).append('\n');

        // @SQ — one per unique chromosome (excluding "*" SAM unmapped
        // sentinel). First-seen order so writer output is
        // deterministic.
        Set<String> seen = new HashSet<>();
        for (String chrom : run.chromosomes()) {
            if (chrom == null || chrom.isEmpty() || "*".equals(chrom)) continue;
            if (!seen.add(chrom)) continue;
            sb.append("@SQ\tSN:").append(chrom)
              .append("\tLN:").append(DEFAULT_SQ_LENGTH).append('\n');
        }

        // @RG — single line if either sample_name or platform is set.
        String sample = run.sampleName();
        String platform = run.platform();
        boolean hasSample = sample != null && !sample.isEmpty();
        boolean hasPlatform = platform != null && !platform.isEmpty();
        if (hasSample || hasPlatform) {
            sb.append("@RG\tID:rg1");
            if (hasSample) sb.append("\tSM:").append(sample);
            if (hasPlatform) sb.append("\tPL:").append(platform);
            sb.append('\n');
        }

        // @PG — one line per provenance record. SAM requires ID;
        // synthesise "pg<idx>" if the software field is blank, and
        // suffix duplicates with .1/.2/...
        Set<String> usedIds = new HashSet<>();
        for (int idx = 0; idx < provenance.size(); idx++) {
            ProvenanceRecord prov = provenance.get(idx);
            String software = prov.software();
            String baseId = (software == null || software.isEmpty())
                ? ("pg" + idx) : software;
            String pgId = baseId;
            int n = 1;
            while (usedIds.contains(pgId)) {
                pgId = baseId + "." + n;
                n++;
            }
            usedIds.add(pgId);
            sb.append("@PG\tID:").append(pgId);
            sb.append("\tPN:").append(software == null ? "" : software);
            String cl = prov.parameters() != null
                ? prov.parameters().get("CL") : null;
            if (cl != null && !cl.isEmpty()) {
                sb.append("\tCL:").append(cl);
            }
            sb.append('\n');
        }
    }

    private static void appendAlignments(StringBuilder sb,
                                         WrittenGenomicRun run) {
        byte[] seqBuf = run.sequences();
        byte[] qualBuf = run.qualities();
        List<String> readNames = run.readNames();
        List<String> chromosomes = run.chromosomes();
        List<String> mateChromosomes = run.mateChromosomes();
        List<String> cigars = run.cigars();
        long[] positions = run.positions();
        long[] matePositions = run.matePositions();
        long[] offsets = run.offsets();
        int[] lengths = run.lengths();
        int[] flags = run.flags();
        int[] templateLengths = run.templateLengths();
        byte[] mappingQualities = run.mappingQualities();

        int n = readNames.size();
        for (int i = 0; i < n; i++) {
            String qnameRaw = readNames.get(i);
            String qname = (qnameRaw == null || qnameRaw.isEmpty()) ? "*" : qnameRaw;
            int flag = flags[i];
            String rnameRaw = chromosomes.get(i);
            String rname = (rnameRaw == null || rnameRaw.isEmpty()) ? "*" : rnameRaw;
            long pos = positions[i];
            int mapq = mappingQualities[i] & 0xFF;
            String cigarRaw = cigars.get(i);
            String cigar = (cigarRaw == null || cigarRaw.isEmpty()) ? "*" : cigarRaw;

            // RNEXT collapse (§136): only when mate matches and
            // chromosome is not "*".
            String mateChromRaw = mateChromosomes.get(i);
            String mateChrom = (mateChromRaw == null || mateChromRaw.isEmpty())
                ? "*" : mateChromRaw;
            String rnext;
            if (mateChrom.equals(rname) && !"*".equals(rname)) {
                rnext = "=";
            } else {
                rnext = mateChrom;
            }

            // PNEXT mapping (§138).
            long matePos = matePositions[i];
            long pnext = matePos < 0 ? 0L : matePos;

            int tlen = templateLengths[i];
            long offset = offsets[i];
            int length = lengths[i];

            String seq;
            String qual;
            if (length == 0) {
                seq = "*";
                qual = "*";
            } else {
                int from = (int) offset;
                int to = from + length;
                seq = new String(seqBuf, from, length, StandardCharsets.US_ASCII);
                // M87 reader produces an all-0xFF buffer when the
                // source SAM had QUAL '*' but a non-empty SEQ — map
                // back to '*' on write so the round trip
                // canonicalises to the source convention.
                boolean allFF = true;
                for (int k = from; k < to; k++) {
                    if ((qualBuf[k] & 0xFF) != 0xFF) { allFF = false; break; }
                }
                if (allFF) {
                    qual = "*";
                } else {
                    // qualities stored as ASCII Phred+33 already; use
                    // ISO_8859_1 so any value > 127 round-trips
                    // (samtools rejects QUAL > '~' = 0x7e but the
                    // pass-through stays lossless).
                    qual = new String(qualBuf, from, length,
                        StandardCharsets.ISO_8859_1);
                }
            }

            sb.append(qname).append('\t')
              .append(flag).append('\t')
              .append(rname).append('\t')
              .append(pos).append('\t')
              .append(mapq).append('\t')
              .append(cigar).append('\t')
              .append(rnext).append('\t')
              .append(pnext).append('\t')
              .append(tlen).append('\t')
              .append(seq).append('\t')
              .append(qual).append('\n');
        }
    }

    // ------------------------------------------------------------------
    // samtools subprocess invocation
    // ------------------------------------------------------------------

    /**
     * Pipe {@code samText} through samtools to produce the output
     * file. Subclasses ({@link CramWriter}) override
     * {@link #buildViewCommand(boolean)} and
     * {@link #buildSortCommand(boolean)} to inject reference and
     * format flags.
     */
    void invokeSamtools(String samText, boolean sort) throws IOException {
        List<String> viewCmd = buildViewCommand(sort);
        List<String> sortCmd = buildSortCommand(sort);
        if (sortCmd == null) {
            runPipeline(List.of(viewCmd), samText);
        } else {
            runPipeline(List.of(viewCmd, sortCmd), samText);
        }
    }

    /**
     * Build the {@code samtools view} stage of the pipeline. When
     * {@code sort} is {@code true}, the view stage emits to stdout
     * (the sort stage consumes from stdin); when {@code false},
     * the view stage writes directly to {@link #path}.
     *
     * <p>Subclasses override to swap in CRAM flags.</p>
     */
    protected List<String> buildViewCommand(boolean sort) {
        List<String> cmd = new ArrayList<>();
        cmd.add("samtools");
        cmd.add("view");
        cmd.add("-bS");
        if (!sort) {
            cmd.add("-o");
            cmd.add(path.toAbsolutePath().toString());
        }
        cmd.add("-");
        return cmd;
    }

    /**
     * Build the {@code samtools sort} stage of the pipeline, or
     * {@code null} for the unsorted single-stage path.
     */
    protected List<String> buildSortCommand(boolean sort) {
        if (!sort) return null;
        List<String> cmd = new ArrayList<>();
        cmd.add("samtools");
        cmd.add("sort");
        cmd.add("-O");
        cmd.add("bam");
        cmd.add("-o");
        cmd.add(path.toAbsolutePath().toString());
        cmd.add("-");
        return cmd;
    }

    private static void runPipeline(List<List<String>> commands,
                                    String stdinText) throws IOException {
        byte[] payload = stdinText.getBytes(StandardCharsets.US_ASCII);
        if (commands.size() == 1) {
            ProcessBuilder pb = new ProcessBuilder(commands.get(0));
            pb.redirectErrorStream(false);
            Process proc = pb.start();
            try (OutputStream stdin = proc.getOutputStream()) {
                stdin.write(payload);
            }
            proc.getInputStream().readAllBytes();
            byte[] errBytes = proc.getErrorStream().readAllBytes();
            int exit;
            try {
                exit = proc.waitFor();
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
                proc.destroy();
                throw new IOException("interrupted while waiting for samtools", ie);
            }
            if (exit != 0) {
                throw new IOException("samtools (" + commands.get(0)
                    + ") exited " + exit + ": "
                    + new String(errBytes, StandardCharsets.UTF_8).trim());
            }
            return;
        }

        // Two-stage pipeline: stage[0].stdout -> stage[1].stdin.
        ProcessBuilder pb1 = new ProcessBuilder(commands.get(0));
        ProcessBuilder pb2 = new ProcessBuilder(commands.get(1));
        Process first = pb1.start();
        Process second = pb2.start();

        // Pump stage 1 stdout to stage 2 stdin in a background thread
        // so the two processes can run concurrently. Closing the first
        // process's input stream signals EOF to the sort stage's
        // stdin once view is done.
        Thread pump = new Thread(() -> {
            try (OutputStream secondIn = second.getOutputStream()) {
                first.getInputStream().transferTo(secondIn);
            } catch (IOException ignored) {
                // Best-effort; failures show up as non-zero exit.
            }
        }, "BamWriter-pipe-pump");
        pump.setDaemon(true);
        pump.start();

        try (OutputStream stdin = first.getOutputStream()) {
            stdin.write(payload);
        }

        // Drain stderr to avoid deadlock on platforms with small pipe
        // buffers.
        byte[] firstErr;
        byte[] secondErr;
        try {
            firstErr = first.getErrorStream().readAllBytes();
            // Discard stage-2 stdout (it goes to a file via -o); stderr
            // we collect.
            second.getInputStream().readAllBytes();
            secondErr = second.getErrorStream().readAllBytes();
        } catch (IOException e) {
            first.destroy();
            second.destroy();
            throw e;
        }

        int firstExit, secondExit;
        try {
            firstExit = first.waitFor();
            pump.join(SAMTOOLS_TIMEOUT_SECONDS * 1000L);
            secondExit = second.waitFor();
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
            first.destroy();
            second.destroy();
            throw new IOException("interrupted while waiting for samtools", ie);
        }
        if (firstExit != 0) {
            throw new IOException("samtools (stage 1, " + commands.get(0)
                + ") exited " + firstExit + ": "
                + new String(firstErr, StandardCharsets.UTF_8).trim());
        }
        if (secondExit != 0) {
            throw new IOException("samtools (stage 2, " + commands.get(1)
                + ") exited " + secondExit + ": "
                + new String(secondErr, StandardCharsets.UTF_8).trim());
        }
    }
}
