#ifndef MPGO_SPECTRUM_INDEX_H
#define MPGO_SPECTRUM_INDEX_H

#import <Foundation/Foundation.h>
#import "ValueClasses/MPGOEnums.h"

@class MPGOValueRange;
@class MPGOHDF5Group;

/**
 * Per-spectrum offsets, lengths, and queryable scan metadata for one
 * MPGOAcquisitionRun. Kept as parallel C arrays inside NSData buffers
 * for compact storage and fast iteration. Persisted as five parallel
 * 1-D HDF5 datasets under the run's `spectrum_index/` sub-group plus
 * a sixth one for precursor charge.
 *
 * Range queries (RT, ms_level, polarity) operate on the in-memory
 * arrays and do not touch the signal channels — this is the
 * "compressed-domain query" property of the MPEG-G access-unit model.
 */
@interface MPGOSpectrumIndex : NSObject

@property (readonly) NSUInteger count;

/** offsets[i] is the starting element index of spectrum i in mz_values. */
- (uint64_t)offsetAt:(NSUInteger)index;
/** lengths[i] is the number of elements (peaks) in spectrum i. */
- (uint32_t)lengthAt:(NSUInteger)index;

- (double)retentionTimeAt:(NSUInteger)index;
- (uint8_t)msLevelAt:(NSUInteger)index;
- (MPGOPolarity)polarityAt:(NSUInteger)index;
- (double)precursorMzAt:(NSUInteger)index;
- (uint8_t)precursorChargeAt:(NSUInteger)index;

/** Indices whose retention time falls within [range.minimum, range.maximum]. */
- (NSIndexSet *)indicesInRetentionTimeRange:(MPGOValueRange *)range;
- (NSIndexSet *)indicesForMsLevel:(uint8_t)msLevel;

#pragma mark - Construction

- (instancetype)initWithOffsets:(NSData *)offsets
                        lengths:(NSData *)lengths
                 retentionTimes:(NSData *)retentionTimes
                       msLevels:(NSData *)msLevels
                     polarities:(NSData *)polarities
                   precursorMzs:(NSData *)precursorMzs
               precursorCharges:(NSData *)precursorCharges;

#pragma mark - HDF5

- (BOOL)writeToGroup:(MPGOHDF5Group *)parent error:(NSError **)error;
+ (instancetype)readFromGroup:(MPGOHDF5Group *)parent error:(NSError **)error;

@end

#endif
