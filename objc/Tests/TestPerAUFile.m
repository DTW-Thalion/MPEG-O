/*
 * TestPerAUFile — v1.0 file-level per-AU encryption round-trip.
 *
 * Mirrors python/tests/test_per_au_file.py. Builds a plaintext
 * fixture, calls TTIOPerAUFile.encryptFilePath:... (with and
 * without header encryption), reopens, verifies the file carries
 * the new feature flags and compound datasets, then decrypts and
 * compares plaintext signal values bit-for-bit.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <unistd.h>
#import <string.h>

#import "Protection/TTIOPerAUFile.h"
#import "Protection/TTIOPerAUEncryption.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOWrittenRun.h"
#import "Providers/TTIOProviderRegistry.h"
#import "Providers/TTIOStorageProtocols.h"
#import "HDF5/TTIOFeatureFlags.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "ValueClasses/TTIOEnums.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Spectra/TTIOSpectrum.h"
#import "Core/TTIOSignalArray.h"


static NSString *tmpPath(NSString *n) {
    return [NSString stringWithFormat:@"/tmp/ttio_peraufile_%d_%@",
            (int)getpid(), n];
}
static void rmFile(NSString *p) { [[NSFileManager defaultManager] removeItemAtPath:p error:NULL]; }
static NSData *key42(void) {
    uint8_t b[32]; memset(b, 0x42, 32);
    return [NSData dataWithBytes:b length:32];
}

static NSData *f64arr(const double *v, NSUInteger n) {
    NSMutableData *d = [NSMutableData dataWithCapacity:n * 8];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:8];
    return d;
}
static NSData *u64arr(const uint64_t *v, NSUInteger n) {
    NSMutableData *d = [NSMutableData dataWithCapacity:n * 8];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:8];
    return d;
}
static NSData *u32arr(const uint32_t *v, NSUInteger n) {
    NSMutableData *d = [NSMutableData dataWithCapacity:n * 4];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:4];
    return d;
}
static NSData *i32arr(const int32_t *v, NSUInteger n) {
    NSMutableData *d = [NSMutableData dataWithCapacity:n * 4];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:4];
    return d;
}

static BOOL buildPlaintextFixture(NSString *path, NSError **error)
{
    NSUInteger n = 5, p = 4, total = n * p;
    double mz[20], intensity[20];
    for (NSUInteger i = 0; i < total; i++) {
        mz[i] = 100.0 + (double)i;
        intensity[i] = (double)(i + 1) * 10.0;
    }
    uint64_t offsets[5] = {0, 4, 8, 12, 16};
    uint32_t lengths[5] = {4, 4, 4, 4, 4};
    double rts[5] = {1.5, 3.0, 4.5, 6.0, 7.5};
    int32_t msLevels[5] = {1, 2, 1, 2, 1};
    int32_t pols[5] = {1, 1, 1, 1, 1};
    double pmzs[5] = {0.0, 501.0, 0.0, 503.0, 0.0};
    int32_t pcs[5] = {0, 2, 0, 2, 0};
    double bpis[5];
    for (NSUInteger i = 0; i < n; i++) {
        double best = 0.0;
        for (NSUInteger k = 0; k < p; k++) {
            double v = intensity[i * p + k];
            if (v > best) best = v;
        }
        bpis[i] = best;
    }
    TTIOWrittenRun *run =
        [[TTIOWrittenRun alloc]
            initWithSpectrumClassName:@"TTIOMassSpectrum"
                      acquisitionMode:(int64_t)TTIOAcquisitionModeMS1DDA
                          channelData:@{@"mz": f64arr(mz, total),
                                        @"intensity": f64arr(intensity, total)}
                              offsets:u64arr(offsets, n)
                              lengths:u32arr(lengths, n)
                       retentionTimes:f64arr(rts, n)
                             msLevels:i32arr(msLevels, n)
                           polarities:i32arr(pols, n)
                         precursorMzs:f64arr(pmzs, n)
                     precursorCharges:i32arr(pcs, n)
                  basePeakIntensities:f64arr(bpis, n)];
    return [TTIOSpectralDataset writeMinimalToPath:path
                                              title:@"per-AU file round-trip fixture"
                                 isaInvestigationId:@"ISA-OBJC-PERAU"
                                             msRuns:@{@"run_0001": run}
                                    identifications:nil
                                    quantifications:nil
                                  provenanceRecords:nil
                                              error:error];
}


// Helper: reopen the HDF5 file to inspect feature flags + children
// without going through TTIOSpectralDataset (which may refuse
// post-encryption).
static NSArray<NSString *> *readFeaturesFromFile(NSString *path)
{
    TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:NULL];
    TTIOHDF5Group *root = f.rootGroup;
    NSArray *feats = [TTIOFeatureFlags featuresForRoot:root];
    return feats ?: @[];
}


void testPerAUFile(void)
{
    // ── 1. Encrypt (channels only) writes segments + flag ───────
    {
        NSString *path = tmpPath(@"src1.tio");
        rmFile(path);
        NSError *err = nil;
        PASS(buildPlaintextFixture(path, &err), "fixture built");

        BOOL ok = [TTIOPerAUFile encryptFilePath:path
                                              key:key42()
                                 encryptHeaders:NO
                                    providerName:nil
                                           error:&err];
        PASS(ok, "encryptFilePath (channels only) succeeds");

        NSArray *features = readFeaturesFromFile(path);
        PASS([features containsObject:@"opt_per_au_encryption"],
             "opt_per_au_encryption flag set");
        PASS(![features containsObject:@"opt_encrypted_au_headers"],
             "opt_encrypted_au_headers flag NOT set (channels-only mode)");
        rmFile(path);
    }

    // ── 2. Encrypt + decrypt recovers plaintext ─────────────────
    {
        NSString *path = tmpPath(@"src2.tio");
        rmFile(path);
        NSError *err = nil;
        buildPlaintextFixture(path, &err);

        // Capture original plaintext bytes before encryption mutates
        // the file.
        TTIOSpectralDataset *src = [TTIOSpectralDataset readFromFilePath:path error:&err];
        TTIOAcquisitionRun *run = src.msRuns[@"run_0001"];
        NSMutableData *origMz = [NSMutableData data];
        NSMutableData *origInt = [NSMutableData data];
        for (NSUInteger i = 0; i < [run count]; i++) {
            TTIOSpectrum *sp = [run objectAtIndex:i];
            [origMz appendData:sp.signalArrays[@"mz"].buffer];
            [origInt appendData:sp.signalArrays[@"intensity"].buffer];
        }
        // Release the read handle before we reopen for in-place
        // encryption; TTIOSpectralDataset holds the HDF5 file open
        // otherwise.
        [src closeFile];
        src = nil;

        BOOL ok = [TTIOPerAUFile encryptFilePath:path
                                              key:key42()
                                 encryptHeaders:NO
                                    providerName:nil
                                           error:&err];
        PASS(ok, "encryptFilePath succeeds on fresh fixture");

        err = nil;
        NSDictionary *decrypted =
            [TTIOPerAUFile decryptFilePath:path
                                         key:key42()
                                providerName:nil
                                       error:&err];
        PASS(decrypted != nil, "decryptFilePath succeeds");
        NSDictionary *runOut = decrypted[@"run_0001"];
        PASS([runOut[@"mz"] isEqualToData:origMz],
             "mz bytes round-trip bit-for-bit");
        PASS([runOut[@"intensity"] isEqualToData:origInt],
             "intensity bytes round-trip bit-for-bit");
        rmFile(path);
    }

    // ── 3. Wrong key fails decrypt ──────────────────────────────
    {
        NSString *path = tmpPath(@"src3.tio");
        rmFile(path);
        NSError *err = nil;
        buildPlaintextFixture(path, &err);
        [TTIOPerAUFile encryptFilePath:path
                                     key:key42()
                        encryptHeaders:NO
                           providerName:nil
                                  error:&err];
        uint8_t badBytes[32]; memset(badBytes, 0, 32);
        NSData *bad = [NSData dataWithBytes:badBytes length:32];
        err = nil;
        NSDictionary *result =
            [TTIOPerAUFile decryptFilePath:path
                                         key:bad
                                providerName:nil
                                       error:&err];
        PASS(result == nil && err != nil, "wrong key rejected (AES-GCM auth)");
        rmFile(path);
    }

    // ── 4. encryptHeaders=YES writes au_header_segments + flag ──
    {
        NSString *path = tmpPath(@"src4.tio");
        rmFile(path);
        NSError *err = nil;
        buildPlaintextFixture(path, &err);

        BOOL ok = [TTIOPerAUFile encryptFilePath:path
                                              key:key42()
                                 encryptHeaders:YES
                                    providerName:nil
                                           error:&err];
        PASS(ok, "encryptFilePath (with headers) succeeds");

        NSArray *features = readFeaturesFromFile(path);
        PASS([features containsObject:@"opt_per_au_encryption"],
             "opt_per_au_encryption set (headers mode)");
        PASS([features containsObject:@"opt_encrypted_au_headers"],
             "opt_encrypted_au_headers set (headers mode)");

        NSDictionary *decrypted =
            [TTIOPerAUFile decryptFilePath:path
                                         key:key42()
                                providerName:nil
                                       error:&err];
        PASS(decrypted != nil, "decryptFilePath w/ headers succeeds");
        NSArray *headers = decrypted[@"run_0001"][@"__au_headers__"];
        PASS(headers.count == 5, "__au_headers__ has 5 rows");
        if (headers.count == 5) {
            TTIOAUHeaderPlaintext *h1 = headers[1];
            PASS(h1.msLevel == 2 && h1.precursorMz == 501.0,
                 "row 1 semantic fields recovered (ms_level=2, pmz=501.0)");
            PASS(fabs(h1.retentionTime - 3.0) < 1e-12,
                 "row 1 retention_time recovered (3.0)");
        }
        rmFile(path);
    }
}
