/*
 * TestMilestone21 — LZ4 + Numpress-delta compression codecs.
 *
 * LZ4 tests are skipped cleanly when the HDF5 filter plugin (id
 * 32004) is not loadable at runtime — the handoff acceptance
 * criterion explicitly allows that. Numpress-delta is a pure-C
 * transform so it always runs.
 */

#import <Foundation/Foundation.h>
#import "Testing.h"

#import "Core/TTIONumpress.h"
#import "Core/TTIOSignalArray.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOInstrumentConfig.h"
#import "Run/TTIOSpectrumIndex.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOEnums.h"

#import <hdf5.h>
#import <math.h>
#import <unistd.h>

static NSString *m21path(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_test_m21_%d_%@.tio",
            (int)getpid(), suffix];
}

static TTIOAcquisitionRun *m21BuildRun(NSUInteger nSpec, NSUInteger nPts)
{
    NSMutableArray *spectra = [NSMutableArray array];
    for (NSUInteger k = 0; k < nSpec; k++) {
        double mz[32], in[32];
        for (NSUInteger i = 0; i < nPts; i++) {
            mz[i] = 100.0 + (double)(k * nPts + i) * 0.25;
            in[i] = (double)(k * 100 + i);
        }
        TTIOEncodingSpec *enc =
            [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                           compressionAlgorithm:TTIOCompressionZlib
                                      byteOrder:TTIOByteOrderLittleEndian];
        TTIOSignalArray *mzA =
            [[TTIOSignalArray alloc] initWithBuffer:[NSData dataWithBytes:mz length:nPts * sizeof(double)]
                                              length:nPts
                                            encoding:enc
                                                axis:nil];
        TTIOSignalArray *inA =
            [[TTIOSignalArray alloc] initWithBuffer:[NSData dataWithBytes:in length:nPts * sizeof(double)]
                                              length:nPts
                                            encoding:enc
                                                axis:nil];
        [spectra addObject:
            [[TTIOMassSpectrum alloc] initWithMzArray:mzA
                                       intensityArray:inA
                                              msLevel:1
                                             polarity:TTIOPolarityPositive
                                           scanWindow:nil
                                        indexPosition:k
                                      scanTimeSeconds:(double)k * 0.5
                                          precursorMz:0
                                      precursorCharge:0
                                                error:NULL]];
    }
    TTIOInstrumentConfig *cfg =
        [[TTIOInstrumentConfig alloc] initWithManufacturer:@""
                                                     model:@""
                                              serialNumber:@""
                                                sourceType:@""
                                              analyzerType:@""
                                              detectorType:@""];
    return [[TTIOAcquisitionRun alloc] initWithSpectra:spectra
                                       acquisitionMode:TTIOAcquisitionModeMS1DDA
                                      instrumentConfig:cfg];
}

void testMilestone21(void)
{
    // ---- 1. Numpress unit test: encoder + decoder round trip ----
    {
        const NSUInteger n = 1024;
        double *input = malloc(n * sizeof(double));
        for (NSUInteger i = 0; i < n; i++) {
            input[i] = 100.0 + (double)i * 0.01;
        }
        int64_t scale = [TTIONumpress scaleForValueRangeMin:input[0] max:input[n-1]];
        int64_t *deltas = malloc(n * sizeof(int64_t));
        PASS([TTIONumpress encodeFloat64:input count:n scale:scale outDeltas:deltas],
             "numpress encode succeeds");

        double *decoded = malloc(n * sizeof(double));
        PASS([TTIONumpress decodeInt64:deltas count:n scale:scale outValues:decoded],
             "numpress decode succeeds");

        double maxRelErr = 0.0;
        for (NSUInteger i = 0; i < n; i++) {
            double err = fabs(decoded[i] - input[i]);
            double rel = err / fmax(fabs(input[i]), 1.0);
            if (rel > maxRelErr) maxRelErr = rel;
        }
        PASS(maxRelErr < 1e-6, "numpress max relative error < 1 ppm");
        free(input); free(deltas); free(decoded);
    }

    // ---- 2. Numpress end-to-end via signalCompression ----
    {
        TTIOAcquisitionRun *run = m21BuildRun(8, 16);
        run.signalCompression = TTIOCompressionNumpressDelta;
        TTIOSpectralDataset *ds =
            [[TTIOSpectralDataset alloc] initWithTitle:@"m21np"
                                    isaInvestigationId:@""
                                                msRuns:@{@"run_0001": run}
                                               nmrRuns:@{}
                                       identifications:@[]
                                       quantifications:@[]
                                     provenanceRecords:@[]
                                           transitions:nil];
        NSString *path = m21path(@"np");
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        PASS([ds writeToFilePath:path error:&err],
             "M21 Numpress dataset writes to disk");

        TTIOSpectralDataset *round =
            [TTIOSpectralDataset readFromFilePath:path error:&err];
        PASS(round != nil, "M21 Numpress dataset reopens");

        TTIOAcquisitionRun *rr = round.msRuns[@"run_0001"];
        PASS(rr.signalCompression == TTIOCompressionNumpressDelta,
             "reader reports Numpress-delta codec");

        NSError *err2 = nil;
        TTIOMassSpectrum *s0 = [rr spectrumAtIndex:0 error:&err2];
        const double *mz = s0.mzArray.buffer.bytes;
        double expected0 = 100.0;
        PASS(fabs(mz[0] - expected0) < 1e-6,
             "Numpress-decoded first m/z within 1 ppm");
        const double *mz_last = mz + 15;
        double expected15 = 100.0 + 15.0 * 0.25;
        PASS(fabs(*mz_last - expected15) < 1e-6,
             "Numpress-decoded last m/z in spectrum 0 within 1 ppm");

        TTIOMassSpectrum *s7 = [rr spectrumAtIndex:7 error:&err2];
        const double *mz7 = s7.mzArray.buffer.bytes;
        double expected_s7_0 = 100.0 + (7.0 * 16.0) * 0.25;
        PASS(fabs(mz7[0] - expected_s7_0) < 1e-6,
             "Numpress spectrum 7 first m/z within 1 ppm");

        unlink([path fileSystemRepresentation]);
    }

    // ---- 3. LZ4 end-to-end (skip cleanly if filter not loadable) ----
    if (H5Zfilter_avail((H5Z_filter_t)32004) > 0) {
        TTIOAcquisitionRun *run = m21BuildRun(8, 16);
        run.signalCompression = TTIOCompressionLZ4;
        TTIOSpectralDataset *ds =
            [[TTIOSpectralDataset alloc] initWithTitle:@"m21lz4"
                                    isaInvestigationId:@""
                                                msRuns:@{@"run_0001": run}
                                               nmrRuns:@{}
                                       identifications:@[]
                                       quantifications:@[]
                                     provenanceRecords:@[]
                                           transitions:nil];
        NSString *path = m21path(@"lz4");
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        PASS([ds writeToFilePath:path error:&err],
             "M21 LZ4 dataset writes to disk");

        TTIOSpectralDataset *round =
            [TTIOSpectralDataset readFromFilePath:path error:&err];
        PASS(round != nil, "M21 LZ4 dataset reopens");
        TTIOAcquisitionRun *rr = round.msRuns[@"run_0001"];
        NSError *err2 = nil;
        TTIOMassSpectrum *s0 = [rr spectrumAtIndex:0 error:&err2];
        const double *mz = s0.mzArray.buffer.bytes;
        PASS(mz[0] == 100.0, "LZ4 round-trip first m/z exact");
        PASS(mz[15] == 100.0 + 15.0 * 0.25,
             "LZ4 round-trip last m/z in spectrum 0 exact");
        unlink([path fileSystemRepresentation]);
    }
    // else: silently skip — the hdf5 LZ4 plugin isn't available in
    // this build, which is the documented behaviour for CI hosts
    // that haven't installed hdf5plugin / hdf5-filter-plugin.
}
