/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_WRITTEN_SPECTRAL_BATCH_H
#define TTIO_WRITTEN_SPECTRAL_BATCH_H

#import <Foundation/Foundation.h>

@class TTIOSpectrum;

NS_ASSUME_NONNULL_BEGIN

/** A batch of spectra in the on-disk column form: the spectrum_index
 *  columns for the batch and one concatenated float64 buffer per
 *  channel. Element types match the index datasets: offsets uint64,
 *  lengths uint32, retention_times / precursor_mzs /
 *  base_peak_intensities float64, ms_levels / polarities /
 *  precursor_charges int32; the optional M74 columns (activation_methods
 *  int32, isolation_* float64) and centroideds (int32) are nil when the
 *  batch does not carry them. Python: <code>WrittenSpectralBatch</code>;
 *  Java: <code>WrittenSpectralBatch</code>. */
@interface TTIOWrittenSpectralBatch : NSObject

@property (nonatomic, readonly, copy) NSData *offsets;
@property (nonatomic, readonly, copy) NSData *lengths;
@property (nonatomic, readonly, copy) NSData *retentionTimes;
@property (nonatomic, readonly, copy) NSData *msLevels;
@property (nonatomic, readonly, copy) NSData *polarities;
@property (nonatomic, readonly, copy) NSData *precursorMzs;
@property (nonatomic, readonly, copy) NSData *precursorCharges;
@property (nonatomic, readonly, copy) NSData *basePeakIntensities;
@property (nonatomic, readonly, copy, nullable) NSData *activationMethods;
@property (nonatomic, readonly, copy, nullable) NSData *isolationTargetMzs;
@property (nonatomic, readonly, copy, nullable) NSData *isolationLowerOffsets;
@property (nonatomic, readonly, copy, nullable) NSData *isolationUpperOffsets;
@property (nonatomic, readonly, copy, nullable) NSData *centroideds;
/** Channel name to concatenated float64 values. */
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSData *> *channelData;

@property (nonatomic, readonly) NSUInteger spectrumCount;
/** YES when the four M74 activation / isolation columns are present. */
@property (nonatomic, readonly) BOOL hasM74;

- (instancetype)initWithOffsets:(NSData *)offsets
                        lengths:(NSData *)lengths
                 retentionTimes:(NSData *)retentionTimes
                       msLevels:(NSData *)msLevels
                     polarities:(NSData *)polarities
                   precursorMzs:(NSData *)precursorMzs
               precursorCharges:(NSData *)precursorCharges
            basePeakIntensities:(NSData *)basePeakIntensities
              activationMethods:(nullable NSData *)activationMethods
             isolationTargetMzs:(nullable NSData *)isolationTargetMzs
          isolationLowerOffsets:(nullable NSData *)isolationLowerOffsets
          isolationUpperOffsets:(nullable NSData *)isolationUpperOffsets
                    centroideds:(nullable NSData *)centroideds
                    channelData:(NSDictionary<NSString *, NSData *> *)channelData;

/** The batch form of in-memory spectra, columns derived as
 *  TTIOAcquisitionRun's index builder derives them (M74 columns only
 *  when a spectrum carries activation or isolation detail). */
+ (instancetype)batchWithSpectra:(NSArray<TTIOSpectrum *> *)spectra
                    channelNames:(NSArray<NSString *> *)channelNames;

@end

NS_ASSUME_NONNULL_END

#endif
