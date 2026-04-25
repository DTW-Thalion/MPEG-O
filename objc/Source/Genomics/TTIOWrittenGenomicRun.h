#ifndef TTIO_WRITTEN_GENOMIC_RUN_H
#define TTIO_WRITTEN_GENOMIC_RUN_H

#import <Foundation/Foundation.h>
#import "ValueClasses/TTIOEnums.h"

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

@end

#endif
