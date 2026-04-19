/*
 * MPGOWrittenRun — flat-buffer value object for
 * +[MPGOSpectralDataset writeMinimalToPath:...].
 *
 * Mirrors the Python `mpeg_o.spectral_dataset.WrittenRun` dataclass.
 * The high-level MPGOAcquisitionRun / MPGOMassSpectrum API requires
 * one NSData per spectrum per channel; at write time the writer
 * iterates every spectrum and memcpy-concatenates the per-spectrum
 * buffers into a flat channel. Callers with already-flat arrays can
 * skip both costs by building an MPGOWrittenRun and calling
 * +writeMinimalToPath: on MPGOSpectralDataset.
 *
 * All buffer fields must be little-endian and typed as documented
 * below. No validation beyond length; the writer trusts the caller.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef MPGO_WRITTEN_RUN_H
#define MPGO_WRITTEN_RUN_H

#import <Foundation/Foundation.h>
#import "ValueClasses/MPGOEnums.h"

NS_ASSUME_NONNULL_BEGIN

@interface MPGOWrittenRun : NSObject

/** "MPGOMassSpectrum" or "MPGONMRSpectrum". */
@property (nonatomic, copy, readonly) NSString *spectrumClassName;

/** AcquisitionMode raw int; see MPGOAcquisitionMode. */
@property (nonatomic, readonly) int64_t acquisitionMode;

/** Flat per-channel signal buffers, keyed by channel name. Each value
 *  is an NSData of float64 little-endian, already concatenated across
 *  spectra in index order. */
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSData *> *channelData;

// All index arrays are parallel with length = spectrumCount.
@property (nonatomic, copy, readonly) NSData *offsets;               // int64 LE
@property (nonatomic, copy, readonly) NSData *lengths;               // uint32 LE
@property (nonatomic, copy, readonly) NSData *retentionTimes;        // float64 LE
@property (nonatomic, copy, readonly) NSData *msLevels;              // int32 LE
@property (nonatomic, copy, readonly) NSData *polarities;            // int32 LE
@property (nonatomic, copy, readonly) NSData *precursorMzs;          // float64 LE
@property (nonatomic, copy, readonly) NSData *precursorCharges;      // int32 LE
@property (nonatomic, copy, readonly) NSData *basePeakIntensities;   // float64 LE

/** Optional — NMR runs set this; MS runs leave empty. */
@property (nonatomic, copy) NSString *nucleusType;

/** v0.3 M21. "gzip", "none", "lz4", or "numpress_delta". Defaults to "gzip". */
@property (nonatomic, copy) NSString *signalCompression;

- (instancetype)initWithSpectrumClassName:(NSString *)spectrumClassName
                          acquisitionMode:(int64_t)acquisitionMode
                              channelData:(NSDictionary<NSString *, NSData *> *)channelData
                                  offsets:(NSData *)offsets
                                  lengths:(NSData *)lengths
                           retentionTimes:(NSData *)retentionTimes
                                 msLevels:(NSData *)msLevels
                               polarities:(NSData *)polarities
                             precursorMzs:(NSData *)precursorMzs
                         precursorCharges:(NSData *)precursorCharges
                      basePeakIntensities:(NSData *)basePeakIntensities;

@end

NS_ASSUME_NONNULL_END

#endif
