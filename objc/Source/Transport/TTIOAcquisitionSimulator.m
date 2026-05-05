/*
 * TTIOAcquisitionSimulator.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOAcquisitionSimulator
 * Inherits From: NSObject
 * Conforms To:   NSObject (NSObject)
 * Declared In:   Transport/TTIOAcquisitionSimulator.h
 *
 * Synthetic LC-MS acquisition simulator. Produces deterministic
 * (per-seed) StreamHeader → DatasetHeader → AccessUnit{N} →
 * EndOfDataset → EndOfStream sequences into a TTIOTransportWriter.
 * Within-language reproducible; not byte-identical across
 * languages.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "TTIOAcquisitionSimulator.h"
#import "TTIOAccessUnit.h"
#import "ValueClasses/TTIOEnums.h"

#include <stdlib.h>
#include <string.h>
#include <time.h>

// Deterministic RNG: the 48-bit LCG from POSIX (drand48/lrand48) —
// available on Linux/BSD/GNUstep, identical output given the same
// seed. We use srand48_r / erand48_r reentrant variants so a
// simulator instance does not stomp on the process-global state.

@implementation TTIOAcquisitionSimulator
{
    struct drand48_data _rng;
}

- (instancetype)initWithScanRate:(double)scanRate
                          duration:(double)duration
                       ms1Fraction:(double)ms1Fraction
                             mzMin:(double)mzMin
                             mzMax:(double)mzMax
                           nPeaks:(NSUInteger)nPeaks
                             seed:(uint64_t)seed
{
    if ((self = [super init])) {
        _scanRate = scanRate;
        _duration = duration;
        _ms1Fraction = ms1Fraction;
        _mzMin = mzMin;
        _mzMax = mzMax;
        _nPeaks = nPeaks;
        _seed = seed;
    }
    return self;
}

- (instancetype)initWithSeed:(uint64_t)seed
{
    return [self initWithScanRate:10.0
                          duration:10.0
                       ms1Fraction:0.3
                             mzMin:100.0
                             mzMax:2000.0
                           nPeaks:200
                             seed:seed];
}

- (NSUInteger)scanCount
{
    NSInteger n = (NSInteger)(_scanRate * _duration);
    return (NSUInteger)MAX((NSInteger)1, n);
}

// ---------------------------------------------------------------- internals

- (double)_uniform:(double)lo hi:(double)hi
{
    double x;
    drand48_r(&_rng, &x);
    return lo + x * (hi - lo);
}

- (NSInteger)_randInt:(NSInteger)range
{
    long v;
    lrand48_r(&_rng, &v);
    return range > 0 ? (NSInteger)(v % range) : 0;
}

static int cmpDouble(const void *a, const void *b)
{
    double da = *(const double *)a, db = *(const double *)b;
    return (da > db) - (da < db);
}

static NSData *packF64(const double *arr, NSUInteger n)
{
    NSMutableData *d = [NSMutableData dataWithCapacity:n * 8];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&arr[i] length:8];
    return d;
}

- (TTIOAccessUnit *)_generateAUForIndex:(NSUInteger)i
                            lastMs1Peak:(double *)lastMs1PeakInOut
{
    double rt = (double)i * (1.0 / _scanRate);
    double coin;
    drand48_r(&_rng, &coin);
    BOOL isMs1 = (coin < _ms1Fraction);
    uint8_t msLevel = isMs1 ? 1 : 2;

    NSInteger jitterRange = (NSInteger)(_nPeaks / 2 + 1);
    NSInteger jitter = [self _randInt:jitterRange] - (NSInteger)(_nPeaks / 4);
    NSInteger n = MAX((NSInteger)1, (NSInteger)_nPeaks + jitter);

    double *mzs = calloc((size_t)n, sizeof(double));
    double *intensities = calloc((size_t)n, sizeof(double));
    for (NSInteger k = 0; k < n; k++) {
        mzs[k] = [self _uniform:_mzMin hi:_mzMax];
    }
    qsort(mzs, (size_t)n, sizeof(double), cmpDouble);
    for (NSInteger k = 0; k < n; k++) {
        intensities[k] = [self _uniform:10.0 hi:1.0e6];
    }

    double basePeakIntensity = 0.0;
    NSInteger basePeakIndex = 0;
    for (NSInteger k = 0; k < n; k++) {
        if (intensities[k] > basePeakIntensity) {
            basePeakIntensity = intensities[k];
            basePeakIndex = k;
        }
    }

    double precursorMz = 0.0;
    uint8_t precursorCharge = 0;
    if (isMs1) {
        *lastMs1PeakInOut = mzs[basePeakIndex];
    } else {
        precursorMz = (*lastMs1PeakInOut > 0)
            ? *lastMs1PeakInOut : [self _uniform:_mzMin hi:_mzMax];
        long c;
        lrand48_r(&_rng, &c);
        precursorCharge = (c % 2 == 0) ? 2 : 3;
    }

    NSData *mzData = packF64(mzs, (NSUInteger)n);
    NSData *intData = packF64(intensities, (NSUInteger)n);
    free(mzs); free(intensities);

    TTIOTransportChannelData *chMz =
        [[TTIOTransportChannelData alloc]
            initWithName:@"mz"
               precision:TTIOPrecisionFloat64
             compression:TTIOCompressionNone
               nElements:(uint32_t)n
                    data:mzData];
    TTIOTransportChannelData *chInt =
        [[TTIOTransportChannelData alloc]
            initWithName:@"intensity"
               precision:TTIOPrecisionFloat64
             compression:TTIOCompressionNone
               nElements:(uint32_t)n
                    data:intData];

    return [[TTIOAccessUnit alloc]
               initWithSpectrumClass:0
                     acquisitionMode:(uint8_t)TTIOAcquisitionModeMS1DDA
                             msLevel:msLevel
                            polarity:0
                       retentionTime:rt
                         precursorMz:precursorMz
                     precursorCharge:precursorCharge
                         ionMobility:0.0
                   basePeakIntensity:basePeakIntensity
                            channels:@[chMz, chInt]
                              pixelX:0 pixelY:0 pixelZ:0];
}

- (void)_seedRNG
{
    memset(&_rng, 0, sizeof(_rng));
    // srand48_r takes long; pack our 64-bit seed in a way that
    // preserves determinism within the language. Any deterministic
    // mapping is fine since cross-language byte-identity is not a
    // goal (documented in the header).
    long packed = (long)(_seed ^ (_seed >> 32));
    srand48_r(packed, &_rng);
}

// ---------------------------------------------------------------- public

static NSString *const kInstrumentJSON =
    @"{\"analyzer_type\": \"\", \"detector_type\": \"\", "
    @"\"manufacturer\": \"TTI-O simulator\", \"model\": \"synthetic-v1\", "
    @"\"serial_number\": \"\", \"source_type\": \"\"}";

- (NSUInteger)streamToWriter:(TTIOTransportWriter *)writer
                        error:(NSError **)error
{
    [self _seedRNG];
    NSUInteger count = [self scanCount];
    if (![writer writeStreamHeaderWithFormatVersion:@"1.2"
                                               title:@"Simulated acquisition"
                                    isaInvestigation:@"ISA-SIMULATOR"
                                            features:@[@"base_v1"]
                                           nDatasets:1
                                               error:error]) return 0;
    if (![writer writeDatasetHeaderWithDatasetId:1
                                             name:@"simulated_run"
                                  acquisitionMode:(uint8_t)TTIOAcquisitionModeMS1DDA
                                    spectrumClass:@"TTIOMassSpectrum"
                                     channelNames:@[@"mz", @"intensity"]
                                   instrumentJSON:kInstrumentJSON
                                 expectedAUCount:(uint32_t)count
                                            error:error]) return 0;

    double lastMs1Peak = 0.0;
    for (NSUInteger i = 0; i < count; i++) {
        TTIOAccessUnit *au = [self _generateAUForIndex:i lastMs1Peak:&lastMs1Peak];
        if (![writer writeAccessUnit:au datasetId:1 auSequence:(uint32_t)i error:error])
            return 0;
    }

    if (![writer writeEndOfDatasetWithDatasetId:1
                                 finalAUSequence:(uint32_t)count
                                            error:error]) return 0;
    if (![writer writeEndOfStreamWithError:error]) return 0;
    return count;
}

- (NSUInteger)streamPacedToWriter:(TTIOTransportWriter *)writer
                             error:(NSError **)error
{
    [self _seedRNG];
    NSUInteger count = [self scanCount];
    if (![writer writeStreamHeaderWithFormatVersion:@"1.2"
                                               title:@"Simulated acquisition"
                                    isaInvestigation:@"ISA-SIMULATOR"
                                            features:@[@"base_v1"]
                                           nDatasets:1
                                               error:error]) return 0;
    if (![writer writeDatasetHeaderWithDatasetId:1
                                             name:@"simulated_run"
                                  acquisitionMode:(uint8_t)TTIOAcquisitionModeMS1DDA
                                    spectrumClass:@"TTIOMassSpectrum"
                                     channelNames:@[@"mz", @"intensity"]
                                   instrumentJSON:kInstrumentJSON
                                 expectedAUCount:0
                                            error:error]) return 0;

    struct timespec start;
    clock_gettime(CLOCK_MONOTONIC, &start);
    double intervalNs = 1.0e9 / _scanRate;

    double lastMs1Peak = 0.0;
    for (NSUInteger i = 0; i < count; i++) {
        TTIOAccessUnit *au = [self _generateAUForIndex:i lastMs1Peak:&lastMs1Peak];
        if (![writer writeAccessUnit:au datasetId:1 auSequence:(uint32_t)i error:error])
            return 0;

        double targetNs = (double)(i + 1) * intervalNs;
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        double elapsedNs = (double)(now.tv_sec - start.tv_sec) * 1.0e9
                         + (double)(now.tv_nsec - start.tv_nsec);
        double delayNs = targetNs - elapsedNs;
        if (delayNs > 0) {
            struct timespec sleep;
            sleep.tv_sec = (time_t)(delayNs / 1.0e9);
            sleep.tv_nsec = (long)(delayNs - (double)sleep.tv_sec * 1.0e9);
            nanosleep(&sleep, NULL);
        }
    }

    if (![writer writeEndOfDatasetWithDatasetId:1
                                 finalAUSequence:(uint32_t)count
                                            error:error]) return 0;
    if (![writer writeEndOfStreamWithError:error]) return 0;
    return count;
}

@end
