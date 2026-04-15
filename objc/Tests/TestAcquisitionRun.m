#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Run/MPGOAcquisitionRun.h"
#import "Run/MPGOInstrumentConfig.h"
#import "Run/MPGOSpectrumIndex.h"
#import "Spectra/MPGOMassSpectrum.h"
#import "Core/MPGOSignalArray.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "ValueClasses/MPGOValueRange.h"
#import "ValueClasses/MPGOEnums.h"
#import "HDF5/MPGOHDF5File.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Errors.h"
#import <math.h>
#import <unistd.h>

static NSString *runPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_test_run_%d_%@.mpgo",
            (int)getpid(), suffix];
}

static MPGOSignalArray *float64Array(const double *src, NSUInteger n)
{
    NSData *buf = [NSData dataWithBytes:src length:n * sizeof(double)];
    MPGOEncodingSpec *enc =
        [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat64
                       compressionAlgorithm:MPGOCompressionZlib
                                  byteOrder:MPGOByteOrderLittleEndian];
    return [[MPGOSignalArray alloc] initWithBuffer:buf
                                            length:n
                                          encoding:enc
                                              axis:nil];
}

/** Build spectrum k of a synthetic 1000-spectrum run. */
static MPGOMassSpectrum *makeSpectrum(NSUInteger k)
{
    NSUInteger N = 50 + (k % 7) * 10;   // 50..110 peaks
    double *mz = malloc(N * sizeof(double));
    double *in = malloc(N * sizeof(double));
    for (NSUInteger i = 0; i < N; i++) {
        mz[i] = 100.0 + (double)k * 0.001 + (double)i * 0.5;
        in[i] = (double)(i + 1) + (double)k;
    }
    MPGOSignalArray *mzA = float64Array(mz, N);
    MPGOSignalArray *inA = float64Array(in, N);
    free(mz); free(in);

    NSError *err = nil;
    MPGOMassSpectrum *s =
        [[MPGOMassSpectrum alloc] initWithMzArray:mzA
                                   intensityArray:inA
                                          msLevel:1 + (k % 2)
                                         polarity:(k % 4 == 0 ? MPGOPolarityNegative : MPGOPolarityPositive)
                                       scanWindow:nil
                                    indexPosition:k
                                  scanTimeSeconds:(double)k * 0.5  // 0..500 seconds
                                      precursorMz:0
                                  precursorCharge:0
                                            error:&err];
    return s;
}

void testAcquisitionRun(void)
{
    // ---- MPGOInstrumentConfig round-trip ----
    {
        MPGOInstrumentConfig *cfg =
            [[MPGOInstrumentConfig alloc] initWithManufacturer:@"Thermo"
                                                         model:@"Q Exactive HF"
                                                  serialNumber:@"SN-12345"
                                                    sourceType:@"ESI"
                                                  analyzerType:@"Orbitrap"
                                                  detectorType:@"electron multiplier"];
        NSString *path = runPath(@"cfg");
        NSError *err = nil;
        MPGOHDF5File *f = [MPGOHDF5File createAtPath:path error:&err];
        PASS([cfg writeToGroup:[f rootGroup] error:&err],
             "MPGOInstrumentConfig writes");
        [f close];

        MPGOHDF5File *g = [MPGOHDF5File openReadOnlyAtPath:path error:&err];
        MPGOInstrumentConfig *back =
            [MPGOInstrumentConfig readFromGroup:[g rootGroup] error:&err];
        PASS([back isEqual:cfg], "MPGOInstrumentConfig round-trips");
        PASS([back.model isEqualToString:@"Q Exactive HF"], "model preserved");
        PASS([back.analyzerType isEqualToString:@"Orbitrap"], "analyzerType preserved");
        [g close];
        unlink([path fileSystemRepresentation]);
    }

    // ---- 1000-spectrum AcquisitionRun ----
    NSMutableArray *spectra = [NSMutableArray arrayWithCapacity:1000];
    for (NSUInteger k = 0; k < 1000; k++) {
        [spectra addObject:makeSpectrum(k)];
    }

    MPGOInstrumentConfig *cfg =
        [[MPGOInstrumentConfig alloc] initWithManufacturer:@"Thermo"
                                                     model:@"Q Exactive HF"
                                              serialNumber:@"SN-1"
                                                sourceType:@"ESI"
                                              analyzerType:@"Orbitrap"
                                              detectorType:@"em"];
    MPGOAcquisitionRun *run =
        [[MPGOAcquisitionRun alloc] initWithSpectra:spectra
                                    acquisitionMode:MPGOAcquisitionModeMS1DDA
                                   instrumentConfig:cfg];
    PASS(run.spectrumIndex.count == 1000, "in-memory run reports 1000 spectra in index");
    PASS([run count] == 1000, "MPGOIndexable count is 1000");

    NSString *path = runPath(@"run1000");
    NSError *err = nil;
    MPGOHDF5File *f = [MPGOHDF5File createAtPath:path error:&err];
    NSDate *t0 = [NSDate date];
    PASS([run writeToGroup:[f rootGroup] name:@"run_0001" error:&err],
         "1000-spectrum run writes to HDF5");
    NSTimeInterval writeMs = -[t0 timeIntervalSinceNow] * 1000.0;
    [f close];
    printf("    [bench] 1000-spectrum run write %.0f ms\n", writeMs);

    // ---- random-access read of spectrum 0, 500, 999 ----
    MPGOHDF5File *g = [MPGOHDF5File openReadOnlyAtPath:path error:&err];
    MPGOAcquisitionRun *back =
        [MPGOAcquisitionRun readFromGroup:[g rootGroup] name:@"run_0001" error:&err];
    PASS(back != nil, "1000-spectrum run reads back");
    PASS([back count] == 1000, "loaded run count is 1000");
    PASS(back.acquisitionMode == MPGOAcquisitionModeMS1DDA, "acquisition mode round-trips");
    PASS([back.instrumentConfig isEqual:cfg], "instrument config round-trips");

    NSUInteger picks[] = { 0, 500, 999 };
    for (int p = 0; p < 3; p++) {
        NSUInteger pick = picks[p];
        NSError *e = nil;
        MPGOMassSpectrum *s = [back spectrumAtIndex:pick error:&e];
        PASS(s != nil, "random-access spectrum read");
        MPGOMassSpectrum *expected = spectra[pick];
        PASS(s.mzArray.length == expected.mzArray.length,
             "random-access length matches expected");
        PASS([s.mzArray.buffer isEqualToData:expected.mzArray.buffer],
             "random-access mz bytes match");
        PASS([s.intensityArray.buffer isEqualToData:expected.intensityArray.buffer],
             "random-access intensity bytes match");
        PASS(s.msLevel == expected.msLevel, "random-access msLevel matches");
        PASS(s.scanTimeSeconds == expected.scanTimeSeconds,
             "random-access scanTime matches");
    }

    // ---- RT range query: 10.0..12.0 seconds → spectra with k in 20..24 ----
    {
        MPGOValueRange *r = [MPGOValueRange rangeWithMinimum:10.0 maximum:12.0];
        NSArray *idxs = [back indicesInRetentionTimeRange:r];
        // RT for spectrum k is 0.5 * k, so 10..12 → k in 20..24 inclusive (5 spectra)
        PASS(idxs.count == 5, "RT range 10..12 returns 5 spectra");
        PASS([idxs[0] unsignedIntegerValue] == 20, "first index is 20");
        PASS([[idxs lastObject] unsignedIntegerValue] == 24, "last index is 24");
    }

    // ---- streaming iteration ----
    {
        [back reset];
        NSUInteger seen = 0;
        NSUInteger lastPos = 0;
        while ([back hasMore]) {
            MPGOMassSpectrum *s = [back nextObject];
            if (!s) break;
            if (seen == 0) PASS(s.indexPosition == 0, "stream first spectrum is index 0");
            lastPos = s.indexPosition;
            seen++;
        }
        PASS(seen == 1000, "stream visits all 1000 spectra");
        PASS(lastPos == 999, "stream last spectrum is index 999");
        PASS(![back hasMore], "stream exhausted after 1000");
    }

    // ---- seek + currentPosition ----
    {
        PASS([back seekToPosition:42], "seek to 42 succeeds");
        PASS([back currentPosition] == 42, "currentPosition is 42");
        MPGOMassSpectrum *s = [back nextObject];
        PASS(s.indexPosition == 42, "next after seek returns spectrum 42");
        PASS([back currentPosition] == 43, "position advanced to 43");
        PASS(![back seekToPosition:1001], "seek beyond count rejected");
    }

    // ---- out-of-range index returns nil + NSError ----
    {
        NSError *e = nil;
        MPGOMassSpectrum *s = [back spectrumAtIndex:1500 error:&e];
        PASS(s == nil, "out-of-range index returns nil");
        PASS(e != nil && e.code == MPGOErrorOutOfRange,
             "out-of-range index populates OutOfRange error");
    }

    [g close];
    unlink([path fileSystemRepresentation]);
}
