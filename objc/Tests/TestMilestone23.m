// Milestone 23: Thread safety on MPGOHDF5File.
//
// Exercises:
//   * -isThreadSafe reflects H5is_library_threadsafe() AND rwlock init
//   * Concurrent readers do not crash and observe consistent data
//   * Writers block readers (a waiting reader cannot complete while a
//     writer is inside its critical section)
//
// NB: we use pthreads directly rather than NSThread for deterministic
// timing. Testing.h's PASS macro is not thread-safe; the worker threads
// only set atomic flags and the main thread runs the PASS() assertions.
//
// The test tool uses MRC (per build flags), so no __bridge / no ARC
// retain-releases in the worker function.

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "HDF5/MPGOHDF5File.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Dataset.h"
#import "HDF5/MPGOHDF5Errors.h"
#import "ValueClasses/MPGOEnums.h"
#import <pthread.h>
#import <unistd.h>
#import <sys/stat.h>

static NSString *m23TempPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_test_m23_%d_%@.mpgo",
            (int)getpid(), suffix];
}

// ---------------------------------------------------------------- worker ctx

typedef struct {
    MPGOHDF5Dataset *ds;
    NSUInteger       length;
    int              iterations;
    volatile int     ok;      // 1 on all reads success
    volatile int     done;    // 1 once worker returned
} M23ReaderCtx;

static void *m23_reader_thread(void *arg)
{
    M23ReaderCtx *c = (M23ReaderCtx *)arg;
    int ok = 1;
    for (int i = 0; i < c->iterations; i++) {
        NSError *err = nil;
        NSData *d = [c->ds readDataWithError:&err];
        if (!d || d.length != c->length * sizeof(double)) { ok = 0; break; }
        // Validate first / last values so we'd notice torn reads
        const double *p = (const double *)d.bytes;
        if (p[0] != 0.0 || p[c->length - 1] != (double)(c->length - 1)) {
            ok = 0; break;
        }
    }
    c->ok = ok;
    c->done = 1;
    return NULL;
}

// ------------------------- writer-holds, reader-waits ---------------------

typedef struct {
    MPGOHDF5File *file;
    volatile int  acquired;   // 1 once the reader-side lock is held
    volatile int  done;
} M23LockCtx;

static void *m23_try_read_lock(void *arg)
{
    M23LockCtx *c = (M23LockCtx *)arg;
    [c->file lockForReading];
    c->acquired = 1;
    [c->file unlockForReading];
    c->done = 1;
    return NULL;
}

void testMilestone23(void)
{
    // ---- -isThreadSafe reports a consistent value ----
    {
        NSString *path = m23TempPath(@"ts");
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        MPGOHDF5File *f = [MPGOHDF5File createAtPath:path error:&err];
        PASS(f != nil, "M23: create file for thread-safety probe");
        BOOL ts = [f isThreadSafe];
        // We only assert the call doesn't crash; the answer depends on the
        // linked libhdf5. CI logs the value so unsafe builds are obvious.
        NSLog(@"M23: isThreadSafe=%@", ts ? @"YES" : @"NO");
        PASS([f close], "M23: close after probe");
        unlink([path fileSystemRepresentation]);
    }

    // ---- concurrent readers: 4 threads x 50 reads of a 1000-double dataset ----
    {
        NSString *path = m23TempPath(@"concread");
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        MPGOHDF5File *f = [MPGOHDF5File createAtPath:path error:&err];
        PASS(f != nil, "M23: create file for concurrent reads");

        MPGOHDF5Group *root = [f rootGroup];
        PASS(root != nil, "M23: root group");

        NSUInteger N = 1000;
        MPGOHDF5Dataset *ds = [root createDatasetNamed:@"x"
                                             precision:MPGOPrecisionFloat64
                                                length:N
                                             chunkSize:0
                                      compressionLevel:0
                                                 error:&err];
        PASS(ds != nil, "M23: create dataset");

        double *buf = (double *)malloc(N * sizeof(double));
        for (NSUInteger i = 0; i < N; i++) buf[i] = (double)i;
        NSData *in = [NSData dataWithBytesNoCopy:buf length:N*sizeof(double) freeWhenDone:YES];
        PASS([ds writeData:in error:&err], "M23: write dataset");

        enum { NTHREADS = 4 };
        pthread_t tids[NTHREADS];
        M23ReaderCtx ctxs[NTHREADS];
        for (int t = 0; t < NTHREADS; t++) {
            ctxs[t].ds = ds;
            ctxs[t].length = N;
            ctxs[t].iterations = 50;
            ctxs[t].ok = 0;
            ctxs[t].done = 0;
            pthread_create(&tids[t], NULL, m23_reader_thread, &ctxs[t]);
        }
        for (int t = 0; t < NTHREADS; t++) {
            pthread_join(tids[t], NULL);
        }
        int allOK = 1;
        for (int t = 0; t < NTHREADS; t++) {
            if (!ctxs[t].ok) { allOK = 0; break; }
        }
        PASS(allOK == 1, "M23: 4 threads x 50 concurrent reads all succeed");

        PASS([f close], "M23: close after concurrent reads");
        unlink([path fileSystemRepresentation]);
    }

    // ---- writer holds → reader blocks ----
    {
        NSString *path = m23TempPath(@"wblock");
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        MPGOHDF5File *f = [MPGOHDF5File createAtPath:path error:&err];
        PASS(f != nil, "M23: create file for write-blocks test");

        [f lockForWriting];

        M23LockCtx ctx = { .file = f, .acquired = 0, .done = 0 };
        pthread_t tid;
        pthread_create(&tid, NULL, m23_try_read_lock, &ctx);

        // Give the reader thread a real chance to attempt the lock.
        usleep(50 * 1000); // 50 ms
        int reader_acquired_while_writer_held = ctx.acquired;

        [f unlockForWriting];
        pthread_join(tid, NULL);

        PASS(reader_acquired_while_writer_held == 0,
             "M23: reader blocked while writer holds exclusive lock");
        PASS(ctx.acquired == 1,
             "M23: reader unblocked after writer releases");

        PASS([f close], "M23: close after write-blocks test");
        unlink([path fileSystemRepresentation]);
    }
}
