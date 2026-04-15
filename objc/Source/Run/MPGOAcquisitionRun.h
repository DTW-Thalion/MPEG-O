#ifndef MPGO_ACQUISITION_RUN_H
#define MPGO_ACQUISITION_RUN_H

#import <Foundation/Foundation.h>
#import "Protocols/MPGOIndexable.h"
#import "Protocols/MPGOStreamable.h"
#import "ValueClasses/MPGOEnums.h"

@class MPGOMassSpectrum;
@class MPGOInstrumentConfig;
@class MPGOSpectrumIndex;
@class MPGOHDF5Group;
@class MPGOValueRange;

/**
 * An ordered run of mass spectra sharing an instrument configuration
 * and acquisition mode. Maps to the MPEG-G Dataset concept; each
 * spectrum is an Access Unit.
 *
 * Persistence layout (under the parent group):
 *
 *   <run_name>/
 *     @acquisition_mode           (int attr)
 *     @spectrum_count             (int attr)
 *     instrument_config/          (string attrs)
 *     spectrum_index/             (parallel offset/length/metadata datasets)
 *     signal_channels/
 *       mz_values                 (float64[N_total], chunked, zlib-6)
 *       intensity_values          (float64[N_total], chunked, zlib-6)
 *
 * On read-back the run holds open HDF5 dataset handles to mz_values and
 * intensity_values; -spectrumAtIndex:error: issues hyperslab reads and
 * reconstructs the requested spectrum without touching unrelated chunks.
 *
 * For v0.1 only mass spectra are supported in a run; mixed runs are a
 * planned post-1.0 extension.
 */
@interface MPGOAcquisitionRun : NSObject <MPGOIndexable, MPGOStreamable>

@property (readonly) MPGOAcquisitionMode acquisitionMode;
@property (readonly, strong) MPGOInstrumentConfig *instrumentConfig;
@property (readonly, strong) MPGOSpectrumIndex *spectrumIndex;

#pragma mark - In-memory construction

- (instancetype)initWithSpectra:(NSArray<MPGOMassSpectrum *> *)spectra
                acquisitionMode:(MPGOAcquisitionMode)mode
               instrumentConfig:(MPGOInstrumentConfig *)config;

#pragma mark - HDF5

- (BOOL)writeToGroup:(MPGOHDF5Group *)parent
                name:(NSString *)name
               error:(NSError **)error;

+ (instancetype)readFromGroup:(MPGOHDF5Group *)parent
                         name:(NSString *)name
                        error:(NSError **)error;

#pragma mark - Random access

/**
 * Materialize the spectrum at index. For runs constructed in memory,
 * returns the original instance. For runs read from disk, issues
 * hyperslab reads against mz_values + intensity_values and reconstructs
 * a fresh MPGOMassSpectrum holding only the requested slice.
 */
- (MPGOMassSpectrum *)spectrumAtIndex:(NSUInteger)index error:(NSError **)error;

/** Indices in the given retention-time range, in ascending order. */
- (NSArray<NSNumber *> *)indicesInRetentionTimeRange:(MPGOValueRange *)range;

@end

#endif
