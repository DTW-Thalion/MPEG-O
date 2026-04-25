#ifndef TTIO_SPECTRUM_INDEX_H
#define TTIO_SPECTRUM_INDEX_H

#import <Foundation/Foundation.h>
#import "ValueClasses/TTIOEnums.h"

@class TTIOValueRange;
@class TTIOHDF5Group;
@class TTIOIsolationWindow;

/**
 * Per-spectrum offsets, lengths, and queryable scan metadata for one
 * TTIOAcquisitionRun. Kept as parallel C arrays inside NSData buffers
 * for compact storage and fast iteration. Persisted as five parallel
 * 1-D HDF5 datasets under the run's `spectrum_index/` sub-group plus
 * a sixth one for precursor charge.
 *
 * Range queries (RT, ms_level, polarity) operate on the in-memory
 * arrays and do not touch the signal channels — this is the
 * "compressed-domain query" property of the MPEG-G access-unit model.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: ttio.acquisition_run.SpectrumIndex
 *   Java:   com.dtwthalion.tio.SpectrumIndex
 */
@interface TTIOSpectrumIndex : NSObject

@property (readonly) NSUInteger count;

/** offsets[i] is the starting element index of spectrum i in mz_values. */
- (uint64_t)offsetAt:(NSUInteger)index;
/** lengths[i] is the number of elements (peaks) in spectrum i. */
- (uint32_t)lengthAt:(NSUInteger)index;

- (double)retentionTimeAt:(NSUInteger)index;
- (uint8_t)msLevelAt:(NSUInteger)index;
- (TTIOPolarity)polarityAt:(NSUInteger)index;
- (double)precursorMzAt:(NSUInteger)index;
- (uint8_t)precursorChargeAt:(NSUInteger)index;
- (double)basePeakIntensityAt:(NSUInteger)index;

/** (M74) Activation method for spectrum `index`. Returns
 *  `TTIOActivationMethodNone` when the file was written without the
 *  `opt_ms2_activation_detail` feature flag (M74 columns absent). */
- (TTIOActivationMethod)activationMethodAt:(NSUInteger)index;

/** (M74) Isolation window for spectrum `index`, or `nil` when the
 *  M74 columns are absent or the stored target+offsets are all zero
 *  (MS1 sentinel). */
- (TTIOIsolationWindow *)isolationWindowAt:(NSUInteger)index;

/** (M74) YES when all four optional parallel columns are present. */
@property (readonly) BOOL hasActivationDetail;

/** Indices whose retention time falls within [range.minimum, range.maximum]. */
- (NSIndexSet *)indicesInRetentionTimeRange:(TTIOValueRange *)range;
- (NSIndexSet *)indicesForMsLevel:(uint8_t)msLevel;

#pragma mark - Construction

/** Pre-M74 initializer; delegates to the full form with nil M74 columns. */
- (instancetype)initWithOffsets:(NSData *)offsets
                        lengths:(NSData *)lengths
                 retentionTimes:(NSData *)retentionTimes
                       msLevels:(NSData *)msLevels
                     polarities:(NSData *)polarities
                   precursorMzs:(NSData *)precursorMzs
               precursorCharges:(NSData *)precursorCharges
             basePeakIntensities:(NSData *)basePeakIntensities;

/** (M74) Designated initializer. The four trailing `NSData *` arguments
 *  must all be nil (legacy file) or all non-nil (M74 columns present
 *  — writer emits them when the `opt_ms2_activation_detail` flag is
 *  set by the author). Mixed nil/non-nil is rejected. */
- (instancetype)initWithOffsets:(NSData *)offsets
                        lengths:(NSData *)lengths
                 retentionTimes:(NSData *)retentionTimes
                       msLevels:(NSData *)msLevels
                     polarities:(NSData *)polarities
                   precursorMzs:(NSData *)precursorMzs
               precursorCharges:(NSData *)precursorCharges
             basePeakIntensities:(NSData *)basePeakIntensities
               activationMethods:(NSData *)activationMethods
             isolationTargetMzs:(NSData *)isolationTargetMzs
          isolationLowerOffsets:(NSData *)isolationLowerOffsets
          isolationUpperOffsets:(NSData *)isolationUpperOffsets;

#pragma mark - HDF5

- (BOOL)writeToGroup:(TTIOHDF5Group *)parent error:(NSError **)error;
+ (instancetype)readFromGroup:(TTIOHDF5Group *)parent error:(NSError **)error;

/** v0.9 M64.5-objc-java: storage-protocol read for cross-provider support. */
+ (instancetype)readFromStorageGroup:(id)parent error:(NSError **)error;

@end

#endif
