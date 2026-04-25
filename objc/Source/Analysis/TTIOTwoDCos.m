#import "TTIOTwoDCos.h"
#import "Spectra/TTIOTwoDimensionalCorrelationSpectrum.h"
#import "HDF5/TTIOHDF5Errors.h"
#import <math.h>

@implementation TTIOTwoDCos

+ (NSData *)hilbertNodaMatrixOfOrder:(NSUInteger)m
                                error:(NSError **)error
{
    if (m < 1) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"TTIOTwoDCos: m must be >= 1, got %lu", (unsigned long)m);
        return nil;
    }
    NSUInteger bytes = (NSUInteger)(m * m * sizeof(double));
    NSMutableData *buf = [NSMutableData dataWithLength:bytes];
    double *n = (double *)[buf mutableBytes];
    for (NSUInteger j = 0; j < m; j++) {
        for (NSUInteger k = 0; k < m; k++) {
            if (j == k) {
                n[j * m + k] = 0.0;
            } else {
                double d = (double)k - (double)j;
                n[j * m + k] = 1.0 / (M_PI * d);
            }
        }
    }
    return buf;
}

+ (TTIOTwoDimensionalCorrelationSpectrum *)computeWithDynamicSpectra:(NSData *)dynamicSpectra
                                                    perturbationPoints:(NSUInteger)m
                                                     spectralVariables:(NSUInteger)n
                                                             reference:(NSData *)reference
                                                          variableAxis:(TTIOAxisDescriptor *)variableAxis
                                                          perturbation:(NSString *)perturbation
                                                      perturbationUnit:(NSString *)perturbationUnit
                                                        sourceModality:(NSString *)sourceModality
                                                                 error:(NSError **)error
{
    if (dynamicSpectra == nil) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"TTIOTwoDCos: dynamicSpectra must not be nil");
        return nil;
    }
    if (m < 2) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"TTIOTwoDCos: need >= 2 perturbation points, got m=%lu",
            (unsigned long)m);
        return nil;
    }
    if (n < 1) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"TTIOTwoDCos: n must be >= 1, got %lu", (unsigned long)n);
        return nil;
    }
    NSUInteger expected = (NSUInteger)(m * n * sizeof(double));
    if (dynamicSpectra.length != expected) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"TTIOTwoDCos: dynamicSpectra bytes %lu != m*n*8 = %lu",
            (unsigned long)dynamicSpectra.length, (unsigned long)expected);
        return nil;
    }
    NSUInteger refExpected = (NSUInteger)(n * sizeof(double));
    if (reference != nil && reference.length != refExpected) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"TTIOTwoDCos: reference bytes %lu != n*8 = %lu",
            (unsigned long)reference.length, (unsigned long)refExpected);
        return nil;
    }

    const double *a = (const double *)[dynamicSpectra bytes];

    // Reference spectrum (column-wise mean if not supplied).
    double *ref = (double *)calloc(n, sizeof(double));
    if (reference != nil) {
        memcpy(ref, [reference bytes], refExpected);
    } else {
        for (NSUInteger i = 0; i < m; i++) {
            const double *row = a + i * n;
            for (NSUInteger j = 0; j < n; j++) {
                ref[j] += row[j];
            }
        }
        double inv = 1.0 / (double)m;
        for (NSUInteger j = 0; j < n; j++) {
            ref[j] *= inv;
        }
    }

    // Mean-centered dynamic matrix.
    double *dyn = (double *)malloc((size_t)(m * n) * sizeof(double));
    for (NSUInteger i = 0; i < m; i++) {
        const double *srcRow = a + i * n;
        double *dstRow = dyn + i * n;
        for (NSUInteger j = 0; j < n; j++) {
            dstRow[j] = srcRow[j] - ref[j];
        }
    }
    free(ref);

    double scale = 1.0 / (double)(m - 1);

    // Synchronous matrix Phi[a, b] = scale * sum_i dyn[i, a] * dyn[i, b].
    NSUInteger n2 = (NSUInteger)(n * n);
    double *sync = (double *)calloc(n2, sizeof(double));
    for (NSUInteger aIdx = 0; aIdx < n; aIdx++) {
        for (NSUInteger bIdx = 0; bIdx < n; bIdx++) {
            double s = 0.0;
            for (NSUInteger i = 0; i < m; i++) {
                s += dyn[i * n + aIdx] * dyn[i * n + bIdx];
            }
            sync[aIdx * n + bIdx] = scale * s;
        }
    }

    // tmp = N @ dyn, m x n; fold N formula into the multiply.
    double *tmp = (double *)calloc((size_t)(m * n), sizeof(double));
    double invPi = 1.0 / M_PI;
    for (NSUInteger j = 0; j < m; j++) {
        for (NSUInteger col = 0; col < n; col++) {
            double s = 0.0;
            for (NSUInteger k = 0; k < m; k++) {
                if (k == j) continue;
                double w = invPi / ((double)k - (double)j);
                s += w * dyn[k * n + col];
            }
            tmp[j * n + col] = s;
        }
    }

    // Psi = scale * dyn^T @ tmp.
    double *async = (double *)calloc(n2, sizeof(double));
    for (NSUInteger aIdx = 0; aIdx < n; aIdx++) {
        for (NSUInteger bIdx = 0; bIdx < n; bIdx++) {
            double s = 0.0;
            for (NSUInteger i = 0; i < m; i++) {
                s += dyn[i * n + aIdx] * tmp[i * n + bIdx];
            }
            async[aIdx * n + bIdx] = scale * s;
        }
    }
    free(dyn);
    free(tmp);

    NSUInteger outBytes = n2 * sizeof(double);
    NSData *syncData = [NSData dataWithBytesNoCopy:sync
                                             length:outBytes
                                       freeWhenDone:YES];
    NSData *asyncData = [NSData dataWithBytesNoCopy:async
                                              length:outBytes
                                        freeWhenDone:YES];

    return [[TTIOTwoDimensionalCorrelationSpectrum alloc]
            initWithSynchronousMatrix:syncData
                   asynchronousMatrix:asyncData
                           matrixSize:n
                         variableAxis:variableAxis
                         perturbation:perturbation ?: @""
                     perturbationUnit:perturbationUnit ?: @""
                       sourceModality:sourceModality ?: @""
                        indexPosition:0
                                error:error];
}

+ (NSData *)disrelationSpectrumFromSynchronous:(NSData *)synchronous
                                   asynchronous:(NSData *)asynchronous
                                          error:(NSError **)error
{
    if (synchronous == nil || asynchronous == nil) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"TTIOTwoDCos: matrices must not be nil");
        return nil;
    }
    if (synchronous.length != asynchronous.length) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"TTIOTwoDCos: shape mismatch %lu vs %lu",
            (unsigned long)synchronous.length,
            (unsigned long)asynchronous.length);
        return nil;
    }
    NSUInteger count = synchronous.length / sizeof(double);
    const double *s = (const double *)[synchronous bytes];
    const double *a = (const double *)[asynchronous bytes];
    NSMutableData *buf = [NSMutableData dataWithLength:count * sizeof(double)];
    double *out = (double *)[buf mutableBytes];
    for (NSUInteger i = 0; i < count; i++) {
        double num = fabs(s[i]);
        double denom = num + fabs(a[i]);
        out[i] = (denom > 0.0) ? (num / denom) : (double)NAN;
    }
    return buf;
}

@end
