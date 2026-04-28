/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.genomics;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.ProvenanceRecord;

import java.util.List;
import java.util.Map;
import java.util.Objects;

/**
 * Write-side container for a single genomic run, passed to
 * {@link global.thalion.ttio.SpectralDataset#writeMinimal SpectralDataset.writeMinimal}.
 *
 * <p>Genomic analogue of {@link global.thalion.ttio.WrittenRun}. Pure
 * data — no methods beyond accessors and the canonical record
 * components.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOWrittenGenomicRun}, Python
 * {@code ttio.written_genomic_run.WrittenGenomicRun}.</p>
 *
 * @param acquisitionMode    {@link AcquisitionMode#GENOMIC_WGS} or
 *                           {@link AcquisitionMode#GENOMIC_WES}.
 * @param referenceUri       e.g. {@code "GRCh38.p14"}.
 * @param platform           e.g. {@code "ILLUMINA"}.
 * @param sampleName         e.g. {@code "NA12878"}.
 * @param positions          int64 per-read 0-based mapping positions.
 * @param mappingQualities   uint8 per-read mapping qualities.
 * @param flags              uint32 per-read SAM flags.
 * @param sequences          uint8 concatenated bases (one ASCII byte
 *                           per base in M82; base-packing deferred to
 *                           the codec milestone).
 * @param qualities          uint8 concatenated Phred quality scores.
 * @param offsets            uint64 per-read byte offset into
 *                           sequences/qualities.
 * @param lengths            uint32 per-read length in bases.
 * @param cigars             one CIGAR string per read.
 * @param readNames          one read name per read.
 * @param mateChromosomes    one mate chromosome per read; {@code ""}
 *                           if unpaired.
 * @param matePositions      int64 per-read mate position; {@code -1}
 *                           if unpaired.
 * @param templateLengths    int32 per-read template length; {@code 0}
 *                           if unpaired.
 * @param chromosomes        one chromosome per read (for the index).
 * @param signalCompression  codec applied to typed signal channels.
 *                           Defaults to {@link Compression#ZLIB}; pass
 *                           {@link Compression#NONE} to skip.
 * @param signalCodecOverrides M86: per-channel TTI-O codec opt-in.
 *                           Maps channel name (only {@code "sequences"}
 *                           and {@code "qualities"} accepted) to a
 *                           codec id (only {@link Compression#RANS_ORDER0},
 *                           {@link Compression#RANS_ORDER1}, or
 *                           {@link Compression#BASE_PACK} accepted).
 *                           Channels not in this map use the
 *                           {@link #signalCompression} HDF5-filter
 *                           dispatch path. Defaults to
 *                           {@link Map#of() empty}; never {@code null}.
 * @param provenanceRecords  Phase 1 (post-M91): per-run provenance
 *                           chain in insertion order. Defaults to
 *                           {@link List#of() empty}; never {@code null}.
 *                           Round-trips through the
 *                           {@code <run>/provenance_json} attribute on
 *                           the genomic run group, mirroring
 *                           {@link global.thalion.ttio.AcquisitionRun}'s
 *                           layout.
 */
public record WrittenGenomicRun(
    AcquisitionMode acquisitionMode,
    String referenceUri,
    String platform,
    String sampleName,
    long[] positions,
    byte[] mappingQualities,
    int[]  flags,
    byte[] sequences,
    byte[] qualities,
    long[] offsets,
    int[]  lengths,
    List<String> cigars,
    List<String> readNames,
    List<String> mateChromosomes,
    long[] matePositions,
    int[]  templateLengths,
    List<String> chromosomes,
    Compression signalCompression,
    Map<String, Compression> signalCodecOverrides,
    List<ProvenanceRecord> provenanceRecords
) {
    public WrittenGenomicRun {
        Objects.requireNonNull(acquisitionMode);
        Objects.requireNonNull(referenceUri);
        Objects.requireNonNull(platform);
        Objects.requireNonNull(sampleName);
        Objects.requireNonNull(signalCompression);
        Objects.requireNonNull(signalCodecOverrides,
            "signalCodecOverrides must not be null; pass Map.of() for none");
        Objects.requireNonNull(provenanceRecords,
            "provenanceRecords must not be null; pass List.of() for none");
        cigars                = List.copyOf(cigars);
        readNames             = List.copyOf(readNames);
        mateChromosomes       = List.copyOf(mateChromosomes);
        chromosomes           = List.copyOf(chromosomes);
        signalCodecOverrides  = Map.copyOf(signalCodecOverrides);
        provenanceRecords     = List.copyOf(provenanceRecords);
    }

    /**
     * Backwards-compatible constructor (pre-M86) that defaults
     * {@link #signalCodecOverrides} to {@link Map#of() empty}. Existing
     * callers that build a run without per-channel codec overrides
     * continue to work unchanged.
     */
    public WrittenGenomicRun(
        AcquisitionMode acquisitionMode,
        String referenceUri,
        String platform,
        String sampleName,
        long[] positions,
        byte[] mappingQualities,
        int[]  flags,
        byte[] sequences,
        byte[] qualities,
        long[] offsets,
        int[]  lengths,
        List<String> cigars,
        List<String> readNames,
        List<String> mateChromosomes,
        long[] matePositions,
        int[]  templateLengths,
        List<String> chromosomes,
        Compression signalCompression
    ) {
        this(acquisitionMode, referenceUri, platform, sampleName,
             positions, mappingQualities, flags, sequences, qualities,
             offsets, lengths, cigars, readNames, mateChromosomes,
             matePositions, templateLengths, chromosomes,
             signalCompression, Map.of(), List.of());
    }

    /**
     * Backwards-compatible constructor (M86 era, 19 components) that
     * defaults {@link #provenanceRecords} to {@link List#of() empty}.
     * Existing callers built before Phase 1 (post-M91) continue to
     * work unchanged.
     */
    public WrittenGenomicRun(
        AcquisitionMode acquisitionMode,
        String referenceUri,
        String platform,
        String sampleName,
        long[] positions,
        byte[] mappingQualities,
        int[]  flags,
        byte[] sequences,
        byte[] qualities,
        long[] offsets,
        int[]  lengths,
        List<String> cigars,
        List<String> readNames,
        List<String> mateChromosomes,
        long[] matePositions,
        int[]  templateLengths,
        List<String> chromosomes,
        Compression signalCompression,
        Map<String, Compression> signalCodecOverrides
    ) {
        this(acquisitionMode, referenceUri, platform, sampleName,
             positions, mappingQualities, flags, sequences, qualities,
             offsets, lengths, cigars, readNames, mateChromosomes,
             matePositions, templateLengths, chromosomes,
             signalCompression, signalCodecOverrides, List.of());
    }

    /** Number of reads (derived from {@link #offsets} length). */
    public int readCount() { return offsets.length; }
}
