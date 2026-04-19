/*
 * ObjC profiling harness for MPEG-O. Matches the Python + Java
 * harnesses: 10K spectra, 16 peaks, HDF5 backend.
 *
 * Reports phase timings (build / write / read). When built with
 * `-pg`, the gmon.out dump lets gprof produce a hot-method breakdown.
 *
 * Build:
 *   clang -fobjc-arc -I ../Source profile_objc.m -lMPGO \
 *       -lgnustep-base -lhdf5 -lobjc -o _build/profile_objc
 *
 * With gprof instrumentation:
 *   add -pg + link libMPGO that was also built with -pg.
 */
#import <Foundation/Foundation.h>
#import <time.h>

#import "Dataset/MPGOSpectralDataset.h"
#import "Dataset/MPGOWrittenRun.h"
#import "Run/MPGOAcquisitionRun.h"
#import "Run/MPGOSpectrumIndex.h"
#import "Run/MPGOInstrumentConfig.h"
#import "Spectra/MPGOMassSpectrum.h"
#import "Core/MPGOSignalArray.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "ValueClasses/MPGOEnums.h"
#import "HDF5/MPGOHDF5File.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Dataset.h"

static double nowSeconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static MPGOSignalArray *encodeF64(const double *src, NSUInteger n)
{
    NSData *buf = [NSData dataWithBytes:src length:n * sizeof(double)];
    MPGOEncodingSpec *enc =
        [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat64
                       compressionAlgorithm:MPGOCompressionZlib
                                  byteOrder:MPGOByteOrderLittleEndian];
    return [[MPGOSignalArray alloc] initWithBuffer:buf length:n encoding:enc axis:nil];
}

static MPGOMassSpectrum *makeSpectrum(NSUInteger k, NSUInteger nPeaks,
                                       double *mzScratch, double *intScratch)
{
    for (NSUInteger i = 0; i < nPeaks; i++) {
        mzScratch[i]  = 100.0 + (double)k + (double)i * 0.1;
        intScratch[i] = 1000.0 + (double)((k * 31 + i) % 1000);
    }
    MPGOSignalArray *mz  = encodeF64(mzScratch, nPeaks);
    MPGOSignalArray *in_ = encodeF64(intScratch, nPeaks);
    NSError *err = nil;
    return [[MPGOMassSpectrum alloc] initWithMzArray:mz
                                      intensityArray:in_
                                             msLevel:1
                                            polarity:MPGOPolarityPositive
                                          scanWindow:nil
                                       indexPosition:k
                                     scanTimeSeconds:(double)k * 0.06
                                         precursorMz:0.0
                                     precursorCharge:0
                                               error:&err];
}

/* Low-level HDF5 path: writes the two signal channels directly as
 * flat datasets, bypassing MPGOAcquisitionRun/MPGOMassSpectrum object
 * construction. This is the apples-to-apples analogue of Python's
 * `SpectralDataset.write_minimal` and Java's direct double[] channels.
 *
 * Measures just the three costs the Java/Python paths pay:
 *   build: allocate and fill two flat double buffers
 *   write: open HDF5 file, create chunked zlib-compressed datasets,
 *          H5Dwrite the buffers, close
 *   read:  open HDF5, H5Dread the mz dataset, no object construction
 */
/* writeMinimal API path: builds an MPGOWrittenRun with flat NSData
 * buffers and calls the new v1.1 writeMinimalToPath. Parity
 * comparison for Python's SpectralDataset.write_minimal. */
static void workload_minimal(NSString *path, NSUInteger n, NSUInteger peaks,
                              double outT[3])
{
    @autoreleasepool {
        NSUInteger total = n * peaks;

        double t0 = nowSeconds();
        NSMutableData *mzBuf  = [NSMutableData dataWithLength:total * sizeof(double)];
        NSMutableData *intBuf = [NSMutableData dataWithLength:total * sizeof(double)];
        double *mz  = (double *)mzBuf.mutableBytes;
        double *inn = (double *)intBuf.mutableBytes;
        for (NSUInteger i = 0; i < n; i++) {
            for (NSUInteger j = 0; j < peaks; j++) {
                NSUInteger pos = i * peaks + j;
                mz[pos]  = 100.0 + (double)i + (double)j * 0.1;
                inn[pos] = 1000.0 + (double)((i * 31 + j) % 1000);
            }
        }
        NSMutableData *offsets = [NSMutableData dataWithLength:n * sizeof(int64_t)];
        NSMutableData *lengths = [NSMutableData dataWithLength:n * sizeof(uint32_t)];
        NSMutableData *rts     = [NSMutableData dataWithLength:n * sizeof(double)];
        NSMutableData *mls     = [NSMutableData dataWithLength:n * sizeof(int32_t)];
        NSMutableData *pols    = [NSMutableData dataWithLength:n * sizeof(int32_t)];
        NSMutableData *pmzs    = [NSMutableData dataWithLength:n * sizeof(double)];
        NSMutableData *pcs     = [NSMutableData dataWithLength:n * sizeof(int32_t)];
        NSMutableData *bps     = [NSMutableData dataWithLength:n * sizeof(double)];
        int64_t *op  = (int64_t *)offsets.mutableBytes;
        uint32_t *lp = (uint32_t *)lengths.mutableBytes;
        double   *rp = (double *)rts.mutableBytes;
        int32_t  *mp = (int32_t *)mls.mutableBytes;
        int32_t  *pp = (int32_t *)pols.mutableBytes;
        double   *qp = (double *)pmzs.mutableBytes;
        int32_t  *cp = (int32_t *)pcs.mutableBytes;
        double   *bp = (double *)bps.mutableBytes;
        for (NSUInteger i = 0; i < n; i++) {
            op[i] = (int64_t)i * (int64_t)peaks;
            lp[i] = (uint32_t)peaks;
            rp[i] = (double)i * 0.06;
            mp[i] = 1; pp[i] = 1; qp[i] = 0.0; cp[i] = 0; bp[i] = 1000.0;
        }
        MPGOWrittenRun *wr = [[MPGOWrittenRun alloc]
            initWithSpectrumClassName:@"MPGOMassSpectrum"
                      acquisitionMode:(int64_t)MPGOAcquisitionModeMS1DDA
                          channelData:@{@"mz": mzBuf, @"intensity": intBuf}
                              offsets:offsets
                              lengths:lengths
                       retentionTimes:rts
                             msLevels:mls
                           polarities:pols
                         precursorMzs:pmzs
                     precursorCharges:pcs
                  basePeakIntensities:bps];
        outT[0] = nowSeconds() - t0;

        t0 = nowSeconds();
        NSError *err = nil;
        BOOL ok = [MPGOSpectralDataset writeMinimalToPath:path
                                                     title:@"stress"
                                       isaInvestigationId:@"ISA-STRESS"
                                                   msRuns:@{@"r": wr}
                                           identifications:nil
                                           quantifications:nil
                                         provenanceRecords:nil
                                                     error:&err];
        if (!ok) { NSLog(@"writeMinimal failed: %@", err); exit(1); }
        outT[1] = nowSeconds() - t0;

        t0 = nowSeconds();
        MPGOSpectralDataset *back =
            [MPGOSpectralDataset readFromFilePath:path error:&err];
        if (!back) { NSLog(@"read failed: %@", err); exit(1); }
        MPGOAcquisitionRun *backRun = back.msRuns[@"r"];
        NSUInteger sampled = 0;
        for (NSUInteger i = 0; i < n; i += 100) {
            MPGOMassSpectrum *spec = [backRun objectAtIndex:i];
            sampled += spec.signalArrays[@"mz"].length;
        }
        outT[2] = nowSeconds() - t0;

        NSUInteger expected = ((n + 99) / 100) * peaks;
        if (sampled != expected) {
            NSLog(@"minimal sampled=%lu expected=%lu",
                  (unsigned long)sampled, (unsigned long)expected);
            exit(1);
        }
    }
}

static void workload_flat(NSString *path, NSUInteger n, NSUInteger peaks,
                           double outT[3])
{
    @autoreleasepool {
        NSUInteger total = n * peaks;

        // ── build ─────────────────────────────────────────────────
        double t0 = nowSeconds();
        NSMutableData *mzBuf  = [NSMutableData dataWithLength:total * sizeof(double)];
        NSMutableData *intBuf = [NSMutableData dataWithLength:total * sizeof(double)];
        double *mz  = (double *)mzBuf.mutableBytes;
        double *inn = (double *)intBuf.mutableBytes;
        for (NSUInteger i = 0; i < n; i++) {
            for (NSUInteger j = 0; j < peaks; j++) {
                NSUInteger pos = i * peaks + j;
                mz[pos]  = 100.0 + (double)i + (double)j * 0.1;
                inn[pos] = 1000.0 + (double)((i * 31 + j) % 1000);
            }
        }
        outT[0] = nowSeconds() - t0;

        // ── write ─────────────────────────────────────────────────
        t0 = nowSeconds();
        NSError *err = nil;
        MPGOHDF5File *f = [MPGOHDF5File createAtPath:path error:&err];
        if (!f) { NSLog(@"create failed: %@", err); exit(1); }
        MPGOHDF5Group *root = [f rootGroup];
        MPGOHDF5Group *ch = [root createGroupNamed:@"signal_channels" error:&err];

        MPGOHDF5Dataset *mzDs =
            [ch createDatasetNamed:@"mz_values"
                         precision:MPGOPrecisionFloat64
                            length:total
                         chunkSize:16384
                  compressionLevel:6
                             error:&err];
        [mzDs writeData:mzBuf error:&err];

        MPGOHDF5Dataset *inDs =
            [ch createDatasetNamed:@"intensity_values"
                         precision:MPGOPrecisionFloat64
                            length:total
                         chunkSize:16384
                  compressionLevel:6
                             error:&err];
        [inDs writeData:intBuf error:&err];
        outT[1] = nowSeconds() - t0;

        // ── read (reopen + sampled hyperslab reads matching obj mode) ──
        // For parity with the Java/Python sampled read (which reads 100
        // mz slices of 16 doubles each), do the same with explicit
        // hyperslab reads on the flat dataset.
        t0 = nowSeconds();
        MPGOHDF5File *f2 = [MPGOHDF5File openAtPath:path error:&err];
        MPGOHDF5Group *root2 = [f2 rootGroup];
        MPGOHDF5Group *ch2 = [root2 openGroupNamed:@"signal_channels" error:&err];
        MPGOHDF5Dataset *mzDs2 = [ch2 openDatasetNamed:@"mz_values" error:&err];
        NSUInteger sampled = 0;
        for (NSUInteger i = 0; i < n; i += 100) {
            NSData *slice = [mzDs2 readDataAtOffset:i * peaks
                                              count:peaks
                                              error:&err];
            sampled += slice.length / sizeof(double);
        }
        outT[2] = nowSeconds() - t0;
        NSUInteger expected = ((n + 99) / 100) * peaks;
        if (sampled != expected) {
            NSLog(@"flat sampled=%lu expected=%lu", (unsigned long)sampled,
                  (unsigned long)expected);
            exit(1);
        }
    }
}

// Phase sub-timings populated by workload() so we can attribute the
// object-mode write phase.
static double g_subBuildSpectrum = 0.0;      // 10K spectrum ctors
static double g_subBuildRun      = 0.0;      // AcquisitionRun init
static double g_subBuildDataset  = 0.0;      // SpectralDataset init
static double g_subConcat        = 0.0;      // writeToGroup channel concat
static double g_subHdf5Write     = 0.0;      // residual = write - concat

static void workload(NSString *path, NSUInteger n, NSUInteger peaks,
                      double outT[3])
{
    @autoreleasepool {
        double *mzScratch  = malloc(peaks * sizeof(double));
        double *intScratch = malloc(peaks * sizeof(double));

        double tPhase = nowSeconds();
        double t0 = tPhase;
        NSMutableArray *spectra = [NSMutableArray arrayWithCapacity:n];
        for (NSUInteger k = 0; k < n; k++) {
            [spectra addObject:makeSpectrum(k, peaks, mzScratch, intScratch)];
        }
        g_subBuildSpectrum = nowSeconds() - t0;
        t0 = nowSeconds();
        MPGOInstrumentConfig *cfg =
            [[MPGOInstrumentConfig alloc] initWithManufacturer:@"Thermo"
                                                         model:@"QE"
                                                  serialNumber:@"S"
                                                    sourceType:@"ESI"
                                                  analyzerType:@"Orbitrap"
                                                  detectorType:@"em"];
        MPGOAcquisitionRun *run =
            [[MPGOAcquisitionRun alloc] initWithSpectra:spectra
                                        acquisitionMode:MPGOAcquisitionModeMS1DDA
                                       instrumentConfig:cfg];
        g_subBuildRun = nowSeconds() - t0;

        t0 = nowSeconds();
        MPGOSpectralDataset *ds =
            [[MPGOSpectralDataset alloc] initWithTitle:@"stress"
                                  isaInvestigationId:@"ISA-STRESS"
                                              msRuns:@{@"r": run}
                                             nmrRuns:@{}
                                     identifications:@[]
                                     quantifications:@[]
                                  provenanceRecords:@[]
                                        transitions:nil];
        g_subBuildDataset = nowSeconds() - t0;
        outT[0] = nowSeconds() - tPhase;                             // build total

        // Measure the channel-concat cost separately: iterate over every
        // spectrum's NSData channel and memcpy into one flat NSMutableData,
        // for both "mz" and "intensity". This is what MPGOAcquisitionRun
        // writeToGroup: does internally; doing it here quantifies the
        // object-model tax versus the flat-buffer path.
        t0 = nowSeconds();
        NSUInteger total = n * peaks;
        for (NSString *chName in @[@"mz", @"intensity"]) {
            NSMutableData *all = [NSMutableData dataWithLength:total * sizeof(double)];
            NSUInteger cursor = 0;
            for (MPGOMassSpectrum *s in spectra) {
                MPGOSignalArray *arr = s.signalArrays[chName];
                NSUInteger nn = arr.length;
                memcpy((uint8_t *)all.mutableBytes + cursor * sizeof(double),
                       arr.buffer.bytes, nn * sizeof(double));
                cursor += nn;
            }
            (void)all;
        }
        g_subConcat = nowSeconds() - t0;

        t0 = nowSeconds();
        NSError *err = nil;
        BOOL ok = [ds writeToFilePath:path error:&err];
        if (!ok) {
            NSLog(@"write failed: %@", err);
            exit(1);
        }
        outT[1] = nowSeconds() - t0;                                 // write
        // residual = write - concat (concat happens INSIDE writeToFilePath,
        // but we approximate by measuring it once more outside).
        g_subHdf5Write = outT[1] - g_subConcat;

        t0 = nowSeconds();
        MPGOSpectralDataset *back =
            [MPGOSpectralDataset readFromFilePath:path error:&err];
        if (!back) {
            NSLog(@"read failed: %@", err);
            exit(1);
        }
        MPGOAcquisitionRun *backRun = back.msRuns[@"r"];
        NSUInteger sampled = 0;
        for (NSUInteger i = 0; i < n; i += 100) {
            MPGOMassSpectrum *spec = [backRun objectAtIndex:i];
            sampled += spec.signalArrays[@"mz"].length;
        }
        outT[2] = nowSeconds() - t0;                                 // read

        NSUInteger expected = ((n + 99) / 100) * peaks;
        if (sampled != expected) {
            NSLog(@"sampled=%lu expected=%lu", (unsigned long)sampled,
                  (unsigned long)expected);
            exit(1);
        }

        free(mzScratch);
        free(intScratch);
    }
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSUInteger n = 10000;
        NSUInteger peaks = 16;
        NSUInteger warmups = 1;
        int flat = 0;
        int minimal = 0;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--n") == 0 && i + 1 < argc) {
                n = (NSUInteger)atoi(argv[++i]);
            } else if (strcmp(argv[i], "--peaks") == 0 && i + 1 < argc) {
                peaks = (NSUInteger)atoi(argv[++i]);
            } else if (strcmp(argv[i], "--warmups") == 0 && i + 1 < argc) {
                warmups = (NSUInteger)atoi(argv[++i]);
            } else if (strcmp(argv[i], "--flat") == 0) {
                flat = 1;
            } else if (strcmp(argv[i], "--minimal") == 0) {
                minimal = 1;
            }
        }
        void (*run_fn)(NSString *, NSUInteger, NSUInteger, double *) =
            minimal ? workload_minimal : (flat ? workload_flat : workload);
        const char *mode = minimal ? " (writeMinimal)"
                                    : (flat ? " (flat primitives)" : "");

        const char *home = getenv("HOME");
        NSString *outDir = [NSString stringWithFormat:@"%s/mpgo_profile_objc_out",
                            home ? home : "/tmp"];
        [[NSFileManager defaultManager] createDirectoryAtPath:outDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];

        // Warm up (caches; no JIT).
        for (NSUInteger w = 0; w < warmups; w++) {
            NSString *wp = [NSString stringWithFormat:@"%@/warm_%lu.mpgo",
                            outDir, (unsigned long)w];
            unlink([wp fileSystemRepresentation]);
            double t[3];
            run_fn(wp, n, peaks, t);
            unlink([wp fileSystemRepresentation]);
        }

        NSString *path = [NSString stringWithFormat:@"%@/stress.mpgo", outDir];
        unlink([path fileSystemRepresentation]);

        double t[3];
        run_fn(path, n, peaks, t);

        NSDictionary *attrs = [[NSFileManager defaultManager]
            attributesOfItemAtPath:path error:NULL];
        double sizeMB = ((NSNumber *)attrs[NSFileSize]).doubleValue / 1e6;

        printf("==============================================================================\n");
        printf("ObjC profile%s: n=%lu, peaks=%lu, file=%.2f MB, warmups=%lu\n",
               mode,
               (unsigned long)n, (unsigned long)peaks, sizeMB,
               (unsigned long)warmups);
        printf("==============================================================================\n");
        printf("  phase build     : %8.1f ms\n", t[0] * 1000.0);
        printf("  phase write     : %8.1f ms\n", t[1] * 1000.0);
        printf("  phase read      : %8.1f ms\n", t[2] * 1000.0);
        printf("  phase TOTAL     : %8.1f ms\n", (t[0] + t[1] + t[2]) * 1000.0);
        if (!flat && !minimal) {
            printf("--- build breakdown ---\n");
            printf("    build spectra (%lu objs) : %8.1f ms\n",
                   (unsigned long)n, g_subBuildSpectrum * 1000.0);
            printf("    build run                : %8.1f ms\n",
                   g_subBuildRun * 1000.0);
            printf("    build dataset            : %8.1f ms\n",
                   g_subBuildDataset * 1000.0);
            printf("--- write breakdown ---\n");
            printf("    channel concat (extra)   : %8.1f ms  [measured outside]\n",
                   g_subConcat * 1000.0);
            printf("    HDF5 emission (residual) : %8.1f ms  [write - concat]\n",
                   g_subHdf5Write * 1000.0);
        }
    }
    return 0;
}
