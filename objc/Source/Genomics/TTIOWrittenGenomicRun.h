#ifndef TTIO_WRITTEN_GENOMIC_RUN_H
#define TTIO_WRITTEN_GENOMIC_RUN_H

#import <Foundation/Foundation.h>
#import "ValueClasses/TTIOEnums.h"

@class TTIOProvenanceRecord;

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> Genomics/TTIOWrittenGenomicRun.h</p>
 *
 * <p>Write-side container for a single genomic run, passed to
 * <code>+[TTIOSpectralDataset writeMinimalToPath:...genomicRuns:...]</code>.
 * Genomic analogue of <code>TTIOWrittenRun</code>. Pure data — no
 * methods beyond accessors and the designated initialisers.</p>
 *
 * <p>The class holds parallel C-array buffers (positions, mapping
 * qualities, flags, sequences, qualities, offsets, lengths, mate
 * positions, template lengths) plus per-read variable-length string
 * arrays (cigars, read names, mate chromosomes, chromosomes). The
 * writer materialises these into the on-disk channel layout
 * described in <code>docs/format-spec.md</code> §10.4-§10.10.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python:
 * <code>ttio.written_genomic_run.WrittenGenomicRun</code><br/>
 * Java:
 * <code>global.thalion.ttio.genomics.WrittenGenomicRun</code></p>
 */
@interface TTIOWrittenGenomicRun : NSObject

/** Acquisition mode. */
@property (readonly) TTIOAcquisitionMode acquisitionMode;

/** Reference genome URI (e.g. <code>@"GRCh38.p14"</code>). */
@property (readonly, copy) NSString *referenceUri;

/** Sequencing platform identifier. */
@property (readonly, copy) NSString *platform;

/** Sample identifier. */
@property (readonly, copy) NSString *sampleName;

/** int64 mapping positions. */
@property (readonly, copy) NSData *positionsData;

/** uint8 mapping qualities. */
@property (readonly, copy) NSData *mappingQualitiesData;

/** uint32 SAM flags. */
@property (readonly, copy) NSData *flagsData;

/** Concatenated uint8 read sequences (one ASCII byte per base). */
@property (readonly, copy) NSData *sequencesData;

/** Concatenated uint8 quality scores (Phred). */
@property (readonly, copy) NSData *qualitiesData;

/** uint64 per-read offsets into <code>sequencesData</code> /
 *  <code>qualitiesData</code>. */
@property (readonly, copy) NSData *offsetsData;

/** uint32 per-read base counts. */
@property (readonly, copy) NSData *lengthsData;

/** Per-read CIGAR strings. */
@property (readonly, copy) NSArray<NSString *> *cigars;

/** Per-read read names. */
@property (readonly, copy) NSArray<NSString *> *readNames;

/** Per-read mate chromosome names. */
@property (readonly, copy) NSArray<NSString *> *mateChromosomes;

/** int64 per-read mate positions; <code>-1</code> sentinel for
 *  unmapped mates. */
@property (readonly, copy) NSData *matePositionsData;

/** int32 per-read template lengths; <code>0</code> sentinel for
 *  unpaired reads. */
@property (readonly, copy) NSData *templateLengthsData;

/** Per-read chromosome names (for the genomic index). */
@property (readonly, copy) NSArray<NSString *> *chromosomes;

/** HDF5-filter compression codec applied to non-genomic-codec
 *  channels. Defaults to <code>TTIOCompressionZlib</code>. */
@property (readonly) TTIOCompression signalCompression;

/**
 * Per-channel codec opt-in. Maps channel name
 * (<code>NSString *</code>) to a boxed
 * <code>TTIOCompression</code> value (<code>NSNumber *</code>).
 * Channels not listed use the
 * <code>signalCompression</code> path. Cross-language equivalent
 * of Python's
 * <code>WrittenGenomicRun.signal_codec_overrides</code>.
 */
@property (readonly, copy) NSDictionary<NSString *, NSNumber *> *signalCodecOverrides;

/** Per-run provenance records. Persisted under
 *  <code>&lt;run&gt;/provenance/steps</code> by the writer; read
 *  back via <code>-[TTIOGenomicRun provenanceChain]</code>.
 *  Defaults to an empty array. */
@property (nonatomic, copy) NSArray<TTIOProvenanceRecord *> *provenanceRecords;

/** When <code>YES</code> (default) and a context-aware codec is
 *  selected on the <code>sequences</code> channel, the writer
 *  embeds the chromosome sequences supplied in
 *  <code>referenceChromSeqs</code> at
 *  <code>/study/references/&lt;referenceUri&gt;/</code>. */
@property (nonatomic, assign) BOOL embedReference;

/** Map from chromosome name to uppercase ACGTN bytes. Required
 *  when <code>REF_DIFF_V2</code> is selected on
 *  <code>sequences</code> and <code>embedReference</code> is
 *  <code>YES</code>; otherwise the writer falls back silently to
 *  <code>BASE_PACK</code> on this channel. */
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSData *> *referenceChromSeqs;

/** External reference path stamped into file metadata for decoder
 *  fallback when the embedded reference is absent. The writer
 *  never reads this path; metadata only. */
@property (nonatomic, copy, nullable) NSString *externalReferencePath;

/** Number of reads in the run. */
@property (readonly) NSUInteger readCount;

/**
 * Convenience initialiser without per-channel codec overrides;
 * delegates to the designated initialiser with an empty overrides
 * dictionary.
 */
- (instancetype)initWithAcquisitionMode:(TTIOAcquisitionMode)mode
                           referenceUri:(NSString *)referenceUri
                               platform:(NSString *)platform
                             sampleName:(NSString *)sampleName
                              positions:(NSData *)positions
                       mappingQualities:(NSData *)mappingQualities
                                  flags:(NSData *)flags
                              sequences:(NSData *)sequences
                              qualities:(NSData *)qualities
                                offsets:(NSData *)offsets
                                lengths:(NSData *)lengths
                                 cigars:(NSArray<NSString *> *)cigars
                              readNames:(NSArray<NSString *> *)readNames
                        mateChromosomes:(NSArray<NSString *> *)mateChromosomes
                          matePositions:(NSData *)matePositions
                        templateLengths:(NSData *)templateLengths
                            chromosomes:(NSArray<NSString *> *)chromosomes
                      signalCompression:(TTIOCompression)signalCompression;

/** Designated initialiser including the per-channel codec
 *  overrides dictionary. */
- (instancetype)initWithAcquisitionMode:(TTIOAcquisitionMode)mode
                           referenceUri:(NSString *)referenceUri
                               platform:(NSString *)platform
                             sampleName:(NSString *)sampleName
                              positions:(NSData *)positions
                       mappingQualities:(NSData *)mappingQualities
                                  flags:(NSData *)flags
                              sequences:(NSData *)sequences
                              qualities:(NSData *)qualities
                                offsets:(NSData *)offsets
                                lengths:(NSData *)lengths
                                 cigars:(NSArray<NSString *> *)cigars
                              readNames:(NSArray<NSString *> *)readNames
                        mateChromosomes:(NSArray<NSString *> *)mateChromosomes
                          matePositions:(NSData *)matePositions
                        templateLengths:(NSData *)templateLengths
                            chromosomes:(NSArray<NSString *> *)chromosomes
                      signalCompression:(TTIOCompression)signalCompression
                   signalCodecOverrides:(NSDictionary<NSString *, NSNumber *> *)signalCodecOverrides;

@end

NS_ASSUME_NONNULL_END

#endif
