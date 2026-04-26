#ifndef TTIO_GENOMIC_RUN_H
#define TTIO_GENOMIC_RUN_H

#import <Foundation/Foundation.h>
#import "ValueClasses/TTIOEnums.h"

@class TTIOAlignedRead;
@class TTIOGenomicIndex;
@protocol TTIOStorageGroup;

/**
 * Lazy view over one /study/genomic_runs/<name>/ group.
 *
 * Materialises TTIOAlignedRead objects on demand from the signal
 * channels. The TTIOGenomicIndex is loaded eagerly at open time for
 * cheap filtering and offset lookups; the heavy signal channels
 * (sequences, qualities, plus 3 compounds) stay lazy on disk.
 *
 * Genomic analogue of TTIOAcquisitionRun.
 *
 * Cross-language equivalents:
 *   Python: ttio.genomic_run.GenomicRun
 *   Java:   global.thalion.ttio.genomics.GenomicRun
 */
@interface TTIOGenomicRun : NSObject

@property (readonly, copy) NSString *name;
@property (readonly) TTIOAcquisitionMode acquisitionMode;
@property (readonly, copy) NSString *modality;
@property (readonly, copy) NSString *referenceUri;
@property (readonly, copy) NSString *platform;
@property (readonly, copy) NSString *sampleName;
@property (readonly, strong) TTIOGenomicIndex *index;

- (NSUInteger)readCount;

/** Materialise the read at `index`. Returns nil and sets *error on
 *  invalid index or I/O failure. */
- (TTIOAlignedRead *)readAtIndex:(NSUInteger)index
                            error:(NSError **)error;

/** Return the read name at `index`. Dispatches on the on-disk
 *  read_names dataset shape (M86 Phase E):
 *    - Compound `{value: VL_STRING}`: existing M82 read path.
 *    - Flat 1-D uint8 with `@compression == 8`: NAME_TOKENIZED
 *      decode-once-and-cache. The decoded list is materialised on
 *      first call and held for the lifetime of this run instance
 *      per Binding Decision §114. */
- (NSString *)readNameAtIndex:(NSUInteger)index
                         error:(NSError **)error;

/** Reads on `chromosome` whose mapping position is in [start, end). */
- (NSArray<TTIOAlignedRead *> *)readsInRegion:(NSString *)chromosome
                                          start:(int64_t)start
                                            end:(int64_t)end;

/** Open an existing /study/genomic_runs/<name>/ group. The caller
 *  resolves the run group and passes it as `runGroup`. */
+ (instancetype)openFromGroup:(id<TTIOStorageGroup>)runGroup
                          name:(NSString *)name
                         error:(NSError **)error;

@end

#endif
