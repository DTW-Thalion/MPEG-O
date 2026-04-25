#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Analysis/TTIOTwoDCos.h"
#import "Spectra/TTIOTwoDimensionalCorrelationSpectrum.h"
#import "ValueClasses/TTIOAxisDescriptor.h"
#import <math.h>
#import <stdlib.h>
#import <string.h>

// M77 unit tests + cross-language conformance gate for the ObjC
// 2D-COS compute primitives (Analysis/TTIOTwoDCos).

static NSString *m77ConformanceDir(void)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *here = [fm currentDirectoryPath];
    for (int up = 0; up < 6; up++) {
        NSString *candidate = [[here
                stringByAppendingPathComponent:@"conformance"]
                stringByAppendingPathComponent:@"two_d_cos"];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:candidate isDirectory:&isDir] && isDir) {
            return candidate;
        }
        here = [here stringByDeletingLastPathComponent];
        if ([here isEqualToString:@"/"] || here.length == 0) break;
    }
    return nil;
}

// Parse a CSV file (one row per line, comma-separated float64 values)
// into a flat row-major double array. Returns NO on shape mismatch.
static BOOL readCsvMatrix(NSString *path,
                          NSMutableData **outData,
                          NSUInteger *outRows,
                          NSUInteger *outCols)
{
    NSError *err = nil;
    NSString *text = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:&err];
    if (!text) {
        NSLog(@"readCsvMatrix: %@: %@", path, err);
        return NO;
    }
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:
                                  [NSCharacterSet newlineCharacterSet]];
    NSMutableArray<NSArray<NSNumber *> *> *rows = [NSMutableArray array];
    for (NSString *raw in lines) {
        NSString *trimmed = [raw stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0) continue;
        NSArray<NSString *> *cols = [trimmed componentsSeparatedByString:@","];
        NSMutableArray<NSNumber *> *rowVals = [NSMutableArray arrayWithCapacity:cols.count];
        for (NSString *c in cols) {
            [rowVals addObject:@([c doubleValue])];
        }
        [rows addObject:rowVals];
    }
    if (rows.count == 0) return NO;
    NSUInteger m = rows.count;
    NSUInteger n = rows[0].count;
    for (NSArray *r in rows) {
        if (r.count != n) return NO;
    }
    NSMutableData *buf = [NSMutableData dataWithLength:m * n * sizeof(double)];
    double *b = (double *)buf.mutableBytes;
    for (NSUInteger i = 0; i < m; i++) {
        for (NSUInteger j = 0; j < n; j++) {
            b[i * n + j] = [rows[i][j] doubleValue];
        }
    }
    *outData = buf;
    *outRows = m;
    *outCols = n;
    return YES;
}

static BOOL allclose(const double *actual, const double *expected,
                      NSUInteger count, double rtol, double atol,
                      const char *label)
{
    for (NSUInteger i = 0; i < count; i++) {
        double tol = atol + rtol * fabs(expected[i]);
        double diff = fabs(actual[i] - expected[i]);
        if (diff > tol) {
            NSLog(@"%s[%lu] mismatch: %.17g vs %.17g (diff=%g, tol=%g)",
                  label, (unsigned long)i, actual[i], expected[i], diff, tol);
            return NO;
        }
    }
    return YES;
}

static void testHilbertNodaMatrix(void)
{
    NSError *err = nil;
    NSData *n = [TTIOTwoDCos hilbertNodaMatrixOfOrder:8 error:&err];
    pass(n != nil && err == nil, "hilbertNodaMatrix(8) built");
    pass(n.length == 8 * 8 * sizeof(double), "hilbertNodaMatrix(8) byte length");
    const double *v = (const double *)n.bytes;
    // Diagonal zeros.
    for (NSUInteger j = 0; j < 8; j++) {
        if (v[j * 8 + j] != 0.0) {
            pass(NO, "hilbertNodaMatrix diagonal zero at %lu", (unsigned long)j);
            return;
        }
    }
    pass(YES, "hilbertNodaMatrix diagonal is zero");
    // Antisymmetry.
    for (NSUInteger j = 0; j < 8; j++) {
        for (NSUInteger k = 0; k < 8; k++) {
            if (fabs(v[j * 8 + k] + v[k * 8 + j]) > 1e-15) {
                pass(NO, "hilbertNodaMatrix antisymmetry at (%lu,%lu)",
                     (unsigned long)j, (unsigned long)k);
                return;
            }
        }
    }
    pass(YES, "hilbertNodaMatrix is antisymmetric");
    // Known entry.
    NSData *n4 = [TTIOTwoDCos hilbertNodaMatrixOfOrder:4 error:NULL];
    const double *v4 = (const double *)n4.bytes;
    pass(fabs(v4[0 * 4 + 1] - 1.0 / M_PI) < 1e-15,
         "hilbertNodaMatrix(4)[0,1] == 1/pi");
    pass(fabs(v4[0 * 4 + 3] - 1.0 / (3.0 * M_PI)) < 1e-15,
         "hilbertNodaMatrix(4)[0,3] == 1/(3*pi)");

    NSError *badErr = nil;
    NSData *bad = [TTIOTwoDCos hilbertNodaMatrixOfOrder:0 error:&badErr];
    pass(bad == nil && badErr != nil,
         "hilbertNodaMatrix(0) rejects");
}

static void testComputeConstantInput(void)
{
    NSUInteger m = 6, n = 12;
    NSMutableData *dynBuf = [NSMutableData dataWithLength:m * n * sizeof(double)];
    double *d = (double *)dynBuf.mutableBytes;
    for (NSUInteger i = 0; i < m; i++) {
        for (NSUInteger j = 0; j < n; j++) {
            d[i * n + j] = sin(M_PI * (double)j / (double)(n - 1));
        }
    }
    NSError *err = nil;
    TTIOTwoDimensionalCorrelationSpectrum *spec =
        [TTIOTwoDCos computeWithDynamicSpectra:dynBuf
                            perturbationPoints:m
                             spectralVariables:n
                                     reference:nil
                                  variableAxis:nil
                                  perturbation:nil
                              perturbationUnit:nil
                                sourceModality:nil
                                         error:&err];
    pass(spec != nil && err == nil, "compute(constant) returns spectrum");
    const double *sync = (const double *)spec.synchronousMatrix.bytes;
    const double *async = (const double *)spec.asynchronousMatrix.bytes;
    BOOL allZero = YES;
    for (NSUInteger i = 0; i < n * n; i++) {
        if (fabs(sync[i]) > 1e-12 || fabs(async[i]) > 1e-12) {
            allZero = NO;
            break;
        }
    }
    pass(allZero, "compute(constant) yields zero sync+async");
}

static void testComputeStructuralInvariants(void)
{
    NSUInteger m = 10, n = 8;
    NSMutableData *dynBuf = [NSMutableData dataWithLength:m * n * sizeof(double)];
    double *d = (double *)dynBuf.mutableBytes;
    uint64_t seed = 0xC0FFEEULL;
    for (NSUInteger i = 0; i < m * n; i++) {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        d[i] = ((int32_t)(seed >> 33)) * (1.0 / (double)(1LL << 31));
    }
    NSError *err = nil;
    TTIOTwoDimensionalCorrelationSpectrum *spec =
        [TTIOTwoDCos computeWithDynamicSpectra:dynBuf
                            perturbationPoints:m
                             spectralVariables:n
                                     reference:nil
                                  variableAxis:nil
                                  perturbation:nil
                              perturbationUnit:nil
                                sourceModality:nil
                                         error:&err];
    pass(spec != nil, "compute(random-ish) returns spectrum");
    const double *sync = (const double *)spec.synchronousMatrix.bytes;
    const double *async = (const double *)spec.asynchronousMatrix.bytes;
    BOOL symOK = YES, antiOK = YES;
    for (NSUInteger a = 0; a < n; a++) {
        for (NSUInteger b = 0; b < n; b++) {
            if (fabs(sync[a * n + b] - sync[b * n + a]) > 1e-12) symOK = NO;
            if (fabs(async[a * n + b] + async[b * n + a]) > 1e-12) antiOK = NO;
        }
    }
    pass(symOK, "synchronous matrix is symmetric");
    pass(antiOK, "asynchronous matrix is antisymmetric");
}

static void testComputeRejects(void)
{
    NSError *err = nil;
    NSMutableData *buf = [NSMutableData dataWithLength:5 * sizeof(double)];
    TTIOTwoDimensionalCorrelationSpectrum *spec =
        [TTIOTwoDCos computeWithDynamicSpectra:buf
                            perturbationPoints:1
                             spectralVariables:5
                                     reference:nil
                                  variableAxis:nil
                                  perturbation:nil
                              perturbationUnit:nil
                                sourceModality:nil
                                         error:&err];
    pass(spec == nil && err != nil, "compute rejects m<2");

    err = nil;
    NSMutableData *buf2 = [NSMutableData dataWithLength:20 * sizeof(double)];
    spec = [TTIOTwoDCos computeWithDynamicSpectra:buf2
                              perturbationPoints:3
                               spectralVariables:4
                                       reference:nil
                                    variableAxis:nil
                                    perturbation:nil
                                perturbationUnit:nil
                                  sourceModality:nil
                                           error:&err];
    pass(spec == nil && err != nil,
         "compute rejects length mismatch (20 != 3*4)");

    err = nil;
    NSMutableData *dynOk = [NSMutableData dataWithLength:4 * 5 * sizeof(double)];
    NSMutableData *refBad = [NSMutableData dataWithLength:7 * sizeof(double)];
    spec = [TTIOTwoDCos computeWithDynamicSpectra:dynOk
                              perturbationPoints:4
                               spectralVariables:5
                                       reference:refBad
                                    variableAxis:nil
                                    perturbation:nil
                                perturbationUnit:nil
                                  sourceModality:nil
                                           error:&err];
    pass(spec == nil && err != nil, "compute rejects bad reference length");
}

static void testDisrelation(void)
{
    double syncVals[] = { 1.0, 0.0, 3.0, 0.0 };
    double asyncVals[] = { 1.0, 0.0, 1.0, 0.0 };
    NSData *s = [NSData dataWithBytes:syncVals length:sizeof(syncVals)];
    NSData *a = [NSData dataWithBytes:asyncVals length:sizeof(asyncVals)];
    NSError *err = nil;
    NSData *d = [TTIOTwoDCos disrelationSpectrumFromSynchronous:s
                                                    asynchronous:a
                                                           error:&err];
    pass(d != nil && err == nil, "disrelation computes");
    const double *v = (const double *)d.bytes;
    pass(fabs(v[0] - 0.5) < 1e-15, "disrelation[0] == 0.5");
    pass(isnan(v[1]), "disrelation[1] NaN on zero denominator");
    pass(fabs(v[2] - 0.75) < 1e-15, "disrelation[2] == 0.75");
    pass(isnan(v[3]), "disrelation[3] NaN on zero denominator");

    NSData *bad = [NSData dataWithBytes:syncVals length:sizeof(syncVals) / 2];
    err = nil;
    NSData *dm = [TTIOTwoDCos disrelationSpectrumFromSynchronous:s
                                                     asynchronous:bad
                                                            error:&err];
    pass(dm == nil && err != nil, "disrelation rejects shape mismatch");
}

static void testConformanceFixture(void)
{
    NSString *dir = m77ConformanceDir();
    if (!dir) {
        pass(YES, "skip: conformance/two_d_cos not reachable from CWD");
        return;
    }
    NSMutableData *dynBuf = nil, *syncBuf = nil, *asyncBuf = nil;
    NSUInteger m = 0, n = 0, sN = 0, aN = 0, unused = 0;
    BOOL ok = readCsvMatrix([dir stringByAppendingPathComponent:@"dynamic.csv"],
                            &dynBuf, &m, &n);
    pass(ok, "read dynamic.csv");
    ok = readCsvMatrix([dir stringByAppendingPathComponent:@"sync.csv"],
                       &syncBuf, &sN, &unused);
    pass(ok && sN == unused && sN == n, "read sync.csv shape");
    ok = readCsvMatrix([dir stringByAppendingPathComponent:@"async.csv"],
                       &asyncBuf, &aN, &unused);
    pass(ok && aN == unused && aN == n, "read async.csv shape");

    NSError *err = nil;
    TTIOTwoDimensionalCorrelationSpectrum *spec =
        [TTIOTwoDCos computeWithDynamicSpectra:dynBuf
                            perturbationPoints:m
                             spectralVariables:n
                                     reference:nil
                                  variableAxis:nil
                                  perturbation:nil
                              perturbationUnit:nil
                                sourceModality:nil
                                         error:&err];
    pass(spec != nil && err == nil, "conformance compute succeeds");

    BOOL syncOK = allclose((const double *)spec.synchronousMatrix.bytes,
                            (const double *)syncBuf.bytes,
                            n * n, 1e-9, 1e-12, "synchronous");
    pass(syncOK, "byte-level synchronous matches (rtol=1e-9, atol=1e-12)");
    BOOL asyncOK = allclose((const double *)spec.asynchronousMatrix.bytes,
                             (const double *)asyncBuf.bytes,
                             n * n, 1e-9, 1e-12, "asynchronous");
    pass(asyncOK, "byte-level asynchronous matches (rtol=1e-9, atol=1e-12)");
}

void testMilestone77(void)
{
    testHilbertNodaMatrix();
    testComputeConstantInput();
    testComputeStructuralInvariants();
    testComputeRejects();
    testDisrelation();
    testConformanceFixture();
}
