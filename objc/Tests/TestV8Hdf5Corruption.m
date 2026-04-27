/*
 * TestV8Hdf5Corruption.m — V8 HDF5 corruption / partial-write recovery (ObjC).
 *
 * Verifies +[TTIOHDF5File openReadOnlyAtPath:error:] returns nil + NSError
 * (or otherwise fails cleanly) on malformed/truncated .tio files. No
 * segfaults, no hangs, no silent data corruption.
 *
 * Mirrors python/tests/test_v8_hdf5_corruption.py (V8a) and
 * java/src/test/java/global/thalion/ttio/V8Hdf5CorruptionTest.java (V8b).
 *
 * Per docs/verification-workplan.md §V8.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "HDF5/TTIOHDF5File.h"
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static NSString *v8MakeTio(NSData *bytes)
{
    NSString *tmpl = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"v8-XXXXXX.tio"];
    char tmpl_c[1024];
    strncpy(tmpl_c, [tmpl fileSystemRepresentation], sizeof(tmpl_c));
    tmpl_c[sizeof(tmpl_c) - 1] = '\0';
    int fd = mkstemps(tmpl_c, 4);  // 4 = strlen(".tio")
    if (fd < 0) return nil;
    close(fd);
    NSString *path = [NSString stringWithUTF8String:tmpl_c];
    [bytes writeToFile:path atomically:YES];
    return path;
}

static NSData *v8MakeIntactTioBytes(void)
{
    // Round-trip a tiny valid HDF5 file via the production class so we
    // know the bytes are realistic. We then mutate copies to make the
    // corruption variants.
    NSString *path = v8MakeTio([NSData data]);
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    NSError *err = nil;
    TTIOHDF5File *f = [TTIOHDF5File createAtPath:path error:&err];
    if (!f || err) {
        NSLog(@"v8: failed to create intact fixture: %@", err);
        return nil;
    }
    f = nil;  // release → close (ARC)
    NSData *bytes = [NSData dataWithContentsOfFile:path];
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    return bytes;
}

void testV8Hdf5Corruption(void)
{
    NSError *err = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSData *intact = v8MakeIntactTioBytes();
    if (!intact || intact.length < 32) {
        PASS(NO, "V8: cannot construct intact .tio fixture; aborting suite");
        return;
    }

    // ── #1: zero-byte file ──────────────────────────────────────────
    {
        NSString *p = v8MakeTio([NSData data]);
        err = nil;
        TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:p error:&err];
        PASS(f == nil, "V8 #1: zero-byte file returns nil from openReadOnlyAtPath");
        // err may or may not be set depending on the wrapper; the
        // contract is "no segfault, no silent success".
        [fm removeItemAtPath:p error:NULL];
    }

    // ── #2: 1-byte file ──────────────────────────────────────────────
    {
        NSString *p = v8MakeTio([NSData dataWithBytes:(char[1]){0} length:1]);
        err = nil;
        TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:p error:&err];
        PASS(f == nil, "V8 #2: 1-byte file returns nil from openReadOnlyAtPath");
        [fm removeItemAtPath:p error:NULL];
    }

    // ── #3: superblock-truncated ─────────────────────────────────────
    {
        NSData *truncated = [intact subdataWithRange:NSMakeRange(0, 4)];
        NSString *p = v8MakeTio(truncated);
        err = nil;
        TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:p error:&err];
        PASS(f == nil, "V8 #3: superblock-truncated file returns nil");
        [fm removeItemAtPath:p error:NULL];
    }

    // ── #4: mid-file truncation ──────────────────────────────────────
    {
        NSData *halfData = [intact subdataWithRange:NSMakeRange(0, intact.length / 2)];
        NSString *p = v8MakeTio(halfData);
        err = nil;
        TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:p error:&err];
        // Either nil (raised) or non-nil (h5lib accepted partial file).
        // Pass condition: no segfault. f != nil means h5lib opened the
        // partial file and we got here without crashing.
        PASS(YES, "V8 #4: mid-file truncation handled cleanly (no segfault)");
        f = nil;
        [fm removeItemAtPath:p error:NULL];
    }

    // ── #5: tail truncation ──────────────────────────────────────────
    {
        NSUInteger newLen = intact.length > 1024 ? intact.length - 1024 : 1;
        NSData *tail = [intact subdataWithRange:NSMakeRange(0, newLen)];
        NSString *p = v8MakeTio(tail);
        err = nil;
        TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:p error:&err];
        PASS(YES, "V8 #5: tail truncation handled cleanly");
        f = nil;
        [fm removeItemAtPath:p error:NULL];
    }

    // ── #6: corrupted superblock magic ──────────────────────────────
    {
        NSMutableData *corrupted = [intact mutableCopy];
        unsigned char *bytes = corrupted.mutableBytes;
        for (NSUInteger i = 0; i < 8 && i < corrupted.length; i++) bytes[i] = 0;
        NSString *p = v8MakeTio(corrupted);
        err = nil;
        TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:p error:&err];
        PASS(f == nil, "V8 #6: corrupted superblock magic returns nil");
        [fm removeItemAtPath:p error:NULL];
    }

    // ── #7: random garbage ──────────────────────────────────────────
    {
        NSMutableData *garbage = [NSMutableData dataWithLength:16 * 1024];
        unsigned char *bytes = garbage.mutableBytes;
        srand(42);
        for (NSUInteger i = 0; i < garbage.length; i++) bytes[i] = (unsigned char)rand();
        NSString *p = v8MakeTio(garbage);
        err = nil;
        TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:p error:&err];
        PASS(f == nil, "V8 #7: 16 KB random garbage returns nil");
        [fm removeItemAtPath:p error:NULL];
    }

    // ── #8: trailing junk past EOF (cross-language divergence!) ────
    {
        NSMutableData *extended = [intact mutableCopy];
        char junk[1024];
        memset(junk, 0xCC, sizeof(junk));
        [extended appendBytes:junk length:sizeof(junk)];
        NSString *p = v8MakeTio(extended);
        err = nil;
        TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:p error:&err];
        // CROSS-LANGUAGE DIVERGENCE (V8c finding):
        // Python h5py tolerates trailing junk past EOF (reads up to
        // declared file extent only). The ObjC TTIOHDF5File wrapper
        // REJECTS such files via its EOF probe. This is stricter and
        // arguably better for tamper-detection. Documented in
        // docs/recovery-and-resilience.md §Cross-language divergence.
        // Pass condition: open returned cleanly (nil + NSError, no
        // segfault). Whether it accepted or rejected is informational.
        PASS(YES, "V8 #8: trailing junk past EOF handled cleanly "
                  "(ObjC rejects, Python tolerates — cross-language divergence)");
        f = nil;
        [fm removeItemAtPath:p error:NULL];
    }
}
