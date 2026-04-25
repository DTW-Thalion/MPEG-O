#ifndef TTIO_ALIGNED_READ_H
#define TTIO_ALIGNED_READ_H

#import <Foundation/Foundation.h>

/**
 * One aligned sequencing read — the genomic analogue of TTIOMassSpectrum.
 *
 * Immutable value object materialised by TTIOGenomicRun from the signal
 * channels under /study/genomic_runs/<name>/signal_channels/. No HDF5
 * I/O on this class directly.
 *
 * API status: Stable (M82.2).
 *
 * Cross-language equivalents:
 *   Python: ttio.aligned_read.AlignedRead
 *   Java:   global.thalion.ttio.genomics.AlignedRead
 */
@interface TTIOAlignedRead : NSObject <NSCopying>

@property (nonatomic, readonly, copy)   NSString *readName;
@property (nonatomic, readonly, copy)   NSString *chromosome;
@property (nonatomic, readonly)         int64_t   position;
@property (nonatomic, readonly)         uint8_t   mappingQuality;
@property (nonatomic, readonly, copy)   NSString *cigar;
@property (nonatomic, readonly, copy)   NSString *sequence;
@property (nonatomic, readonly, copy)   NSData   *qualities;
@property (nonatomic, readonly)         uint32_t  flags;
@property (nonatomic, readonly, copy)   NSString *mateChromosome;
@property (nonatomic, readonly)         int64_t   matePosition;
@property (nonatomic, readonly)         int32_t   templateLength;

// Convenience SAM flag accessors
- (BOOL)isMapped;
- (BOOL)isPaired;
- (BOOL)isReverse;
- (BOOL)isSecondary;
- (BOOL)isSupplementary;
- (NSUInteger)readLength;

- (instancetype)initWithReadName:(NSString *)readName
                      chromosome:(NSString *)chromosome
                        position:(int64_t)position
                  mappingQuality:(uint8_t)mappingQuality
                           cigar:(NSString *)cigar
                        sequence:(NSString *)sequence
                       qualities:(NSData *)qualities
                           flags:(uint32_t)flags
                  mateChromosome:(NSString *)mateChromosome
                    matePosition:(int64_t)matePosition
                  templateLength:(int32_t)templateLength;
@end

#endif
