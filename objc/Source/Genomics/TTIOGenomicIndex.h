#ifndef TTIO_GENOMIC_INDEX_H
#define TTIO_GENOMIC_INDEX_H

#import <Foundation/Foundation.h>

@protocol TTIOStorageGroup;

/**
 * Per-read offsets, lengths, positions, mapping qualities, flags, and
 * chromosome strings for one TTIOGenomicRun. Held in memory as NSData
 * buffers backing typed C arrays; exposed via typed accessors. Loaded
 * eagerly when the run is opened.
 *
 * Genomic analogue of TTIOSpectrumIndex.
 *
 * API status: Provisional (M82.2). Disk read/write methods land in a
 * follow-up commit; until then they raise NSInternalInconsistencyException.
 *
 * Cross-language equivalents:
 *   Python: ttio.genomic_index.GenomicIndex
 *   Java:   global.thalion.ttio.genomics.GenomicIndex
 */
@interface TTIOGenomicIndex : NSObject

@property (readonly) NSUInteger count;

- (uint64_t)offsetAt:(NSUInteger)index;
- (uint32_t)lengthAt:(NSUInteger)index;
- (int64_t)positionAt:(NSUInteger)index;
- (uint8_t)mappingQualityAt:(NSUInteger)index;
- (uint32_t)flagsAt:(NSUInteger)index;
- (NSString *)chromosomeAt:(NSUInteger)index;

/** Read indices on `chromosome` with start <= position < end. */
- (NSIndexSet *)indicesForRegion:(NSString *)chromosome
                            start:(int64_t)start
                              end:(int64_t)end;

/** Read indices where (flags & 0x4) != 0. */
- (NSIndexSet *)indicesForUnmapped;

/** Read indices where (flags & flagMask) != 0. */
- (NSIndexSet *)indicesForFlag:(uint32_t)flagMask;

#pragma mark - Construction

- (instancetype)initWithOffsets:(NSData *)offsets
                         lengths:(NSData *)lengths
                     chromosomes:(NSArray<NSString *> *)chromosomes
                       positions:(NSData *)positions
                mappingQualities:(NSData *)mappingQualities
                            flags:(NSData *)flags;

#pragma mark - I/O (implemented in a follow-up commit)

- (BOOL)writeToGroup:(id<TTIOStorageGroup>)group
                error:(NSError **)error;

+ (instancetype)readFromGroup:(id<TTIOStorageGroup>)group
                         error:(NSError **)error;

@end

#endif
