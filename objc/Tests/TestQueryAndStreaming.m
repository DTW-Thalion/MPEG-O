#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Query/MPGOQuery.h"
#import "Query/MPGOStreamWriter.h"
#import "Query/MPGOStreamReader.h"
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
#import <sys/stat.h>

static NSString *qpath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_test_q_%d_%@.mpgo",
            (int)getpid(), suffix];
}

static MPGOSignalArray *qf64(const double *src, NSUInteger n)
{
    NSData *buf = [NSData dataWithBytes:src length:n * sizeof(double)];
    MPGOEncodingSpec *enc =
        [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat64
                       compressionAlgorithm:MPGOCompressionZlib
                                  byteOrder:MPGOByteOrderLittleEndian];
    return [[MPGOSignalArray alloc] initWithBuffer:buf length:n encoding:enc axis:nil];
}

/** k-th spectrum of a 10k synthetic LC-MS run. */
static MPGOMassSpectrum *bigSpectrum(NSUInteger k)
{
    const NSUInteger N = 8;
    double mz[8], in[8];
    double basePeakIntensity = 1.0e3 + (double)(k % 7) * 1.0e3; // 1k..7k
    for (NSUInteger i = 0; i < N; i++) {
        mz[i] = 100.0 + (double)i * 0.5 + (double)(k % 17) * 0.001;
        in[i] = (i == N/2) ? basePeakIntensity : (double)(i + 1);
    }
    NSError *err = nil;
    return [[MPGOMassSpectrum alloc] initWithMzArray:qf64(mz, N)
                                       intensityArray:qf64(in, N)
                                              msLevel:(k % 3 == 0 ? 1 : 2)  // 1/3 are MS1, 2/3 are MS2
                                             polarity:MPGOPolarityPositive
                                           scanWindow:nil
                                        indexPosition:k
                                      // RT = k * 0.06 → 10000 spectra cover 0..600 seconds
                                      scanTimeSeconds:(double)k * 0.06
                                          precursorMz:(k % 3 == 0 ? 0.0 : 500.0 + (double)(k % 50))
                                      precursorCharge:(k % 3 == 0 ? 0 : 2)
                                                error:&err];
}

void testQueryAndStreaming(void)
{
    // ---- 10,000-spectrum query benchmark ----
    {
        NSMutableArray *spectra = [NSMutableArray arrayWithCapacity:10000];
        for (NSUInteger k = 0; k < 10000; k++) [spectra addObject:bigSpectrum(k)];
        MPGOInstrumentConfig *cfg =
            [[MPGOInstrumentConfig alloc] initWithManufacturer:@"Thermo"
                                                         model:@"QE"
                                                  serialNumber:@"S"
                                                    sourceType:@"ESI"
                                                  analyzerType:@"Orbitrap"
                                                  detectorType:@"em"];
        MPGOAcquisitionRun *run =
            [[MPGOAcquisitionRun alloc] initWithSpectra:spectra
                                        acquisitionMode:MPGOAcquisitionModeMS2DDA
                                       instrumentConfig:cfg];
        PASS([run count] == 10000, "10000-spectrum run constructed in memory");

        // Persist + reload so the query exercises the on-disk index path
        // (matches the workplan's "compressed-domain query" intent).
        NSString *path = qpath(@"q10k");
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        MPGOHDF5File *f = [MPGOHDF5File createAtPath:path error:&err];
        PASS([run writeToGroup:[f rootGroup] name:@"r" error:&err], "10k run writes");
        [f close];

        MPGOHDF5File *g = [MPGOHDF5File openReadOnlyAtPath:path error:&err];
        MPGOAcquisitionRun *back =
            [MPGOAcquisitionRun readFromGroup:[g rootGroup] name:@"r" error:&err];
        PASS(back.spectrumIndex.count == 10000, "10k index loaded");

        // Run the query: MS2, RT in [10, 12] seconds, precursor in [500, 550]
        // RT 10..12 → k in 167..200 inclusive (k * 0.06 in [10.02, 12.0] → k 167..200)
        NSDate *t0 = [NSDate date];
        NSIndexSet *hits =
            [[[[MPGOQuery queryOnIndex:back.spectrumIndex]
                withMsLevel:2]
                withRetentionTimeRange:[MPGOValueRange rangeWithMinimum:10.0 maximum:12.0]]
                withPrecursorMzRange:[MPGOValueRange rangeWithMinimum:500.0 maximum:550.0]]
                .matchingIndices;
        NSTimeInterval scanMs = -[t0 timeIntervalSinceNow] * 1000.0;
        printf("    [bench] 10k-spectrum query scan %.2f ms (%lu hits)\n",
               scanMs, (unsigned long)hits.count);

        PASS(hits.count > 0, "query returns at least one hit");
        // Verify every returned index actually satisfies all predicates.
        BOOL ok = YES;
        NSUInteger idx = [hits firstIndex];
        while (idx != NSNotFound) {
            uint8_t ml = [back.spectrumIndex msLevelAt:idx];
            double rt  = [back.spectrumIndex retentionTimeAt:idx];
            double pmz = [back.spectrumIndex precursorMzAt:idx];
            if (ml != 2 || rt < 10.0 || rt > 12.0 || pmz < 500.0 || pmz > 550.0) ok = NO;
            idx = [hits indexGreaterThanIndex:idx];
        }
        PASS(ok, "every hit satisfies MS2 ∧ RT∈[10,12] ∧ precursor∈[500,550]");
        PASS(scanMs < 50.0, "10k-spectrum header scan < 50 ms");

        // Single-predicate variants
        NSIndexSet *justMS1 =
            [[MPGOQuery queryOnIndex:back.spectrumIndex] withMsLevel:1].matchingIndices;
        // 1/3 of 10000 should be MS1 (k % 3 == 0): floor(10000/3)+1 = 3334
        PASS(justMS1.count == 3334, "MS1 filter returns 3334 spectra");

        NSIndexSet *byBasePeak =
            [[MPGOQuery queryOnIndex:back.spectrumIndex]
                withBasePeakIntensityAtLeast:5000.0].matchingIndices;
        PASS(byBasePeak.count > 0, "base-peak filter returns hits");
        // Verify the threshold actually applies
        NSUInteger pidx = [byBasePeak firstIndex];
        BOOL bpOk = YES;
        while (pidx != NSNotFound) {
            if ([back.spectrumIndex basePeakIntensityAt:pidx] < 5000.0) { bpOk = NO; break; }
            pidx = [byBasePeak indexGreaterThanIndex:pidx];
        }
        PASS(bpOk, "every base-peak hit is >= 5000");

        [g close];
        unlink([path fileSystemRepresentation]);
    }

    // ---- StreamWriter: append 500 spectra, flush periodically, file valid each time ----
    {
        NSString *path = qpath(@"stream");
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        MPGOInstrumentConfig *cfg =
            [[MPGOInstrumentConfig alloc] initWithManufacturer:@"Thermo"
                                                         model:@"QE"
                                                  serialNumber:@"S"
                                                    sourceType:@"ESI"
                                                  analyzerType:@"Orbitrap"
                                                  detectorType:@"em"];
        MPGOStreamWriter *w =
            [[MPGOStreamWriter alloc] initWithFilePath:path
                                                runName:@"stream_run"
                                        acquisitionMode:MPGOAcquisitionModeMS1DDA
                                       instrumentConfig:cfg
                                                  error:&err];
        PASS(w != nil, "MPGOStreamWriter created");

        BOOL appendedAll = YES;
        for (NSUInteger k = 0; k < 500; k++) {
            if (![w appendSpectrum:bigSpectrum(k) error:&err]) {
                appendedAll = NO; break;
            }
            // Flush every 100 spectra and verify the file is openable + has the
            // expected number of spectra so far. Wrap in an autoreleasepool so
            // the verification reader's HDF5 handles drop before the next flush.
            if ((k + 1) % 100 == 0) {
                @autoreleasepool {
                    PASS([w flushWithError:&err], "intermediate flush succeeds");
                    MPGOHDF5File *f = [MPGOHDF5File openReadOnlyAtPath:path error:&err];
                    MPGOAcquisitionRun *run =
                        [MPGOAcquisitionRun readFromGroup:[f rootGroup]
                                                      name:@"stream_run"
                                                     error:&err];
                    PASS(run != nil, "post-flush file opens as a valid run");
                    PASS([run count] == k + 1, "post-flush run reports correct spectrum count");
                    [f close];
                    f = nil; run = nil;
                }
            }
        }

        PASS(appendedAll, "all 500 appendSpectrum: calls succeeded");
        PASS([w flushAndCloseWithError:&err], "final flush + close");
        PASS(w.spectrumCount == 500, "writer reports 500 spectra written");

        // ---- StreamReader reads the same 500 spectra in order with byte-exact match ----
        MPGOStreamReader *r =
            [[MPGOStreamReader alloc] initWithFilePath:path
                                                runName:@"stream_run"
                                                  error:&err];
        PASS(r != nil, "MPGOStreamReader opens the streamed file");
        PASS(r.totalCount == 500, "reader reports 500 spectra");

        NSUInteger seen = 0;
        BOOL allOk = YES;
        while (![r atEnd]) {
            MPGOMassSpectrum *got = [r nextSpectrumWithError:&err];
            if (!got) { allOk = NO; break; }
            MPGOMassSpectrum *expected = bigSpectrum(seen);
            if (![got.mzArray.buffer isEqualToData:expected.mzArray.buffer]) allOk = NO;
            if (![got.intensityArray.buffer isEqualToData:expected.intensityArray.buffer]) allOk = NO;
            if (got.msLevel != expected.msLevel) allOk = NO;
            seen++;
        }
        PASS(seen == 500, "reader visits all 500 spectra");
        PASS(allOk, "all 500 streamed spectra match originals byte-exact");

        [r close];
        unlink([path fileSystemRepresentation]);
    }
}
