#import <Foundation/Foundation.h>
#import "Testing.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Dataset.h"
#import "HDF5/TTIOHDF5Errors.h"
#import "ValueClasses/TTIOEnums.h"
#import <math.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *tempPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_test_%d_%@.tio",
            (int)getpid(), suffix];
}

static BOOL fileExistsAt(NSString *path)
{
    struct stat st;
    return stat([path fileSystemRepresentation], &st) == 0;
}

void testHDF5(void)
{
    // ---- create / close / file exists on disk ----
    {
        NSString *path = tempPath(@"create");
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        TTIOHDF5File *f = [TTIOHDF5File createAtPath:path error:&err];
        PASS(f != nil, "TTIOHDF5File +createAtPath: succeeds");
        PASS(err == nil, "no error on create");
        PASS([f close], "explicit close returns YES");
        PASS(fileExistsAt(path), "created file exists on disk");
        unlink([path fileSystemRepresentation]);
    }

    // ---- open nonexistent → nil + NSError ----
    {
        NSString *path = @"/tmp/ttio_test_does_not_exist.tio";
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        TTIOHDF5File *f = [TTIOHDF5File openAtPath:path error:&err];
        PASS(f == nil, "open nonexistent returns nil");
        PASS(err != nil, "open nonexistent populates NSError");
        PASS([err.domain isEqualToString:TTIOErrorDomain], "error domain is TTIOErrorDomain");
        PASS(err.code == TTIOErrorFileNotFound, "error code is FileNotFound");
    }

    // ---- float64 round-trip, 1e-12 epsilon ----
    {
        NSString *path = tempPath(@"float64");
        NSError *err = nil;
        TTIOHDF5File *f = [TTIOHDF5File createAtPath:path error:&err];
        TTIOHDF5Group *root = [f rootGroup];

        const NSUInteger N = 256;
        double *src = malloc(N * sizeof(double));
        for (NSUInteger i = 0; i < N; i++) src[i] = sin((double)i * 0.01) * 1e6;

        TTIOHDF5Dataset *ds = [root createDatasetNamed:@"floats"
                                             precision:TTIOPrecisionFloat64
                                                length:N
                                             chunkSize:64
                                      compressionLevel:6
                                                 error:&err];
        PASS(ds != nil, "create chunked+compressed float64 dataset");
        PASS([ds writeData:[NSData dataWithBytes:src length:N*sizeof(double)] error:&err],
             "write float64 dataset");
        [f close];

        TTIOHDF5File *g = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
        TTIOHDF5Dataset *rd = [[g rootGroup] openDatasetNamed:@"floats" error:&err];
        PASS(rd != nil, "reopen + open float64 dataset");
        PASS(rd.length == N, "round-tripped length matches");
        PASS(rd.precision == TTIOPrecisionFloat64, "precision detected on open");

        NSData *back = [rd readDataWithError:&err];
        PASS(back.length == N * sizeof(double), "read returns full byte length");
        const double *r = back.bytes;
        BOOL ok = YES;
        for (NSUInteger i = 0; i < N; i++) {
            if (fabs(r[i] - src[i]) > 1e-12) { ok = NO; break; }
        }
        PASS(ok, "float64 values round-trip within 1e-12 epsilon");
        free(src);
        [g close];
        unlink([path fileSystemRepresentation]);
    }

    // ---- chunked + compressed int32 byte-exact ----
    {
        NSString *path = tempPath(@"int32");
        NSError *err = nil;
        TTIOHDF5File *f = [TTIOHDF5File createAtPath:path error:&err];
        const NSUInteger N = 1024;
        int32_t *src = malloc(N * sizeof(int32_t));
        for (NSUInteger i = 0; i < N; i++) src[i] = (int32_t)(i * 7 - 100);
        TTIOHDF5Dataset *ds = [[f rootGroup] createDatasetNamed:@"ints"
                                                       precision:TTIOPrecisionInt32
                                                          length:N
                                                       chunkSize:128
                                                compressionLevel:9
                                                           error:&err];
        [ds writeData:[NSData dataWithBytes:src length:N*sizeof(int32_t)] error:&err];
        [f close];

        TTIOHDF5File *g = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
        TTIOHDF5Dataset *rd = [[g rootGroup] openDatasetNamed:@"ints" error:&err];
        NSData *back = [rd readDataWithError:&err];
        PASS(memcmp(back.bytes, src, N * sizeof(int32_t)) == 0,
             "chunked+compressed int32 round-trips byte-exact");
        free(src);
        [g close];
        unlink([path fileSystemRepresentation]);
    }

    // ---- complex128 compound type ----
    {
        NSString *path = tempPath(@"complex");
        NSError *err = nil;
        TTIOHDF5File *f = [TTIOHDF5File createAtPath:path error:&err];
        const NSUInteger N = 64;
        double *src = malloc(N * 2 * sizeof(double)); // interleaved real,imag
        for (NSUInteger i = 0; i < N; i++) {
            src[2*i]     = (double)i * 0.5;
            src[2*i + 1] = -(double)i * 0.25;
        }
        TTIOHDF5Dataset *ds = [[f rootGroup] createDatasetNamed:@"cplx"
                                                       precision:TTIOPrecisionComplex128
                                                          length:N
                                                       chunkSize:0
                                                compressionLevel:0
                                                           error:&err];
        PASS(ds != nil, "create complex128 dataset");
        PASS([ds writeData:[NSData dataWithBytes:src length:N*2*sizeof(double)] error:&err],
             "write complex128");
        [f close];

        TTIOHDF5File *g = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
        TTIOHDF5Dataset *rd = [[g rootGroup] openDatasetNamed:@"cplx" error:&err];
        PASS(rd.precision == TTIOPrecisionComplex128, "complex128 precision detected");
        NSData *back = [rd readDataWithError:&err];
        const double *r = back.bytes;
        BOOL ok = YES;
        for (NSUInteger i = 0; i < N; i++) {
            if (r[2*i]     != src[2*i])     { ok = NO; break; }
            if (r[2*i + 1] != src[2*i + 1]) { ok = NO; break; }
        }
        PASS(ok, "complex128 real and imaginary components both intact");
        free(src);
        [g close];
        unlink([path fileSystemRepresentation]);
    }

    // ---- partial (hyperslab) read ----
    {
        NSString *path = tempPath(@"hyperslab");
        NSError *err = nil;
        TTIOHDF5File *f = [TTIOHDF5File createAtPath:path error:&err];
        const NSUInteger N = 1000;
        double *src = malloc(N * sizeof(double));
        for (NSUInteger i = 0; i < N; i++) src[i] = (double)i;
        TTIOHDF5Dataset *ds = [[f rootGroup] createDatasetNamed:@"line"
                                                       precision:TTIOPrecisionFloat64
                                                          length:N
                                                       chunkSize:128
                                                compressionLevel:0
                                                           error:&err];
        [ds writeData:[NSData dataWithBytes:src length:N*sizeof(double)] error:&err];
        [f close];

        TTIOHDF5File *g = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
        TTIOHDF5Dataset *rd = [[g rootGroup] openDatasetNamed:@"line" error:&err];
        NSData *slice = [rd readDataAtOffset:500 count:100 error:&err];
        PASS(slice.length == 100 * sizeof(double), "hyperslab returns 100 doubles");
        const double *sp = slice.bytes;
        BOOL ok = YES;
        for (NSUInteger i = 0; i < 100; i++) {
            if (sp[i] != (double)(500 + i)) { ok = NO; break; }
        }
        PASS(ok, "hyperslab values are 500..599");

        // Out-of-range hyperslab → nil + error
        NSError *err2 = nil;
        NSData *bad = [rd readDataAtOffset:990 count:100 error:&err2];
        PASS(bad == nil, "out-of-range hyperslab returns nil");
        PASS(err2 != nil && err2.code == TTIOErrorOutOfRange,
             "out-of-range hyperslab populates OutOfRange error");

        free(src);
        [g close];
        unlink([path fileSystemRepresentation]);
    }

    // ---- benchmark: 1M float64 write + read ----
    {
        NSString *path = tempPath(@"bench");
        NSError *err = nil;
        const NSUInteger N = 1000000;
        double *src = malloc(N * sizeof(double));
        for (NSUInteger i = 0; i < N; i++) src[i] = (double)i * 0.001;
        NSData *data = [NSData dataWithBytesNoCopy:src
                                            length:N*sizeof(double)
                                      freeWhenDone:NO];

        TTIOHDF5File *f = [TTIOHDF5File createAtPath:path error:&err];
        TTIOHDF5Dataset *ds = [[f rootGroup] createDatasetNamed:@"big"
                                                       precision:TTIOPrecisionFloat64
                                                          length:N
                                                       chunkSize:16384
                                                compressionLevel:0
                                                           error:&err];
        NSDate *t0 = [NSDate date];
        [ds writeData:data error:&err];
        NSTimeInterval writeMs = -[t0 timeIntervalSinceNow] * 1000.0;
        [f close];

        TTIOHDF5File *g = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
        TTIOHDF5Dataset *rd = [[g rootGroup] openDatasetNamed:@"big" error:&err];
        NSDate *t1 = [NSDate date];
        NSData *back = [rd readDataWithError:&err];
        NSTimeInterval readMs = -[t1 timeIntervalSinceNow] * 1000.0;

        printf("    [bench] 1M float64 write %.1f ms, read %.1f ms\n", writeMs, readMs);
        PASS(back.length == N * sizeof(double), "1M element read returned full buffer");
        PASS(writeMs < 100.0, "1M float64 write < 100 ms");
        PASS(readMs  < 100.0, "1M float64 read < 100 ms");

        free(src);
        [g close];
        unlink([path fileSystemRepresentation]);
    }
}
