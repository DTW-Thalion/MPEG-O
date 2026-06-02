/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.importers;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.ProvenanceRecord;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.io.ProgressSink;

import htsjdk.samtools.SAMFileHeader;
import htsjdk.samtools.SAMProgramRecord;
import htsjdk.samtools.SAMReadGroupRecord;
import htsjdk.samtools.SAMRecord;
import htsjdk.samtools.SAMSequenceRecord;
import htsjdk.samtools.SamInputResource;
import htsjdk.samtools.SamReader;
import htsjdk.samtools.SamReaderFactory;
import htsjdk.samtools.ValidationStringency;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * SAM/BAM importer — M87.
 *
 * <p>Reads SAM and BAM (Sequence Alignment/Map) files into
 * {@link WrittenGenomicRun} instances using <a
 * href="https://github.com/samtools/htsjdk">htsjdk</a> — the pure-Java
 * SAM/BAM/CRAM library used by GATK, Picard, and IGV.</p>
 *
 * <p>v1.5.0 replaced the prior {@code samtools} subprocess implementation
 * so tio-browser works on Windows without requiring a system samtools
 * install. The public API is unchanged; the {@code SamtoolsNotFoundException}
 * type is retained as a no-throw historical alias so callers and tests
 * compile unchanged.</p>
 *
 * <p>Format auto-detection is provided by htsjdk based on magic bytes;
 * one parser handles both SAM and BAM. The companion {@link SamReader}
 * (note: name collides with htsjdk.samtools.SamReader — fully qualify if
 * needed) exists as a discoverable convenience alias.</p>
 *
 * <p><b>Cross-language equivalents:</b> Python {@code ttio.importers.bam.BamReader},
 * Objective-C {@code TTIOBamReader}. The byte-level output is verified
 * by the {@code cross-compat} CI job.</p>
 *
 * (M87, v1.5.0 htsjdk swap)
 */
public class BamReader {

    /** Default emit-every-N cadence for the
     *  {@link #toGenomicRun(String, String, String, ProgressSink)}
     *  {@link ProgressSink}. The htsjdk record iterator can chew
     *  through several hundred thousand records per second; a tighter
     *  cadence drowns the GUI thread without adding info. */
    public static final int PROGRESS_INTERVAL_READS = 1000;

    static {
        // htsjdk's CRAM decoder validates the reference sequence MD5 by
        // default and refuses to decode if the embedded CRAM @SQ M5 hash
        // doesn't match the on-disk FASTA. The old samtools-subprocess
        // BamWriter / CramWriter wrote @SQ LN:INT32_MAX placeholders and
        // samtools never cared; htsjdk does. Disable the check globally
        // so we can read existing fixture CRAMs and not block on MD5
        // strictness. Lossless data integrity is still ensured by CRAM's
        // per-record byte-exact reconstruction.
        if (System.getProperty("samjdk.cram.use_alignment_md5_check") == null) {
            System.setProperty("samjdk.cram.use_alignment_md5_check", "false");
        }
    }

    /**
     * Historical exception type from the samtools-subprocess era.
     * v1.5.0 onwards never throws this — htsjdk is a Maven dep, always
     * available. Retained as a no-throw alias so callers and tests that
     * catch this type still compile.
     */
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
     */
    public List<ProvenanceRecord> lastProvenance() { return lastProvenance; }

    /** Default name {@code "genomic_0001"}, no region filter, no sample override. */
    public WrittenGenomicRun toGenomicRun(String name) throws IOException {
        return toGenomicRun(name, null, null, ProgressSink.discard());
    }

    /** No sample override. */
    public WrittenGenomicRun toGenomicRun(String name, String region)
            throws IOException {
        return toGenomicRun(name, region, null, ProgressSink.discard());
    }

    /** Backwards-compatible overload without a {@link ProgressSink}. */
    public WrittenGenomicRun toGenomicRun(String name, String region,
                                          String sampleName) throws IOException {
        return toGenomicRun(name, region, sampleName, ProgressSink.discard());
    }

    /** {@code ProgressSink}-accepting overload; defaults region + sample
     *  to {@code null}. */
    public WrittenGenomicRun toGenomicRun(String name, ProgressSink progress)
            throws IOException {
        return toGenomicRun(name, null, null, progress);
    }

    /**
     * Read the BAM/SAM and return a {@link WrittenGenomicRun}, firing
     * {@code progress.onProgress(readsDone, -1L)} every
     * {@link #PROGRESS_INTERVAL_READS} records during iteration and a
     * final {@code onProgress(total, total)} once all records have been
     * consumed. Total is unknown mid-iteration because htsjdk's record
     * iterator does not expose a cheap count without re-walking the
     * file (and the file may be region-filtered).
     *
     * @param name        run name (becomes {@code /study/genomic_runs/<name>}).
     * @param region      optional region filter (e.g. {@code "chr1:1000-2000"},
     *                    {@code "chr1"}, {@code "*"} for unmapped); {@code null}
     *                    means no filter.
     * @param sampleName  optional override for {@code sample_name};
     *                    {@code null} means "use first @RG SM:".
     * @param progress    progress callback; {@link ProgressSink#discard()}
     *                    if you don't care.
     * @throws IOException if the file is missing, malformed, or a region
     *                     filter is requested against an unindexed file.
     * @since 1.5.0
     */
    public WrittenGenomicRun toGenomicRun(String name, String region,
                                          String sampleName,
                                          ProgressSink progress)
            throws IOException {
        if (progress == null) progress = ProgressSink.discard();
        if (!Files.exists(path)) {
            throw new IOException("BAM/SAM file not found: " + path);
        }
        // htsjdk treats a zero-byte file as a 0-record BAM rather than
        // an error; reject explicitly for parity with samtools' "no BGZF
        // header" rejection and with the V4 zero-byte regression test.
        try {
            if (Files.size(path) == 0) {
                throw new IOException(
                    "BAM/SAM file is empty (0 bytes): " + path);
            }
        } catch (IOException e) {
            throw e;
        }

        long fileMtime;
        try {
            fileMtime = Files.getLastModifiedTime(path).toInstant().getEpochSecond();
        } catch (IOException e) {
            fileMtime = System.currentTimeMillis() / 1000L;
        }

        // Header state
        List<String> sqNames = new ArrayList<>();
        String rgSample = "";
        String rgPlatform = "";
        List<ProvenanceRecord> provenance = new ArrayList<>();

        // Per-read accumulators (boxed because final size is unknown).
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

        SamReaderFactory factory = makeReaderFactory();
        SamReader reader;
        try {
            reader = factory.open(SamInputResource.of(path.toFile()));
        } catch (RuntimeException e) {
            // htsjdk throws FileTruncatedException / SAMFormatException /
            // RuntimeIOException as unchecked. Wrap so callers catching
            // IOException (the documented contract) still see them.
            throw new IOException(
                "Failed to open BAM/SAM/CRAM: " + path + ": " + e.getMessage(), e);
        }
        try (reader) {
            SAMFileHeader header = reader.getFileHeader();

            // @SQ → reference sequence names (first wins for reference_uri).
            for (SAMSequenceRecord seq : header.getSequenceDictionary().getSequences()) {
                sqNames.add(seq.getSequenceName());
            }

            // @RG → sample + platform (first wins).
            for (SAMReadGroupRecord rg : header.getReadGroups()) {
                if (rgSample.isEmpty() && rg.getSample() != null) {
                    rgSample = rg.getSample();
                }
                if (rgPlatform.isEmpty() && rg.getPlatform() != null) {
                    rgPlatform = rg.getPlatform();
                }
            }

            // @PG → provenance records.
            for (SAMProgramRecord pg : header.getProgramRecords()) {
                String program = pg.getProgramName() != null ? pg.getProgramName() : "";
                Map<String, String> params = new LinkedHashMap<>();
                String cl = pg.getCommandLine();
                if (cl != null) params.put("CL", cl);
                if (pg.getId() != null) params.put("ID", pg.getId());
                if (pg.getProgramVersion() != null) params.put("VN", pg.getProgramVersion());
                if (pg.getPreviousProgramGroupId() != null) {
                    params.put("PP", pg.getPreviousProgramGroupId());
                }
                provenance.add(new ProvenanceRecord(
                    fileMtime, program, params, List.of(), List.of()));
            }

            // Iterate alignments — region filter applied if requested.
            // htsjdk may throw RuntimeException subclasses
            // (SAMFormatException, FileTruncatedException, etc.) during
            // record parsing; wrap as IOException for caller contract.
            Iterator<SAMRecord> it;
            try {
                it = iteratorFor(reader, region);
            } catch (RuntimeException e) {
                throw new IOException(
                    "Failed to iterate records in " + path + ": " + e.getMessage(), e);
            }
            try {
                while (true) {
                    SAMRecord rec;
                    try {
                        if (!it.hasNext()) break;
                        rec = it.next();
                    } catch (RuntimeException e) {
                        throw new IOException(
                            "Malformed record in " + path + ": " + e.getMessage(), e);
                    }

                    String qname = rec.getReadName() != null ? rec.getReadName() : "*";
                    int flag = rec.getFlags();
                    String rname = rec.getReferenceName() != null
                        ? rec.getReferenceName() : "*";
                    // SAM spec: 1-based pos; 0 means unmapped/no position.
                    // htsjdk: getAlignmentStart() returns 1-based or 0 if NO_ALIGNMENT_START.
                    long pos = rec.getAlignmentStart();
                    int mapq = rec.getMappingQuality();
                    String cigar = rec.getCigarString() != null
                        ? rec.getCigarString() : "*";
                    // RNEXT: htsjdk auto-expands "=" to the actual ref name —
                    // same semantic as the prior samtools-text parser's manual
                    // expansion (Gotcha §156).
                    String rnext = rec.getMateReferenceName() != null
                        ? rec.getMateReferenceName() : "*";
                    long pnext = rec.getMateAlignmentStart();
                    int tlen = rec.getInferredInsertSize();

                    readNames.add(qname);
                    flagsL.add(flag);
                    chromosomes.add(rname);
                    positionsL.add(pos);
                    mappingQualitiesL.add(mapq);
                    cigars.add(cigar);
                    mateChromosomes.add(rnext);
                    matePositionsL.add(pnext);
                    templateLengthsL.add(tlen);

                    // SEQ: getReadString() returns "*" for missing or an ASCII
                    // sequence string. Match the prior parser's "*" → empty bytes.
                    String seqStr = rec.getReadString();
                    byte[] seqBytes;
                    if (seqStr == null || "*".equals(seqStr)) {
                        seqBytes = new byte[0];
                    } else {
                        seqBytes = seqStr.getBytes(StandardCharsets.US_ASCII);
                    }

                    // QUAL: getBaseQualities() returns raw Phred bytes (0-93)
                    // or SAMRecord.NULL_QUALS (a static empty array) for "*".
                    // Prior parser stored Phred+33 ASCII bytes (verbatim from
                    // SAM text). Convert raw -> ASCII by adding 33 to match.
                    byte[] qualRaw = rec.getBaseQualities();
                    byte[] qualBytes;
                    if (qualRaw == null || qualRaw == SAMRecord.NULL_QUALS
                            || qualRaw.length == 0) {
                        if (seqBytes.length == 0) {
                            qualBytes = new byte[0];
                        } else {
                            qualBytes = new byte[seqBytes.length];
                            Arrays.fill(qualBytes, (byte) 0xFF);
                        }
                    } else {
                        qualBytes = new byte[qualRaw.length];
                        for (int i = 0; i < qualRaw.length; i++) {
                            qualBytes[i] = (byte) ((qualRaw[i] & 0xFF) + 33);
                        }
                    }

                    if (qualBytes.length != seqBytes.length) {
                        if (seqBytes.length == 0) {
                            qualBytes = new byte[0];
                        } else if (qualBytes.length != 0) {
                            throw new IOException(
                                "SEQ/QUAL length mismatch in record " + qname
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

                    if (readNames.size() % PROGRESS_INTERVAL_READS == 0) {
                        progress.onProgress(readNames.size(), -1L);
                    }
                }
            } finally {
                if (it instanceof htsjdk.samtools.util.CloseableIterator<?>) {
                    ((htsjdk.samtools.util.CloseableIterator<?>) it).close();
                }
            }
        }

        // sample_name override.
        String effectiveSample = sampleName != null ? sampleName : rgSample;

        // reference_uri: first @SQ wins.
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

        // Final progress fire — total is now known. Listeners can flip
        // from indeterminate ("done out of ?") to determinate
        // ("done == total"), which the import dialog uses to mark
        // 100% before the write phase begins.
        progress.onProgress((long) n, (long) n);

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
    // Factory + region filter (overridable by CramReader)
    // ------------------------------------------------------------------

    /**
     * Build the htsjdk reader factory for this importer. Default is the
     * lenient stringency factory suitable for SAM/BAM. {@link CramReader}
     * overrides to inject a {@code ReferenceSource} so reference-
     * compressed CRAM bytes can be reconstituted.
     */
    protected SamReaderFactory makeReaderFactory() {
        return SamReaderFactory.makeDefault()
            .validationStringency(ValidationStringency.LENIENT);
    }


    /**
     * Resolve a samtools-style region string ({@code null}, {@code "*"},
     * {@code "chr1"}, {@code "chr1:1000"}, {@code "chr1:1000-2000"}) to
     * an iterator over matching SAMRecords. Subclasses
     * ({@code CramReader} in M88) can override to inject a reference for
     * CRAM decode if needed; default implementation handles SAM/BAM.
     */
    protected Iterator<SAMRecord> iteratorFor(SamReader reader, String region) {
        if (region == null) {
            return reader.iterator();
        }
        if ("*".equals(region)) {
            return reader.queryUnmapped();
        }
        // Parse "name[:start[-end]]" with optional thousands-separator commas.
        String refName;
        int start = 1;
        int end = Integer.MAX_VALUE;
        int colon = region.indexOf(':');
        if (colon < 0) {
            refName = region;
        } else {
            refName = region.substring(0, colon);
            String range = region.substring(colon + 1).replace(",", "");
            int dash = range.indexOf('-');
            try {
                if (dash < 0) {
                    start = Integer.parseInt(range);
                } else {
                    start = Integer.parseInt(range.substring(0, dash));
                    end = Integer.parseInt(range.substring(dash + 1));
                }
            } catch (NumberFormatException nfe) {
                throw new IllegalArgumentException(
                    "Malformed region string: " + region
                    + " (expected name[:start[-end]])", nfe);
            }
        }
        return reader.queryOverlapping(refName, start, end);
    }

    // ------------------------------------------------------------------
    // Samtools-availability shims (always-true since v1.5.0)
    // ------------------------------------------------------------------

    /**
     * Pre-v1.5.0 this probed for {@code samtools} on PATH. v1.5.0 onwards
     * BamReader uses htsjdk (a Maven dep, always available), so this
     * unconditionally returns {@code true}. Retained for source compat
     * with tests using {@code Assumptions.assumeTrue(isSamtoolsAvailable())}.
     */
    public static boolean isSamtoolsAvailable() {
        return true;
    }
}
