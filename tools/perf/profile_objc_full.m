/*
 * Multi-function ObjC perf harness for TTI-O.
 *
 * Mirrors profile_python_full.py + ProfileHarnessFull.java so
 * cross-language deltas are directly comparable.
 *
 * Coverage:
 *   ms.hdf5              — SpectralDataset writeMinimal + sampled read
 *   ms.memory/sqlite/zarr — reported as N/A in ObjC v0.11.1 (write
 *                            path not yet ported — read-only via
 *                            readViaProviderURL:). Python + Java
 *                            continue to measure these.
 *   transport.plain      — TTIOTransportWriter / TTIOTransportReader
 *   transport.compressed — same with useCompression=YES
 *   encryption           — TTIOPerAUFile encrypt/decrypt round-trip
 *   signatures           — TTIOSignatureManager sign/verify on HDF5 dataset
 *   jcamp                — TTIOJcampDxWriter/Reader for IR+Raman+UV-Vis
 *   spectra.build        — IR/Raman/UV-Vis/2D-COS in-memory construction
 *
 * Usage:
 *   ./build_and_run_objc_full.sh [--n 10000] [--peaks 16] [--only ms.hdf5,...]
 */
#import <Foundation/Foundation.h>
#import <stdio.h>
#import <string.h>
#import <time.h>
#import <math.h>
#import <unistd.h>

#import "Core/TTIOSignalArray.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOWrittenRun.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOInstrumentConfig.h"
#import "Run/TTIOSpectrumIndex.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "Spectra/TTIOIRSpectrum.h"
#import "Spectra/TTIORamanSpectrum.h"
#import "Spectra/TTIOUVVisSpectrum.h"
#import "Spectra/TTIOTwoDimensionalCorrelationSpectrum.h"
#import "Protection/TTIOPerAUFile.h"
#import "Protection/TTIOSignatureManager.h"
#import "Transport/TTIOTransportWriter.h"
#import "Transport/TTIOTransportReader.h"
#import "Export/TTIOJcampDxWriter.h"
#import "Import/TTIOJcampDxReader.h"
#import "ValueClasses/TTIOAxisDescriptor.h"
#import "ValueClasses/TTIOValueRange.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOEnums.h"

/* ── Clock ─────────────────────────────────────────────────────── */

static double nowSeconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/* ── Workload builders ─────────────────────────────────────────── */

static TTIOWrittenRun *buildMsRun(NSUInteger n, NSUInteger peaks)
{
    NSUInteger total = n * peaks;
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
    int64_t  *op = (int64_t *)offsets.mutableBytes;
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
    return [[TTIOWrittenRun alloc]
        initWithSpectrumClassName:@"TTIOMassSpectrum"
                  acquisitionMode:(int64_t)TTIOAcquisitionModeMS1DDA
                      channelData:@{@"mz": mzBuf, @"intensity": intBuf}
                          offsets:offsets
                          lengths:lengths
                   retentionTimes:rts
                         msLevels:mls
                       polarities:pols
                     precursorMzs:pmzs
                 precursorCharges:pcs
              basePeakIntensities:bps];
}

/* ── Helpers for spectrum construction ─────────────────────────── */

static TTIOSignalArray *makeSignalArray(const double *src, NSUInteger n,
                                         NSString *axisName, NSString *axisUnit)
{
    NSData *buf = [NSData dataWithBytes:src length:n * sizeof(double)];
    TTIOEncodingSpec *enc = [TTIOEncodingSpec
        specWithPrecision:TTIOPrecisionFloat64
     compressionAlgorithm:TTIOCompressionNone
                byteOrder:TTIOByteOrderLittleEndian];
    TTIOValueRange *range = nil;
    double lo = src[0], hi = src[0];
    for (NSUInteger i = 1; i < n; i++) {
        if (src[i] < lo) lo = src[i];
        if (src[i] > hi) hi = src[i];
    }
    range = [TTIOValueRange rangeWithMinimum:lo maximum:hi];
    TTIOAxisDescriptor *axis = [TTIOAxisDescriptor
        descriptorWithName:axisName
                      unit:axisUnit
                valueRange:range
              samplingMode:TTIOSamplingModeUniform];
    return [[TTIOSignalArray alloc] initWithBuffer:buf
                                             length:n
                                           encoding:enc
                                               axis:axis];
}

static TTIOIRSpectrum *makeIRSpectrum(NSUInteger n)
{
    double *wn = malloc(n * sizeof(double));
    double *y  = malloc(n * sizeof(double));
    for (NSUInteger i = 0; i < n; i++) {
        double w = 4000.0 - (4000.0 - 400.0) * (double)i / (double)(n - 1);
        wn[i] = w;
        y[i]  = 0.5 + 0.4 * sin(w / 50.0);
    }
    TTIOSignalArray *wnArr  = makeSignalArray(wn, n, @"wavenumber", @"1/cm");
    TTIOSignalArray *intArr = makeSignalArray(y,  n, @"absorbance", @"");
    free(wn); free(y);
    NSError *err = nil;
    return [[TTIOIRSpectrum alloc] initWithWavenumberArray:wnArr
                                             intensityArray:intArr
                                                       mode:TTIOIRModeAbsorbance
                                            resolutionCmInv:4.0
                                              numberOfScans:32
                                              indexPosition:0
                                            scanTimeSeconds:0.0
                                                      error:&err];
}

static TTIORamanSpectrum *makeRamanSpectrum(NSUInteger n)
{
    double *wn = malloc(n * sizeof(double));
    double *y  = malloc(n * sizeof(double));
    for (NSUInteger i = 0; i < n; i++) {
        double w = 100.0 + (3200.0 - 100.0) * (double)i / (double)(n - 1);
        wn[i] = w;
        double d = (w - 1500.0) / 300.0;
        y[i]  = 10.0 + 100.0 * exp(-d * d);
    }
    TTIOSignalArray *wnArr  = makeSignalArray(wn, n, @"raman shift", @"1/cm");
    TTIOSignalArray *intArr = makeSignalArray(y,  n, @"intensity", @"counts");
    free(wn); free(y);
    NSError *err = nil;
    return [[TTIORamanSpectrum alloc] initWithWavenumberArray:wnArr
                                                intensityArray:intArr
                                        excitationWavelengthNm:785.0
                                                  laserPowerMw:20.0
                                            integrationTimeSec:5.0
                                                 indexPosition:0
                                               scanTimeSeconds:0.0
                                                         error:&err];
}

static TTIOUVVisSpectrum *makeUVVisSpectrum(NSUInteger n)
{
    double *wl = malloc(n * sizeof(double));
    double *ab = malloc(n * sizeof(double));
    for (NSUInteger i = 0; i < n; i++) {
        double w = 200.0 + (800.0 - 200.0) * (double)i / (double)(n - 1);
        wl[i] = w;
        double d = (w - 450.0) / 40.0;
        ab[i] = exp(-d * d);
    }
    TTIOSignalArray *wlArr = makeSignalArray(wl, n, @"wavelength", @"nm");
    TTIOSignalArray *abArr = makeSignalArray(ab, n, @"absorbance", @"");
    free(wl); free(ab);
    NSError *err = nil;
    return [[TTIOUVVisSpectrum alloc] initWithWavelengthArray:wlArr
                                              absorbanceArray:abArr
                                                 pathLengthCm:1.0
                                                      solvent:@"methanol"
                                                indexPosition:0
                                              scanTimeSeconds:0.0
                                                        error:&err];
}

static TTIOTwoDimensionalCorrelationSpectrum *make2DCos(NSUInteger m)
{
    NSUInteger size = m * m;
    NSMutableData *sync = [NSMutableData dataWithLength:size * sizeof(double)];
    NSMutableData *asyn = [NSMutableData dataWithLength:size * sizeof(double)];
    double *s = (double *)sync.mutableBytes;
    double *a = (double *)asyn.mutableBytes;
    double *row = malloc(m * sizeof(double));
    for (NSUInteger i = 0; i < m; i++) {
        double v = 1000.0 + (1800.0 - 1000.0) * (double)i / (double)(m - 1);
        row[i] = v;
    }
    for (NSUInteger i = 0; i < m; i++) {
        double ci = cos(row[i] / 100.0);
        double si = sin(row[i] / 100.0);
        for (NSUInteger j = 0; j < m; j++) {
            double cj = cos(row[j] / 100.0);
            s[i * m + j] = ci * cj;
            a[i * m + j] = si * cj;
        }
    }
    free(row);
    TTIOValueRange *rng = [TTIOValueRange rangeWithMinimum:1000.0 maximum:1800.0];
    TTIOAxisDescriptor *axis = [TTIOAxisDescriptor
        descriptorWithName:@"wavenumber" unit:@"1/cm"
                valueRange:rng samplingMode:TTIOSamplingModeUniform];
    NSError *err = nil;
    return [[TTIOTwoDimensionalCorrelationSpectrum alloc]
        initWithSynchronousMatrix:sync
               asynchronousMatrix:asyn
                       matrixSize:m
                     variableAxis:axis
                     perturbation:@"temperature"
                 perturbationUnit:@"K"
                   sourceModality:@"IR"
                    indexPosition:0
                            error:&err];
}

/* ── Benchmark result type ─────────────────────────────────────── */

// Each benchmark fills a mutable dict of phase → seconds (or NaN = N/A).
typedef void (*BenchFn)(NSString *tmp, NSUInteger n, NSUInteger peaks,
                         NSMutableDictionary *out);

static void putSeconds(NSMutableDictionary *d, NSString *k, double s)
{
    d[k] = @(s);
}

static void putNA(NSMutableDictionary *d, NSString *k)
{
    d[k] = [NSNull null];
}

/* ── MS benchmarks ─────────────────────────────────────────────── */

static void bench_ms_hdf5(NSString *tmp, NSUInteger n, NSUInteger peaks,
                           NSMutableDictionary *out)
{
    @autoreleasepool {
        NSString *path = [tmp stringByAppendingPathComponent:@"ms-hdf5.tio"];
        unlink([path fileSystemRepresentation]);
        TTIOWrittenRun *run = buildMsRun(n, peaks);
        NSError *err = nil;
        double t0 = nowSeconds();
        BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                     title:@"stress"
                                       isaInvestigationId:@"ISA-PERF"
                                                   msRuns:@{@"r": run}
                                           identifications:nil
                                           quantifications:nil
                                         provenanceRecords:nil
                                                     error:&err];
        if (!ok) { NSLog(@"ms.hdf5 write failed: %@", err); exit(1); }
        putSeconds(out, @"write", nowSeconds() - t0);

        t0 = nowSeconds();
        TTIOSpectralDataset *back =
            [TTIOSpectralDataset readFromFilePath:path error:&err];
        if (!back) { NSLog(@"ms.hdf5 read failed: %@", err); exit(1); }
        TTIOAcquisitionRun *r = back.msRuns[@"r"];
        NSUInteger step = MAX(1UL, (NSUInteger)(n / 100));
        NSUInteger sampled = 0;
        for (NSUInteger i = 0; i < n; i += step) {
            TTIOMassSpectrum *sp = [r objectAtIndex:i];
            sampled += sp.signalArrays[@"mz"].length;
        }
        (void)sampled;
        [back closeFile];
        putSeconds(out, @"read", nowSeconds() - t0);
    }
}

static void bench_ms_other(NSString *tmp, NSUInteger n, NSUInteger peaks,
                            NSMutableDictionary *out)
{
    (void)tmp; (void)n; (void)peaks;
    putNA(out, @"write");
    putNA(out, @"read");
}

/* ── Transport benchmarks ──────────────────────────────────────── */

static void bench_transport(NSString *tmp, NSUInteger n, NSUInteger peaks,
                             BOOL compressed, NSMutableDictionary *out)
{
    @autoreleasepool {
        NSString *src = [tmp stringByAppendingPathComponent:@"xport.tio"];
        NSString *mots = [tmp stringByAppendingPathComponent:
                           (compressed ? @"xport-c.mots" : @"xport.mots")];
        NSString *rt = [tmp stringByAppendingPathComponent:
                         (compressed ? @"rt-c.tio" : @"rt.tio")];
        unlink([src fileSystemRepresentation]);
        unlink([mots fileSystemRepresentation]);
        unlink([rt fileSystemRepresentation]);

        TTIOWrittenRun *run = buildMsRun(n, peaks);
        NSError *err = nil;
        if (![TTIOSpectralDataset writeMinimalToPath:src
                                                title:@"xport"
                                  isaInvestigationId:@"ISA-XPORT"
                                              msRuns:@{@"r": run}
                                      identifications:nil
                                      quantifications:nil
                                    provenanceRecords:nil
                                                error:&err]) {
            NSLog(@"transport src write failed: %@", err); exit(1);
        }
        TTIOSpectralDataset *ds =
            [TTIOSpectralDataset readFromFilePath:src error:&err];
        if (!ds) { NSLog(@"transport src read failed: %@", err); exit(1); }

        double t0 = nowSeconds();
        TTIOTransportWriter *w = [[TTIOTransportWriter alloc] initWithOutputPath:mots];
        w.useCompression = compressed;
        w.useChecksum = YES;
        if (![w writeDataset:ds error:&err]) {
            NSLog(@"transport write failed: %@", err); exit(1);
        }
        [w close];
        putSeconds(out, @"encode", nowSeconds() - t0);

        [ds closeFile];

        t0 = nowSeconds();
        TTIOTransportReader *r = [[TTIOTransportReader alloc] initWithInputPath:mots];
        if (![r writeTtioToPath:rt error:&err]) {
            NSLog(@"transport read failed: %@", err); exit(1);
        }
        putSeconds(out, @"decode", nowSeconds() - t0);

        NSDictionary *srcAttrs  = [[NSFileManager defaultManager]
            attributesOfItemAtPath:src error:NULL];
        NSDictionary *motsAttrs = [[NSFileManager defaultManager]
            attributesOfItemAtPath:mots error:NULL];
        putSeconds(out, @"src_mb",
                    ((NSNumber *)srcAttrs[NSFileSize]).doubleValue / 1e6);
        putSeconds(out, @"mots_mb",
                    ((NSNumber *)motsAttrs[NSFileSize]).doubleValue / 1e6);
    }
}

static void bench_transport_plain(NSString *tmp, NSUInteger n, NSUInteger peaks,
                                    NSMutableDictionary *out)
{
    bench_transport(tmp, n, peaks, NO, out);
}

static void bench_transport_compressed(NSString *tmp, NSUInteger n,
                                         NSUInteger peaks,
                                         NSMutableDictionary *out)
{
    bench_transport(tmp, n, peaks, YES, out);
}

/* ── Encryption benchmark ──────────────────────────────────────── */

static void bench_encryption(NSString *tmp, NSUInteger n, NSUInteger peaks,
                              NSMutableDictionary *out)
{
    @autoreleasepool {
        NSString *src  = [tmp stringByAppendingPathComponent:@"enc.tio"];
        NSString *copy = [tmp stringByAppendingPathComponent:@"enc-copy.tio"];
        unlink([src fileSystemRepresentation]);
        unlink([copy fileSystemRepresentation]);

        TTIOWrittenRun *run = buildMsRun(n, peaks);
        NSError *err = nil;
        if (![TTIOSpectralDataset writeMinimalToPath:src
                                                title:@"enc"
                                  isaInvestigationId:@"ISA-ENC"
                                              msRuns:@{@"r": run}
                                      identifications:nil
                                      quantifications:nil
                                    provenanceRecords:nil
                                                error:&err]) {
            NSLog(@"encryption src write failed: %@", err); exit(1);
        }
        if (![[NSFileManager defaultManager] copyItemAtPath:src
                                                       toPath:copy
                                                        error:&err]) {
            NSLog(@"encryption copy failed: %@", err); exit(1);
        }

        uint8_t keyBytes[32];
        for (int i = 0; i < 32; i++) keyBytes[i] = (uint8_t)i;
        NSData *key = [NSData dataWithBytes:keyBytes length:32];

        double t0 = nowSeconds();
        if (![TTIOPerAUFile encryptFilePath:copy
                                         key:key
                              encryptHeaders:NO
                                providerName:nil
                                       error:&err]) {
            NSLog(@"encrypt failed: %@", err); exit(1);
        }
        putSeconds(out, @"encrypt", nowSeconds() - t0);

        t0 = nowSeconds();
        NSDictionary *dec = [TTIOPerAUFile decryptFilePath:copy
                                                       key:key
                                              providerName:nil
                                                     error:&err];
        if (!dec) { NSLog(@"decrypt failed: %@", err); exit(1); }
        putSeconds(out, @"decrypt", nowSeconds() - t0);

        NSDictionary *attrs = [[NSFileManager defaultManager]
            attributesOfItemAtPath:src error:NULL];
        putSeconds(out, @"bytes_mb",
                    ((NSNumber *)attrs[NSFileSize]).doubleValue / 1e6);
    }
}

/* ── Signatures benchmark ──────────────────────────────────────── */

static void bench_signatures(NSString *tmp, NSUInteger n, NSUInteger peaks,
                              NSMutableDictionary *out)
{
    @autoreleasepool {
        NSString *src = [tmp stringByAppendingPathComponent:@"sig.tio"];
        unlink([src fileSystemRepresentation]);
        TTIOWrittenRun *run = buildMsRun(n, peaks);
        NSError *err = nil;
        if (![TTIOSpectralDataset writeMinimalToPath:src
                                                title:@"sig"
                                  isaInvestigationId:@"ISA-SIG"
                                              msRuns:@{@"r": run}
                                      identifications:nil
                                      quantifications:nil
                                    provenanceRecords:nil
                                                error:&err]) {
            NSLog(@"sig src write failed: %@", err); exit(1);
        }

        uint8_t keyBytes[32];
        for (int i = 0; i < 32; i++) keyBytes[i] = (uint8_t)i;
        NSData *key = [NSData dataWithBytes:keyBytes length:32];

        NSString *dsPath = @"/study/ms_runs/r/signal_channels/intensity_values";

        double t0 = nowSeconds();
        if (![TTIOSignatureManager signDataset:dsPath
                                         inFile:src
                                        withKey:key
                                          error:&err]) {
            NSLog(@"sign failed: %@", err); exit(1);
        }
        putSeconds(out, @"sign", nowSeconds() - t0);

        t0 = nowSeconds();
        if (![TTIOSignatureManager verifyDataset:dsPath
                                           inFile:src
                                          withKey:key
                                            error:&err]) {
            NSLog(@"verify failed: %@", err); exit(1);
        }
        putSeconds(out, @"verify", nowSeconds() - t0);
    }
}

/* ── JCAMP benchmark ───────────────────────────────────────────── */

static void bench_jcamp(NSString *tmp, NSUInteger n, NSUInteger peaks,
                         NSMutableDictionary *out)
{
    (void)peaks;
    @autoreleasepool {
        NSError *err = nil;
        TTIOIRSpectrum *ir = makeIRSpectrum(n);
        NSString *jdxIR = [tmp stringByAppendingPathComponent:@"ir.jdx"];
        double t0 = nowSeconds();
        if (![TTIOJcampDxWriter writeIRSpectrum:ir
                                           toPath:jdxIR
                                            title:@"perf IR"
                                            error:&err]) {
            NSLog(@"jcamp ir write failed: %@", err); exit(1);
        }
        putSeconds(out, @"ir_write", nowSeconds() - t0);
        t0 = nowSeconds();
        if (![TTIOJcampDxReader readSpectrumFromPath:jdxIR error:&err]) {
            NSLog(@"jcamp ir read failed: %@", err); exit(1);
        }
        putSeconds(out, @"ir_read", nowSeconds() - t0);

        TTIORamanSpectrum *raman = makeRamanSpectrum(n);
        NSString *jdxR = [tmp stringByAppendingPathComponent:@"raman.jdx"];
        t0 = nowSeconds();
        if (![TTIOJcampDxWriter writeRamanSpectrum:raman
                                              toPath:jdxR
                                               title:@"perf Raman"
                                               error:&err]) {
            NSLog(@"jcamp raman write failed: %@", err); exit(1);
        }
        putSeconds(out, @"raman_write", nowSeconds() - t0);
        t0 = nowSeconds();
        if (![TTIOJcampDxReader readSpectrumFromPath:jdxR error:&err]) {
            NSLog(@"jcamp raman read failed: %@", err); exit(1);
        }
        putSeconds(out, @"raman_read", nowSeconds() - t0);

        TTIOUVVisSpectrum *uv = makeUVVisSpectrum(n);
        NSString *jdxU = [tmp stringByAppendingPathComponent:@"uvvis.jdx"];
        t0 = nowSeconds();
        if (![TTIOJcampDxWriter writeUVVisSpectrum:uv
                                              toPath:jdxU
                                               title:@"perf UV-Vis"
                                               error:&err]) {
            NSLog(@"jcamp uvvis write failed: %@", err); exit(1);
        }
        putSeconds(out, @"uvvis_write", nowSeconds() - t0);
        t0 = nowSeconds();
        if (![TTIOJcampDxReader readSpectrumFromPath:jdxU error:&err]) {
            NSLog(@"jcamp uvvis read failed: %@", err); exit(1);
        }
        putSeconds(out, @"uvvis_read", nowSeconds() - t0);

        // Compressed (SQZ) fixture — hand-rolled so we measure the
        // decompressing read path.
        NSMutableString *body = [NSMutableString string];
        const char *sqzAlpha = "@ABCDEFGHI";  // 0..9 absolute value
        NSUInteger lineX = 100;
        NSUInteger i = 0;
        while (i < n) {
            NSUInteger chunk = MIN(10UL, n - i);
            [body appendFormat:@"%lu ", (unsigned long)lineX];
            for (NSUInteger k = 0; k < chunk; k++) {
                NSUInteger v = (i + k) % 10;
                [body appendFormat:@"%c", sqzAlpha[v]];
            }
            [body appendString:@"\n"];
            lineX += chunk;
            i += chunk;
        }
        NSString *header = [NSString stringWithFormat:
            @"##TITLE=perf-compressed\n"
             "##JCAMP-DX=5.01\n"
             "##DATA TYPE=INFRARED ABSORBANCE\n"
             "##XUNITS=1/CM\n##YUNITS=ABSORBANCE\n"
             "##FIRSTX=100\n##LASTX=%lu\n##NPOINTS=%lu\n"
             "##XFACTOR=1\n##YFACTOR=1\n"
             "##XYDATA=(X++(Y..Y))\n",
             (unsigned long)(100 + n - 1), (unsigned long)n];
        NSString *full = [[header stringByAppendingString:body]
                           stringByAppendingString:@"##END=\n"];
        NSString *jdxC = [tmp stringByAppendingPathComponent:@"compressed.jdx"];
        [full writeToFile:jdxC atomically:YES
                 encoding:NSUTF8StringEncoding error:&err];
        t0 = nowSeconds();
        if (![TTIOJcampDxReader readSpectrumFromPath:jdxC error:&err]) {
            NSLog(@"jcamp compressed read failed: %@", err); exit(1);
        }
        putSeconds(out, @"compressed_read", nowSeconds() - t0);
    }
}

/* ── spectra.build benchmark ──────────────────────────────────── */

static void bench_spectra_build(NSString *tmp, NSUInteger n, NSUInteger peaks,
                                 NSMutableDictionary *out)
{
    (void)tmp; (void)peaks;
    @autoreleasepool {
        double t0 = nowSeconds();
        (void)makeIRSpectrum(n);
        putSeconds(out, @"ir_build", nowSeconds() - t0);

        t0 = nowSeconds();
        (void)makeRamanSpectrum(n);
        putSeconds(out, @"raman_build", nowSeconds() - t0);

        t0 = nowSeconds();
        (void)makeUVVisSpectrum(n);
        putSeconds(out, @"uvvis_build", nowSeconds() - t0);

        NSUInteger m = (NSUInteger)sqrt((double)n);
        if (m < 8) m = 8;
        t0 = nowSeconds();
        (void)make2DCos(m);
        putSeconds(out, @"2dcos_build", nowSeconds() - t0);
    }
}

/* Pipeline + Encryption + Streaming benchmarks (B2-B6) */

static int cmp_double(const void *a, const void *b) {
    double va = *(const double *)a, vb = *(const double *)b;
    return (va > vb) - (va < vb);
}

#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Genomics/TTIOAlignedRead.h"
#import "Protection/TTIOEncryptionManager.h"
#import "Query/TTIOStreamWriter.h"
#import "Query/TTIOStreamReader.h"

/* B2/B3/B4: Genomic pipeline (write, read, random access) */

static void bench_genomic(NSString *tmp, NSUInteger n, NSUInteger peaks,
                           NSMutableDictionary *out)
{
    (void)peaks;
    @autoreleasepool {
        NSString *path = [tmp stringByAppendingPathComponent:@"genomic.tio"];
        unlink([path fileSystemRepresentation]);

        const NSUInteger nReads   = 100000;
        const NSUInteger readLen  = 100;
        (void)n;

        /* Positions: sorted ascending, LCG seed 0xBEEF, deltas 100-500 */
        NSMutableData *posData = [NSMutableData dataWithLength:nReads * sizeof(int64_t)];
        int64_t *posPtr = (int64_t *)posData.mutableBytes;
        uint64_t lcgState = 0xBEEF;
        int64_t curPos = 0;
        for (NSUInteger i = 0; i < nReads; i++) {
            lcgState = lcgState * 6364136223846793005ULL + 1442695040888963407ULL;
            int64_t delta = 100 + (int64_t)((lcgState >> 33) % 401);
            curPos += delta;
            posPtr[i] = curPos;
        }

        /* Flags: 5 dominant values {0,16,83,99,163} */
        static const uint32_t kDomFlags[5] = {0, 16, 83, 99, 163};
        NSMutableData *flagData = [NSMutableData dataWithLength:nReads * sizeof(uint32_t)];
        uint32_t *flagPtr = (uint32_t *)flagData.mutableBytes;
        for (NSUInteger i = 0; i < nReads; i++) {
            flagPtr[i] = kDomFlags[i % 5];
        }

        /* Mapping qualities: Q0-Q60 */
        NSMutableData *mqData = [NSMutableData dataWithLength:nReads * sizeof(uint8_t)];
        uint8_t *mqPtr = (uint8_t *)mqData.mutableBytes;
        for (NSUInteger i = 0; i < nReads; i++) {
            mqPtr[i] = (uint8_t)(i % 61);
        }

        /* Sequences: ACGT pattern with 2% mutations (srand(42)) */
        const char kBases[] = "ACGT";
        NSUInteger totalBases = nReads * readLen;
        NSMutableData *seqData = [NSMutableData dataWithLength:totalBases];
        uint8_t *seqPtr = (uint8_t *)seqData.mutableBytes;
        srand(42);
        for (NSUInteger i = 0; i < totalBases; i++) {
            seqPtr[i] = (uint8_t)kBases[i % 4];
            if ((rand() % 50) == 0) {
                seqPtr[i] = (uint8_t)kBases[rand() % 4];
            }
        }

        /* Qualities: Q20-Q40, LCG seed 0xBEEF */
        NSMutableData *qualData = [NSMutableData dataWithLength:totalBases];
        uint8_t *qualPtr = (uint8_t *)qualData.mutableBytes;
        lcgState = 0xBEEF;
        for (NSUInteger i = 0; i < totalBases; i++) {
            lcgState = lcgState * 6364136223846793005ULL + 1442695040888963407ULL;
            qualPtr[i] = (uint8_t)(20 + (lcgState >> 33) % 21);
        }

        /* Offsets / lengths */
        NSMutableData *offData = [NSMutableData dataWithLength:nReads * sizeof(uint64_t)];
        NSMutableData *lenData = [NSMutableData dataWithLength:nReads * sizeof(uint32_t)];
        uint64_t *offPtr = (uint64_t *)offData.mutableBytes;
        uint32_t *lenPtr = (uint32_t *)lenData.mutableBytes;
        for (NSUInteger i = 0; i < nReads; i++) {
            offPtr[i] = (uint64_t)(i * readLen);
            lenPtr[i] = (uint32_t)readLen;
        }

        /* Per-read arrays */
        NSMutableArray *cigars     = [NSMutableArray arrayWithCapacity:nReads];
        NSMutableArray *readNames  = [NSMutableArray arrayWithCapacity:nReads];
        NSMutableArray *chroms     = [NSMutableArray arrayWithCapacity:nReads];
        NSMutableArray *mateChroms = [NSMutableArray arrayWithCapacity:nReads];
        NSMutableData *matePosData = [NSMutableData dataWithLength:nReads * sizeof(int64_t)];
        NSMutableData *tplLenData  = [NSMutableData dataWithLength:nReads * sizeof(int32_t)];
        int64_t *matePosPtr = (int64_t *)matePosData.mutableBytes;
        int32_t *tplLenPtr  = (int32_t *)tplLenData.mutableBytes;
        for (NSUInteger i = 0; i < nReads; i++) {
            [cigars addObject:@"100M"];
            [readNames addObject:[NSString stringWithFormat:@"M88_%08lu:001:01",
                                  (unsigned long)i]];
            [chroms addObject:@"chr1"];
            [mateChroms addObject:@"chr1"];
            matePosPtr[i] = posPtr[i] + (int64_t)readLen + 20;
            tplLenPtr[i]  = (int32_t)(readLen * 2 + 20);
        }

        TTIOWrittenGenomicRun *wgr = [[TTIOWrittenGenomicRun alloc]
            initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                       referenceUri:@"perf://ref/chr1"
                           platform:@"Illumina"
                         sampleName:@"perf-sample"
                           positions:posData
                    mappingQualities:mqData
                               flags:flagData
                           sequences:seqData
                           qualities:qualData
                             offsets:offData
                             lengths:lenData
                              cigars:cigars
                           readNames:readNames
                     mateChromosomes:mateChroms
                       matePositions:matePosData
                     templateLengths:tplLenData
                         chromosomes:chroms
                  signalCompression:TTIOCompressionZlib];

        /* B2: Write */
        NSError *err = nil;
        double t0 = nowSeconds();
        BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                     title:@"genomic-perf"
                                       isaInvestigationId:@"ISA-GENOMIC-PERF"
                                                   msRuns:@{}
                                               genomicRuns:@{@"r": wgr}
                                           identifications:nil
                                           quantifications:nil
                                         provenanceRecords:nil
                                                     error:&err];
        if (!ok) { NSLog(@"genomic write failed: %@", err); exit(1); }
        putSeconds(out, @"write", nowSeconds() - t0);

        NSDictionary *attrs = [[NSFileManager defaultManager]
            attributesOfItemAtPath:path error:NULL];
        putSeconds(out, @"write_mb",
                    ((NSNumber *)attrs[NSFileSize]).doubleValue / 1e6);

        /* B3: Sequential read-all (sampled) */
        t0 = nowSeconds();
        TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
        if (!ds) { NSLog(@"genomic read open failed: %@", err); exit(1); }
        TTIOGenomicRun *gr = ds.genomicRuns[@"r"];
        NSUInteger total = [gr readCount];
        NSUInteger step = MAX(1UL, total / 100);
        NSUInteger sampled = 0;
        for (NSUInteger i = 0; i < total; i += step) {
            TTIOAlignedRead *ar = [gr objectAtIndex:i];
            sampled += ar.sequence.length;
        }
        (void)sampled;
        [ds closeFile];
        putSeconds(out, @"read", nowSeconds() - t0);

        /* B4: Random access p50/p99 latency (1000 reads) */
        ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
        if (!ds) { NSLog(@"genomic ra open failed: %@", err); exit(1); }
        gr = ds.genomicRuns[@"r"];
        total = [gr readCount];

        const NSUInteger kRaSamples = 1000;
        srand(99);
        double *latencies = (double *)malloc(kRaSamples * sizeof(double));
        for (NSUInteger i = 0; i < kRaSamples; i++) {
            NSUInteger idx = (NSUInteger)((unsigned)rand() % (unsigned)total);
            double ts = nowSeconds();
            TTIOAlignedRead *ar = [gr objectAtIndex:idx];
            (void)ar.sequence;
            latencies[i] = nowSeconds() - ts;
        }
        [ds closeFile];

        qsort(latencies, kRaSamples, sizeof(double), cmp_double);
        putSeconds(out, @"random_access_p50", latencies[(NSUInteger)(kRaSamples * 0.50)]);
        putSeconds(out, @"random_access_p99", latencies[(NSUInteger)(kRaSamples * 0.99)]);
        free(latencies);
    }
}

/* B5: Encryption -- AES-256-GCM on 10 MiB payload */

static void bench_encryption_genomic(NSString *tmp, NSUInteger n, NSUInteger peaks,
                                      NSMutableDictionary *out)
{
    (void)tmp; (void)n; (void)peaks;
    @autoreleasepool {
        const NSUInteger payloadBytes = 10 * 1024 * 1024;

        NSMutableData *payload = [NSMutableData dataWithLength:payloadBytes];
        uint8_t *pp = payload.mutableBytes;
        srand(42);
        for (NSUInteger i = 0; i < payloadBytes; i++) {
            pp[i] = (uint8_t)(rand() & 0xFF);
        }

        uint8_t keyBytes[32];
        for (int i = 0; i < 32; i++) keyBytes[i] = (uint8_t)i;
        NSData *key = [NSData dataWithBytes:keyBytes length:32];

        NSError *err = nil;
        NSData *iv = nil, *tag = nil;

        double t0 = nowSeconds();
        NSData *ciphertext = [TTIOEncryptionManager encryptData:payload
                                                        withKey:key
                                                             iv:&iv
                                                        authTag:&tag
                                                          error:&err];
        if (!ciphertext) { NSLog(@"enc.genomic encrypt failed: %@", err); exit(1); }
        putSeconds(out, @"encrypt", nowSeconds() - t0);

        t0 = nowSeconds();
        NSData *plaintext = [TTIOEncryptionManager decryptData:ciphertext
                                                       withKey:key
                                                            iv:iv
                                                       authTag:tag
                                                         error:&err];
        if (!plaintext) { NSLog(@"enc.genomic decrypt failed: %@", err); exit(1); }
        putSeconds(out, @"decrypt", nowSeconds() - t0);

        putSeconds(out, @"bytes_mb", (double)payloadBytes / 1e6);
    }
}

/* B6: Streaming -- StreamWriter/StreamReader throughput */

static void bench_streaming(NSString *tmp, NSUInteger n, NSUInteger peaks,
                             NSMutableDictionary *out)
{
    @autoreleasepool {
        NSString *srcPath    = [tmp stringByAppendingPathComponent:@"stream-src.tio"];
        NSString *streamPath = [tmp stringByAppendingPathComponent:@"stream.tio"];
        unlink([srcPath fileSystemRepresentation]);
        unlink([streamPath fileSystemRepresentation]);

        TTIOWrittenRun *run = buildMsRun(n, peaks);
        NSError *err = nil;
        if (![TTIOSpectralDataset writeMinimalToPath:srcPath
                                                title:@"stream-src"
                                  isaInvestigationId:@"ISA-STREAM"
                                              msRuns:@{@"r": run}
                                      identifications:nil
                                      quantifications:nil
                                    provenanceRecords:nil
                                                error:&err]) {
            NSLog(@"streaming src write failed: %@", err); exit(1);
        }

        TTIOSpectralDataset *srcDs = [TTIOSpectralDataset readFromFilePath:srcPath error:&err];
        if (!srcDs) { NSLog(@"streaming src open failed: %@", err); exit(1); }
        TTIOAcquisitionRun *srcRun = srcDs.msRuns[@"r"];
        NSUInteger specCount = [srcRun count];

        TTIOInstrumentConfig *cfg = [[TTIOInstrumentConfig alloc]
            initWithManufacturer:@"PerfInstruments"
                           model:@"Bench-1"
                    serialNumber:@"SN-PERF"
                      sourceType:@"ESI"
                    analyzerType:@"Orbitrap"
                    detectorType:@"Detector"];

        /* B6 write */
        double t0 = nowSeconds();
        TTIOStreamWriter *writer = [[TTIOStreamWriter alloc]
            initWithFilePath:streamPath
                     runName:@"r"
             acquisitionMode:TTIOAcquisitionModeMS1DDA
            instrumentConfig:cfg
                       error:&err];
        if (!writer) { NSLog(@"StreamWriter init failed: %@", err); exit(1); }

        for (NSUInteger i = 0; i < specCount; i++) {
            TTIOMassSpectrum *sp = [srcRun objectAtIndex:i];
            if (![writer appendSpectrum:sp error:&err]) {
                NSLog(@"StreamWriter append %lu failed: %@", (unsigned long)i, err);
                exit(1);
            }
        }
        if (![writer flushAndCloseWithError:&err]) {
            NSLog(@"StreamWriter flush failed: %@", err); exit(1);
        }
        putSeconds(out, @"write", nowSeconds() - t0);
        [srcDs closeFile];

        /* B6 read */
        t0 = nowSeconds();
        TTIOStreamReader *reader = [[TTIOStreamReader alloc]
            initWithFilePath:streamPath
                     runName:@"r"
                       error:&err];
        if (!reader) { NSLog(@"StreamReader init failed: %@", err); exit(1); }

        NSUInteger readBack = 0;
        while (![reader atEnd]) {
            TTIOMassSpectrum *sp = [reader nextSpectrumWithError:&err];
            if (!sp) { NSLog(@"StreamReader next failed: %@", err); exit(1); }
            readBack += sp.signalArrays[@"mz"].length;
        }
        (void)readBack;
        [reader close];
        putSeconds(out, @"read", nowSeconds() - t0);
    }
}


/* ── codecs benchmark (P4 — perf workplan) ─────────────────────── */

#import "Codecs/TTIORans.h"
#import "Codecs/TTIOBasePack.h"
#import "Codecs/TTIOQuality.h"
#import "Codecs/TTIONameTokenizer.h"
#import "Codecs/TTIORefDiff.h"
#import "Codecs/TTIOFqzcompNx16Z.h"
#import "Codecs/TTIODeltaRans.h"
#include <openssl/md5.h>
#include <stdlib.h>
#include <stdint.h>

static void bench_codecs(NSString *tmp, NSUInteger n, NSUInteger peaks,
                          NSMutableDictionary *out)
{
    (void)tmp; (void)n; (void)peaks;
    @autoreleasepool {
        const NSUInteger oneMiB = 1024 * 1024;
        srand(42);

        // rANS: random bytes.
        NSMutableData *ransIn = [NSMutableData dataWithLength:oneMiB];
        unsigned char *p = ransIn.mutableBytes;
        for (NSUInteger i = 0; i < oneMiB; i++) p[i] = (unsigned char)rand();

        double t0 = nowSeconds();
        NSData *o0 = TTIORansEncode(ransIn, 0);
        putSeconds(out, @"rans_o0_encode", nowSeconds() - t0);
        t0 = nowSeconds();
        (void)TTIORansDecode(o0, NULL);
        putSeconds(out, @"rans_o0_decode", nowSeconds() - t0);

        t0 = nowSeconds();
        NSData *o1 = TTIORansEncode(ransIn, 1);
        putSeconds(out, @"rans_o1_encode", nowSeconds() - t0);
        t0 = nowSeconds();
        (void)TTIORansDecode(o1, NULL);
        putSeconds(out, @"rans_o1_decode", nowSeconds() - t0);

        // BASE_PACK on pure ACGT.
        const char alpha[] = "ACGT";
        NSMutableData *bpIn = [NSMutableData dataWithLength:oneMiB];
        unsigned char *bp = bpIn.mutableBytes;
        for (NSUInteger i = 0; i < oneMiB; i++) bp[i] = (unsigned char)alpha[rand() & 3];
        t0 = nowSeconds();
        NSData *bpEnc = TTIOBasePackEncode(bpIn);
        putSeconds(out, @"base_pack_encode", nowSeconds() - t0);
        t0 = nowSeconds();
        (void)TTIOBasePackDecode(bpEnc, NULL);
        putSeconds(out, @"base_pack_decode", nowSeconds() - t0);

        // QUALITY_BINNED on random Phred bytes.
        NSMutableData *qbIn = [NSMutableData dataWithLength:oneMiB];
        unsigned char *qb = qbIn.mutableBytes;
        for (NSUInteger i = 0; i < oneMiB; i++) qb[i] = (unsigned char)(rand() % 94);
        t0 = nowSeconds();
        NSData *qbEnc = TTIOQualityEncode(qbIn);
        putSeconds(out, @"quality_binned_encode", nowSeconds() - t0);
        t0 = nowSeconds();
        (void)TTIOQualityDecode(qbEnc, NULL);
        putSeconds(out, @"quality_binned_decode", nowSeconds() - t0);

        // NAME_TOKENIZED: 10K Illumina-style names.
        NSMutableArray *names = [NSMutableArray arrayWithCapacity:10000];
        for (NSUInteger i = 0; i < 10000; i++) {
            [names addObject:[NSString stringWithFormat:@"M88_%08lu:%03d:%02d",
                              (unsigned long)i, rand() % 1000, rand() % 100]];
        }
        t0 = nowSeconds();
        NSData *ntEnc = TTIONameTokenizerEncode(names);
        putSeconds(out, @"name_tokenized_encode", nowSeconds() - t0);
        t0 = nowSeconds();
        (void)TTIONameTokenizerDecode(ntEnc, NULL);
        putSeconds(out, @"name_tokenized_decode", nowSeconds() - t0);
    }
}

/* ── Genomic codecs benchmark (B1) ────────────────────────────── */

static int cmp_int64(const void *a, const void *b) {
    int64_t va = *(const int64_t *)a, vb = *(const int64_t *)b;
    return (va > vb) - (va < vb);
}

static void bench_codecs_genomic(NSString *tmp, NSUInteger n, NSUInteger peaks,
                                  NSMutableDictionary *out)
{
    (void)tmp; (void)n; (void)peaks;
    @autoreleasepool {
        NSError *err = nil;

        // ── REF_DIFF: 100K reads × 100bp against 100Kbp reference ──
        const NSUInteger rdNumReads = 100000;
        const NSUInteger rdReadLen  = 100;
        const NSUInteger rdRefLen   = 100000;

        // Build reference sequence (all 'A' for simplicity).
        NSMutableData *refSeqData = [NSMutableData dataWithLength:rdRefLen];
        memset(refSeqData.mutableBytes, 'A', rdRefLen);

        // Compute MD5 of reference.
        unsigned char refMd5Bytes[16];
        MD5(refSeqData.bytes, refSeqData.length, refMd5Bytes);
        NSData *refMd5 = [NSData dataWithBytes:refMd5Bytes length:16];

        // Build read sequences (all 100bp of 'A').
        NSMutableArray<NSData *> *sequences =
            [NSMutableArray arrayWithCapacity:rdNumReads];
        NSMutableArray<NSString *> *cigars =
            [NSMutableArray arrayWithCapacity:rdNumReads];
        NSMutableData *positions =
            [NSMutableData dataWithLength:rdNumReads * sizeof(int64_t)];
        int64_t *posPtr = (int64_t *)positions.mutableBytes;

        // LCG seed 0xBEEF for positions (1-based, clamped to ref).
        uint64_t lcgState = 0xBEEF;
        NSData *readSeq = [NSData dataWithBytes:refSeqData.bytes length:rdReadLen];
        srand(42);
        for (NSUInteger i = 0; i < rdNumReads; i++) {
            lcgState = lcgState * 6364136223846793005ULL + 1442695040888963407ULL;
            int64_t pos = (int64_t)((lcgState >> 17) % (rdRefLen - rdReadLen)) + 1;
            posPtr[i] = pos;
            // Apply a mutation with low probability using srand(42) sequence.
            if ((rand() % 20) == 0) {
                // Mutate one base at random position within read.
                NSMutableData *mutSeq = [NSMutableData dataWithData:readSeq];
                uint8_t *bp = mutSeq.mutableBytes;
                NSUInteger mpos = (NSUInteger)(rand() % (int)rdReadLen);
                const char bases[] = "ACGT";
                bp[mpos] = (uint8_t)bases[rand() % 4];
                [sequences addObject:mutSeq];
            } else {
                [sequences addObject:readSeq];
            }
            [cigars addObject:[NSString stringWithFormat:@"%luM",
                               (unsigned long)rdReadLen]];
        }

        double t0 = nowSeconds();
        NSData *rdEnc = [TTIORefDiff encodeWithSequences:sequences
                                                  cigars:cigars
                                               positions:positions
                                      referenceChromSeq:refSeqData
                                            referenceMD5:refMd5
                                            referenceURI:@"perf://ref/chr1"
                                                   error:&err];
        putSeconds(out, @"ref_diff_encode", nowSeconds() - t0);
        if (!rdEnc) { NSLog(@"ref_diff encode failed: %@", err); }

        if (rdEnc) {
            t0 = nowSeconds();
            (void)[TTIORefDiff decodeData:rdEnc
                                   cigars:cigars
                                positions:positions
                       referenceChromSeq:refSeqData
                                    error:&err];
            putSeconds(out, @"ref_diff_decode", nowSeconds() - t0);
            if (err) NSLog(@"ref_diff decode error: %@", err);
        } else {
            putSeconds(out, @"ref_diff_decode", 0.0);
        }

        // ── Quality test data: 100K × 100bp quality strings Q20-Q40 ─────
        const NSUInteger fqNumReads = 100000;
        const NSUInteger fqReadLen  = 100;
        const NSUInteger fqTotalQual = fqNumReads * fqReadLen;

        NSMutableData *qualities = [NSMutableData dataWithLength:fqTotalQual];
        uint8_t *qPtr = (uint8_t *)qualities.mutableBytes;
        lcgState = 0xBEEF;
        for (NSUInteger i = 0; i < fqTotalQual; i++) {
            lcgState = lcgState * 6364136223846793005ULL + 1442695040888963407ULL;
            qPtr[i] = (uint8_t)(20 + (lcgState >> 33) % 21); // Q20..Q40
        }

        NSMutableArray<NSNumber *> *readLengths =
            [NSMutableArray arrayWithCapacity:fqNumReads];
        for (NSUInteger i = 0; i < fqNumReads; i++) {
            [readLengths addObject:@((uint32_t)fqReadLen)];
        }

        // ── FQZCOMP_NX16_Z: same quality input, revcomp (i & 7) == 0 ─
        NSMutableArray<NSNumber *> *revcompFlagsMixed =
            [NSMutableArray arrayWithCapacity:fqNumReads];
        for (NSUInteger i = 0; i < fqNumReads; i++) {
            [revcompFlagsMixed addObject:@((i & 7) == 0 ? 1 : 0)];
        }

        t0 = nowSeconds();
        NSData *fqzEnc = [TTIOFqzcompNx16Z encodeWithQualities:qualities
                                                     readLengths:readLengths
                                                    revcompFlags:revcompFlagsMixed
                                                           error:&err];
        putSeconds(out, @"fqzcomp_nx16_z_encode", nowSeconds() - t0);
        if (!fqzEnc) { NSLog(@"fqzcomp_nx16_z encode failed: %@", err); }

        if (fqzEnc) {
            t0 = nowSeconds();
            (void)[TTIOFqzcompNx16Z decodeData:fqzEnc
                                   revcompFlags:revcompFlagsMixed
                                          error:&err];
            putSeconds(out, @"fqzcomp_nx16_z_decode", nowSeconds() - t0);
            if (err) NSLog(@"fqzcomp_nx16_z decode error: %@", err);
        } else {
            putSeconds(out, @"fqzcomp_nx16_z_decode", 0.0);
        }

        // ── DELTA_RANS: 1.25M sorted int64 positions ────────────────
        const NSUInteger drCount = 1250000;

        NSMutableData *drData =
            [NSMutableData dataWithLength:drCount * sizeof(int64_t)];
        int64_t *drPtr = (int64_t *)drData.mutableBytes;
        lcgState = 0xBEEF;
        int64_t pos = 0;
        for (NSUInteger i = 0; i < drCount; i++) {
            lcgState = lcgState * 6364136223846793005ULL + 1442695040888963407ULL;
            int64_t delta = 100 + (int64_t)((lcgState >> 33) % 401); // 100..500
            pos += delta;
            drPtr[i] = pos;
        }
        // Sort to ensure ascending order (LCG already produces that via
        // cumulative sum, but sort defensively).
        qsort(drPtr, drCount, sizeof(int64_t), cmp_int64);

        t0 = nowSeconds();
        NSData *drEnc = TTIODeltaRansEncode(drData, 8, &err);
        putSeconds(out, @"delta_rans_encode", nowSeconds() - t0);
        if (!drEnc) { NSLog(@"delta_rans encode failed: %@", err); }

        if (drEnc) {
            t0 = nowSeconds();
            (void)TTIODeltaRansDecode(drEnc, &err);
            putSeconds(out, @"delta_rans_decode", nowSeconds() - t0);
            if (err) NSLog(@"delta_rans decode error: %@", err);
        } else {
            putSeconds(out, @"delta_rans_decode", 0.0);
        }
    }
}

/* ── Registry + driver ─────────────────────────────────────────── */

typedef struct {
    const char *name;
    BenchFn fn;
} BenchEntry;

static BenchEntry kBenches[] = {
    { "ms.hdf5",              bench_ms_hdf5 },
    { "ms.memory",            bench_ms_other },
    { "ms.sqlite",            bench_ms_other },
    { "ms.zarr",              bench_ms_other },
    { "transport.plain",      bench_transport_plain },
    { "transport.compressed", bench_transport_compressed },
    { "encryption",           bench_encryption },
    { "signatures",           bench_signatures },
    { "jcamp",                bench_jcamp },
    { "spectra.build",        bench_spectra_build },
    { "codecs",               bench_codecs },
    { "codecs.genomic",       bench_codecs_genomic },
    { "genomic",              bench_genomic },
    { "encryption.genomic",   bench_encryption_genomic },
    { "streaming",            bench_streaming },
    { NULL, NULL }
};

static BOOL inSet(NSString *s, NSSet *set) {
    return set.count == 0 || [set containsObject:s];
}

static void printResult(const char *name, NSDictionary *res)
{
    printf("\n[%s]\n", name);
    for (NSString *k in res) {
        id v = res[k];
        if ([v isKindOfClass:[NSNull class]]) {
            printf("  %-20s       N/A (writer not implemented in ObjC v0.11.1)\n",
                   [k UTF8String]);
            continue;
        }
        double s = [(NSNumber *)v doubleValue];
        if ([k hasSuffix:@"_mb"]) {
            printf("  %-20s %10.2f MB\n", [k UTF8String], s);
        } else {
            printf("  %-20s %10.1f ms\n", [k UTF8String], s * 1000.0);
        }
    }
}

static NSString *jsonEscape(NSString *s)
{
    NSMutableString *m = [NSMutableString stringWithCapacity:s.length];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '"' || c == '\\') { [m appendFormat:@"\\%C", c]; }
        else if (c == '\n') { [m appendString:@"\\n"]; }
        else { [m appendFormat:@"%C", c]; }
    }
    return m;
}

static void writeJson(NSString *path, NSUInteger n, NSUInteger peaks,
                       NSDictionary *allResults)
{
    NSMutableString *j = [NSMutableString string];
    [j appendFormat:@"{\n  \"n\": %lu,\n  \"peaks\": %lu,\n  \"results\": {\n",
        (unsigned long)n, (unsigned long)peaks];
    NSArray *names = [allResults.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSUInteger i = 0; i < names.count; i++) {
        NSString *bn = names[i];
        NSDictionary *res = allResults[bn];
        [j appendFormat:@"    \"%@\": {", jsonEscape(bn)];
        NSArray *phases = res.allKeys;
        for (NSUInteger k = 0; k < phases.count; k++) {
            NSString *p = phases[k];
            id v = res[p];
            if ([v isKindOfClass:[NSNull class]]) {
                [j appendFormat:@"\"%@\": null", jsonEscape(p)];
            } else {
                [j appendFormat:@"\"%@\": %g", jsonEscape(p), [(NSNumber *)v doubleValue]];
            }
            if (k + 1 < phases.count) [j appendString:@", "];
        }
        [j appendFormat:@"}%@\n", (i + 1 < names.count) ? @"," : @""];
    }
    [j appendString:@"  }\n}\n"];
    [j writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSUInteger n = 10000;
        NSUInteger peaks = 16;
        NSMutableSet *only = [NSMutableSet set];
        NSMutableSet *skip = [NSMutableSet set];
        NSString *jsonPath = nil;
        NSString *outDir = nil;

        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--n") == 0 && i + 1 < argc) {
                n = (NSUInteger)atoll(argv[++i]);
            } else if (strcmp(argv[i], "--peaks") == 0 && i + 1 < argc) {
                peaks = (NSUInteger)atoll(argv[++i]);
            } else if (strcmp(argv[i], "--only") == 0 && i + 1 < argc) {
                NSString *s = [NSString stringWithUTF8String:argv[++i]];
                for (NSString *t in [s componentsSeparatedByString:@","]) {
                    NSString *tr = [t stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]];
                    if (tr.length) [only addObject:tr];
                }
            } else if (strcmp(argv[i], "--skip") == 0 && i + 1 < argc) {
                NSString *s = [NSString stringWithUTF8String:argv[++i]];
                for (NSString *t in [s componentsSeparatedByString:@","]) {
                    NSString *tr = [t stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]];
                    if (tr.length) [skip addObject:tr];
                }
            } else if (strcmp(argv[i], "--json") == 0 && i + 1 < argc) {
                jsonPath = [NSString stringWithUTF8String:argv[++i]];
            } else if (strcmp(argv[i], "--out") == 0 && i + 1 < argc) {
                outDir = [NSString stringWithUTF8String:argv[++i]];
            }
        }

        if (!outDir) {
            const char *home = getenv("HOME");
            outDir = [NSString stringWithFormat:@"%s/mpgo_profile_objc_full",
                       home ? home : "/tmp"];
        }
        [[NSFileManager defaultManager] createDirectoryAtPath:outDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];

        printf("==============================================================================\n");
        printf("ObjC multi-function perf  n=%lu  peaks=%lu\n",
               (unsigned long)n, (unsigned long)peaks);
        NSMutableArray *selected = [NSMutableArray array];
        for (int i = 0; kBenches[i].name; i++) {
            NSString *nm = [NSString stringWithUTF8String:kBenches[i].name];
            if (inSet(nm, only) && ![skip containsObject:nm]) {
                [selected addObject:nm];
            }
        }
        printf("  running: %s\n", [[selected componentsJoinedByString:@", "] UTF8String]);
        printf("==============================================================================\n");

        NSMutableDictionary *all = [NSMutableDictionary dictionary];
        for (int i = 0; kBenches[i].name; i++) {
            NSString *nm = [NSString stringWithUTF8String:kBenches[i].name];
            if (![selected containsObject:nm]) continue;

            NSString *tmp = [outDir stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"%@-%d",
                               [nm stringByReplacingOccurrencesOfString:@"." withString:@"-"],
                               (int)getpid()]];
            [[NSFileManager defaultManager] createDirectoryAtPath:tmp
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:NULL];
            NSMutableDictionary *res = [NSMutableDictionary dictionary];
            @try {
                kBenches[i].fn(tmp, n, peaks, res);
            } @catch (NSException *e) {
                printf("\n[%s] FAILED: %s\n",
                       [nm UTF8String], [e.reason UTF8String]);
                res[@"error"] = e.reason ?: @"exception";
            }
            all[nm] = res;
            printResult([nm UTF8String], res);
        }

        printf("\n==============================================================================\n");
        printf("SUMMARY (milliseconds)\n");
        printf("==============================================================================\n");
        for (NSString *nm in selected) {
            NSDictionary *res = all[nm];
            if (res[@"error"]) {
                printf("  %-28s FAILED: %s\n",
                       [nm UTF8String], [res[@"error"] UTF8String]);
                continue;
            }
            double total = 0.0;
            BOOL anyNA = NO;
            NSMutableString *phases = [NSMutableString string];
            for (NSString *p in res) {
                if ([p hasSuffix:@"_mb"]) continue;
                id v = res[p];
                if ([v isKindOfClass:[NSNull class]]) { anyNA = YES; continue; }
                double ms = [(NSNumber *)v doubleValue] * 1000.0;
                total += ms;
                [phases appendFormat:@"%@=%.1f  ", p, ms];
            }
            if (anyNA) {
                printf("  %-28s N/A (ObjC v0.11.1)\n", [nm UTF8String]);
            } else {
                printf("  %-28s total=%7.1f   %s\n",
                       [nm UTF8String], total, [phases UTF8String]);
            }
        }

        if (jsonPath) {
            writeJson(jsonPath, n, peaks, all);
            printf("\nJSON dump: %s\n", [jsonPath UTF8String]);
        }
    }
    return 0;
}
