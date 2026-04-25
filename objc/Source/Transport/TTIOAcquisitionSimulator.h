/*
 * TTIOAcquisitionSimulator — v0.10 M69.
 *
 * Synthetic LC-MS acquisition simulator. Produces transport packets
 * into an TTIOTransportWriter. Deterministic under a fixed seed;
 * byte-identity across languages is NOT guaranteed (each language
 * uses its own RNG). Use for within-language reproducibility.
 *
 * Cross-language equivalents:
 *   Python: ttio.transport.simulator.AcquisitionSimulator
 *   Java:   com.dtwthalion.tio.transport.AcquisitionSimulator
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_ACQUISITION_SIMULATOR_H
#define TTIO_ACQUISITION_SIMULATOR_H

#import <Foundation/Foundation.h>
#import "TTIOTransportWriter.h"

NS_ASSUME_NONNULL_BEGIN

@interface TTIOAcquisitionSimulator : NSObject

/** Scans per second. Default: 10.0. */
@property (nonatomic, readonly) double scanRate;

/** Total acquisition duration in seconds. Default: 10.0. */
@property (nonatomic, readonly) double duration;

/** Probability a scan is MS1. Default: 0.3. */
@property (nonatomic, readonly) double ms1Fraction;

/** Inclusive m/z range used for peak generation. */
@property (nonatomic, readonly) double mzMin;
@property (nonatomic, readonly) double mzMax;

/** Mean peaks per spectrum (actual count jitters ±25%). */
@property (nonatomic, readonly) NSUInteger nPeaks;

/** Seed for deterministic runs. */
@property (nonatomic, readonly) uint64_t seed;

- (instancetype)initWithScanRate:(double)scanRate
                          duration:(double)duration
                       ms1Fraction:(double)ms1Fraction
                             mzMin:(double)mzMin
                             mzMax:(double)mzMax
                           nPeaks:(NSUInteger)nPeaks
                             seed:(uint64_t)seed;

/** Convenience initialiser with defaults matching the Python / Java
 *  reference simulators (10 Hz, 10 s, ms1_fraction=0.3, mz [100..2000],
 *  200 peaks/spectrum). */
- (instancetype)initWithSeed:(uint64_t)seed;

/** Total AU count for the configured duration. */
- (NSUInteger)scanCount;

/** Emit StreamHeader → DatasetHeader → N AccessUnits → EndOfDataset
 *  → EndOfStream to ``writer``. No wall-clock pacing. Returns AU
 *  count. */
- (NSUInteger)streamToWriter:(TTIOTransportWriter *)writer
                        error:(NSError * _Nullable *)error;

/** Same as streamToWriter but paced: sleeps between scans so the
 *  run consumes roughly ``duration`` seconds of wall-clock time.
 *  Blocks the calling thread. */
- (NSUInteger)streamPacedToWriter:(TTIOTransportWriter *)writer
                             error:(NSError * _Nullable *)error;

@end

NS_ASSUME_NONNULL_END

#endif
