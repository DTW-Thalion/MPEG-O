// TestFloatDeltaZstd.m
//
// FLOAT_DELTA_ZSTD (codec id 17) — round-trips and the shared golden
// decode fixture (the cross-language contract per the spec's Option
// B). Python: test_float_delta_zstd.py; Java: FloatDeltaZstdTest.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Codecs/TTIOFloatDeltaZstd.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOInstrumentConfig.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "ValueClasses/TTIOEncodingSpec.h"

#include <math.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

static NSData *doublesData(const double *v, NSUInteger n)
{
    return [NSData dataWithBytes:v length:n * sizeof(double)];
}

static BOOL bitExact(NSData *a, NSData *b)
{
    return a.length == b.length
        && memcmp(a.bytes, b.bytes, a.length) == 0;
}

static BOOL roundTrips(NSData *values)
{
    NSData *enc = [TTIOFloatDeltaZstd encodeFloat64:values];
    if (!enc) return NO;
    NSError *err = nil;
    NSData *dec = [TTIOFloatDeltaZstd decodeStream:enc error:&err];
    return dec != nil && bitExact(dec, values);
}

// Same generator constants as Python golden_values() / Java
// FloatDeltaZstdTest.goldenValues().
static NSData *goldenValues(void)
{
    const NSUInteger n = 4096;
    NSMutableData *d = [NSMutableData dataWithLength:(2 * n + 6) * sizeof(double)];
    double *out = d.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) out[i] = 100.0 + 0.25 * (double)i;
    uint64_t x = 88172645463325252ull;
    uint64_t *bits = (uint64_t *)d.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) {   // xorshift64
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        bits[n + i] = x;
    }
    out[2 * n + 0] = 0.0;
    out[2 * n + 1] = -0.0;
    out[2 * n + 2] = INFINITY;
    out[2 * n + 3] = -INFINITY;
    out[2 * n + 4] = NAN;
    out[2 * n + 5] = 5e-324;
    return d;
}

static NSString *fdzFixturePath(void)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *here = [fm currentDirectoryPath];
    for (int up = 0; up < 6; up++) {
        NSString *c1 = [[here stringByAppendingPathComponent:@"Tests"]
                stringByAppendingPathComponent:@"Fixtures/float_delta_zstd_golden.bin"];
        if ([fm fileExistsAtPath:c1]) return c1;
        NSString *c2 = [[[here stringByAppendingPathComponent:@"objc"]
                stringByAppendingPathComponent:@"Tests"]
                stringByAppendingPathComponent:@"Fixtures/float_delta_zstd_golden.bin"];
        if ([fm fileExistsAtPath:c2]) return c2;
        here = [here stringByDeletingLastPathComponent];
    }
    return nil;
}

void testFloatDeltaZstd(void)
{
    // ── Round trips over the edge-case battery ─────────────────────
    PASS(roundTrips([NSData data]), "round trip: empty");
    double single[] = { 3.14159 };
    PASS(roundTrips(doublesData(single, 1)), "round trip: single value");

    NSMutableData *ident = [NSMutableData dataWithLength:10000 * sizeof(double)];
    double *ip = ident.mutableBytes;
    for (int i = 0; i < 10000; i++) ip[i] = 7.5;
    PASS(roundTrips(ident), "round trip: all-identical");

    NSMutableData *grid = [NSMutableData dataWithLength:50000 * sizeof(double)];
    double *gp = grid.mutableBytes;
    for (int i = 0; i < 50000; i++) gp[i] = 100.0 + 0.038 * i;
    PASS(roundTrips(grid), "round trip: monotone grid");

    NSMutableData *noise = [NSMutableData dataWithLength:50000 * sizeof(double)];
    uint64_t *np_ = noise.mutableBytes;
    uint64_t x = 12345;
    for (int i = 0; i < 50000; i++) {
        x ^= x << 13; x ^= x >> 7; x ^= x << 17;
        np_[i] = x;
    }
    PASS(roundTrips(noise), "round trip: random bit patterns (NaN payloads)");

    double specials[] = { 0.0, -0.0, INFINITY, -INFINITY, NAN,
                          1.7976931348623157e308, 5e-324, -5e-324 };
    PASS(roundTrips(doublesData(specials, 8)), "round trip: specials");

    // ── Selector uses both transforms ──────────────────────────────
    NSData *encGrid = [TTIOFloatDeltaZstd encodeFloat64:grid];
    NSData *encNoise = [TTIOFloatDeltaZstd encodeFloat64:noise];
    PASS(((const uint8_t *)encGrid.bytes)[22] == 0x01,
         "monotone grid picks the delta transform");
    PASS(((const uint8_t *)encNoise.bytes)[22] == 0x00,
         "noise picks the none transform");

    // ── Malformed streams ──────────────────────────────────────────
    NSError *err = nil;
    PASS([TTIOFloatDeltaZstd decodeStream:[NSMutableData dataWithLength:22]
                                    error:&err] == nil,
         "bad magic is rejected");
    NSData *encS = [TTIOFloatDeltaZstd encodeFloat64:doublesData(specials, 8)];
    err = nil;
    PASS([TTIOFloatDeltaZstd decodeStream:
              [encS subdataWithRange:NSMakeRange(0, encS.length - 3)]
                                    error:&err] == nil,
         "truncated stream is rejected");

    // ── End-to-end .tio dispatch: write + reopen + slice ───────────
    {
        NSUInteger nSpec = 6, nPts = 24;
        NSMutableArray *spectra = [NSMutableArray array];
        TTIOEncodingSpec *enc2 =
            [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                           compressionAlgorithm:TTIOCompressionZlib
                                      byteOrder:TTIOByteOrderLittleEndian];
        for (NSUInteger k = 0; k < nSpec; k++) {
            double mzv[24], inv[24];
            for (NSUInteger i = 0; i < nPts; i++) {
                mzv[i] = 100.0 + (double)(k * nPts + i) * 0.25;
                inv[i] = (double)(k * 100 + i) + 0.5;
            }
            TTIOSignalArray *mzA = [[TTIOSignalArray alloc]
                initWithBuffer:[NSData dataWithBytes:mzv length:nPts * sizeof(double)]
                        length:nPts encoding:enc2 axis:nil];
            TTIOSignalArray *inA = [[TTIOSignalArray alloc]
                initWithBuffer:[NSData dataWithBytes:inv length:nPts * sizeof(double)]
                        length:nPts encoding:enc2 axis:nil];
            [spectra addObject:[[TTIOMassSpectrum alloc]
                initWithMzArray:mzA
                 intensityArray:inA
                        msLevel:1
                       polarity:TTIOPolarityPositive
                     scanWindow:nil
                  indexPosition:k
                scanTimeSeconds:(double)k
                    precursorMz:0
                precursorCharge:0
                          error:NULL]];
        }
        TTIOInstrumentConfig *cfg2 =
            [[TTIOInstrumentConfig alloc] initWithManufacturer:@""
                                                         model:@""
                                                  serialNumber:@""
                                                    sourceType:@""
                                                  analyzerType:@""
                                                  detectorType:@""];
        TTIOAcquisitionRun *run =
            [[TTIOAcquisitionRun alloc] initWithSpectra:spectra
                                        acquisitionMode:TTIOAcquisitionModeMS1DDA
                                       instrumentConfig:cfg2];
        run.signalCompression = TTIOCompressionFloatDeltaZstd;
        TTIOSpectralDataset *ds = [[TTIOSpectralDataset alloc]
            initWithTitle:@"fdz" isaInvestigationId:@""
                   msRuns:@{@"run_0001": run} nmrRuns:@{}
          identifications:@[] quantifications:@[]
        provenanceRecords:@[] transitions:nil];
        NSString *tioPath = [NSString stringWithFormat:
            @"/tmp/ttio_test_fdz_%d.tio", (int)getpid()];
        unlink([tioPath fileSystemRepresentation]);
        NSError *werr = nil;
        PASS([ds writeToFilePath:tioPath error:&werr],
             "codec-17 dataset writes");
        NSError *rerr = nil;
        TTIOSpectralDataset *round =
            [TTIOSpectralDataset readFromFilePath:tioPath error:&rerr];
        PASS(round != nil, "codec-17 dataset reopens");
        if (round) {
            TTIOAcquisitionRun *rr = round.msRuns[@"run_0001"];
            PASS(rr.signalCompression == TTIOCompressionFloatDeltaZstd,
                 "reader reports the FLOAT_DELTA_ZSTD codec");
            NSError *serr = nil;
            TTIOMassSpectrum *s2 = (TTIOMassSpectrum *)
                [rr spectrumAtIndex:2 error:&serr];
            PASS(s2 != nil, "codec-17 spectrum materialises");
            if (s2) {
                const double *mzp = s2.mzArray.buffer.bytes;
                PASS(mzp[0] == 100.0 + (2.0 * 24.0) * 0.25
                     && mzp[23] == 100.0 + (2.0 * 24.0 + 23.0) * 0.25,
                     "codec-17 slices are bit-exact");
            }
        }
        unlink([tioPath fileSystemRepresentation]);
    }

    // ── Golden fixture — the cross-language decode contract ────────
    NSString *path = fdzFixturePath();
    PASS(path != nil, "golden fixture located");
    if (path) {
        NSData *stream = [NSData dataWithContentsOfFile:path];
        err = nil;
        NSData *dec = [TTIOFloatDeltaZstd decodeStream:stream error:&err];
        PASS(dec != nil && bitExact(dec, goldenValues()),
             "golden stream decodes bit-exactly");
    }
}
