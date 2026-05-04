#ifndef TTIO_WRITTEN_GENOMIC_RUN_H
#define TTIO_WRITTEN_GENOMIC_RUN_H

#import <Foundation/Foundation.h>
#import "ValueClasses/TTIOEnums.h"

@class TTIOProvenanceRecord;

NS_ASSUME_NONNULL_BEGIN

/**
 * Write-side container for a single genomic run, passed to
 * +[TTIOSpectralDataset writeMinimalToPath:...genomicRuns:...].
 *
 * Genomic analogue of TTIOWrittenRun. Pure data — no methods beyond
 * accessors and the designated initializer.
 *
 * Cross-language equivalents:
 *   Python: ttio.written_genomic_run.WrittenGenomicRun
 *   Java:   global.thalion.ttio.genomics.WrittenGenomicRun
 */
@interface TTIOWrittenGenomicRun : NSObject

@property (readonly) TTIOAcquisitionMode acquisitionMode;
@property (readonly, copy) NSString *referenceUri;
@property (readonly, copy) NSString *platform;
@property (readonly, copy) NSString *sampleName;

// Per-read parallel arrays (length == readCount), packed in NSData
@property (readonly, copy) NSData *positionsData;        // int64_t
@property (readonly, copy) NSData *mappingQualitiesData; // uint8_t
@property (readonly, copy) NSData *flagsData;            // uint32_t

// Concatenated signal data
@property (readonly, copy) NSData *sequencesData;  // uint8_t (one ASCII byte per base)
@property (readonly, copy) NSData *qualitiesData;  // uint8_t (Phred scores)

// Per-read offsets/lengths into sequences/qualities
@property (readonly, copy) NSData *offsetsData;    // uint64_t
@property (readonly, copy) NSData *lengthsData;    // uint32_t

// Per-read variable-length fields
@property (readonly, copy) NSArray<NSString *> *cigars;
@property (readonly, copy) NSArray<NSString *> *readNames;
@property (readonly, copy) NSArray<NSString *> *mateChromosomes;
@property (readonly, copy) NSData *matePositionsData;    // int64_t (-1 sentinel)
@property (readonly, copy) NSData *templateLengthsData;  // int32_t (0 sentinel)

// Chromosomes (per-read, for the index)
@property (readonly, copy) NSArray<NSString *> *chromosomes;

// Optional codec choice — defaults to TTIOCompressionZlib
@property (readonly) TTIOCompression signalCompression;

/**
 * M86: per-channel codec opt-in. Maps channel name (NSString *) to a
 * boxed TTIOCompression value (NSNumber *). Only @"sequences" and
 * @"qualities" are accepted as channel keys; only RansOrder0,
 * RansOrder1, BasePack are accepted as codec values. Channels not in
 * this dictionary use the existing signalCompression path. Defaults
 * to an empty dictionary.
 *
 * Cross-language equivalent of Python's
 * ``WrittenGenomicRun.signal_codec_overrides``.
 */
@property (readonly, copy) NSDictionary<NSString *, NSNumber *> *signalCodecOverrides;

/** Phase 1 (post-M91): per-run provenance records. Persisted under
 *  ``<run>/provenance/steps`` by the writer; read back via
 *  -[TTIOGenomicRun provenanceChain]. Defaults to an empty array.
 *  Settable so callers building a TTIOWrittenGenomicRun via the
 *  existing initialisers can attach provenance after construction
 *  without binding the (already large) initialiser surface. */
@property (nonatomic, copy) NSArray<TTIOProvenanceRecord *> *provenanceRecords;

/** M93 v1.2: when YES (default) AND a context-aware codec is selected
 *  on the ``sequences`` channel, the writer embeds the chromosome
 *  sequences supplied in ``referenceChromSeqs`` at
 *  ``/study/references/<referenceUri>/`` in the output file. */
@property (nonatomic, assign) BOOL embedReference;

/** M93 v1.2: chromosome name -> uppercase ACGTN bytes. Required when
 *  REF_DIFF is selected on ``sequences`` and ``embedReference`` is YES;
 *  otherwise REF_DIFF falls back silently to BASE_PACK on this channel. */
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSData *> *referenceChromSeqs;

/** M93 v1.2: external reference path stamped into file metadata for
 *  decoder fallback when the embedded reference is absent. The writer
 *  never reads this path; metadata only. */
@property (nonatomic, copy, nullable) NSString *externalReferencePath;

/** v1.7 #11: when YES, the writer falls back to the M86 Phase F
 *  per-field mate_info subgroup layout (or the M82 compound when no
 *  per-field overrides are set). Default NO: the writer encodes via
 *  TTIOMateInfoV2 (codec id 13) into
 *  signal_channels/mate_info/inline_v2.
 *
 *  Cross-language equivalent of Python's
 *  ``WrittenGenomicRun.opt_disable_inline_mate_info_v2``. */
@property (nonatomic, assign) BOOL optDisableInlineMateInfoV2;

/** v1.8 #11: when YES, the writer falls back to the v1 REF_DIFF flat
 *  dataset layout (@compression=9) for signal_channels/sequences.
 *  Default NO: when the native lib is linked AND the run is eligible
 *  (reference present, all reads mapped, single chromosome), the writer
 *  encodes via TTIORefDiffV2 (codec id 14) and writes sequences as a
 *  GROUP containing a refdiff_v2 child dataset.
 *
 *  Cross-language equivalent of Python's
 *  ``WrittenGenomicRun.opt_disable_ref_diff_v2``. */
@property (nonatomic, assign) BOOL optDisableRefDiffV2;

@property (readonly) NSUInteger readCount;

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

/** M86: same as the 17-arg initialiser plus per-channel codec overrides. */
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
