/*
 * TestMilestone18 — canonical byte-order signatures.
 *
 * v0.3 serializes atomic numeric datasets as little-endian before
 * hashing and emits compound records field-by-field (LE numerics,
 * ``u32_le(length) || bytes`` for VL strings). The stored attribute
 * carries a ``v2:`` prefix; v0.2 native-byte signatures remain
 * verifiable via an automatic fallback path. Signing a dataset adds
 * both ``opt_digital_signatures`` and ``opt_canonical_signatures`` to
 * the root feature flags.
 */

#import <Foundation/Foundation.h>
#import "Testing.h"

#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOInstrumentConfig.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOEnums.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOIdentification.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOFeatureFlags.h"
#import "Protection/TTIOSignatureManager.h"
#import "Protection/TTIOVerifier.h"

#import <hdf5.h>
#import <openssl/hmac.h>
#import <openssl/evp.h>
#import <unistd.h>

static NSString *m18path(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_test_m18_%d_%@.tio",
            (int)getpid(), suffix];
}

static NSData *m18Key(void)
{
    uint8_t raw[32];
    for (int i = 0; i < 32; i++) raw[i] = (uint8_t)(0x5A ^ (i * 7));
    return [NSData dataWithBytes:raw length:32];
}

static TTIOAcquisitionRun *m18BuildRun(void)
{
    NSMutableArray *spectra = [NSMutableArray array];
    for (NSUInteger k = 0; k < 4; k++) {
        double mz[8], in[8];
        for (NSUInteger i = 0; i < 8; i++) {
            mz[i] = 100.0 + (double)(k * 8 + i);
            in[i] = (double)(k * 10 + i + 1);
        }
        TTIOEncodingSpec *enc =
            [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                           compressionAlgorithm:TTIOCompressionZlib
                                      byteOrder:TTIOByteOrderLittleEndian];
        TTIOSignalArray *mzA =
            [[TTIOSignalArray alloc] initWithBuffer:[NSData dataWithBytes:mz length:sizeof(mz)]
                                              length:8
                                            encoding:enc
                                                axis:nil];
        TTIOSignalArray *inA =
            [[TTIOSignalArray alloc] initWithBuffer:[NSData dataWithBytes:in length:sizeof(in)]
                                              length:8
                                            encoding:enc
                                                axis:nil];
        [spectra addObject:
            [[TTIOMassSpectrum alloc] initWithMzArray:mzA
                                       intensityArray:inA
                                              msLevel:1
                                             polarity:TTIOPolarityPositive
                                           scanWindow:nil
                                        indexPosition:k
                                      scanTimeSeconds:(double)k
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

static NSString *readSignatureString(NSString *path, const char *dsetPath)
{
    NSString *out = nil;
    @autoreleasepool {
        TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:NULL];
        TTIOHDF5Group *root = [f rootGroup];
        hid_t did = H5Dopen2(root.groupId, dsetPath, H5P_DEFAULT);
        if (did >= 0 && H5Aexists(did, "ttio_signature") > 0) {
            hid_t aid = H5Aopen(did, "ttio_signature", H5P_DEFAULT);
            hid_t t = H5Aget_type(aid);
            if (H5Tis_variable_str(t) > 0) {
                char *cs = NULL;
                H5Aread(aid, t, &cs);
                if (cs) {
                    out = [[NSString alloc] initWithUTF8String:cs];
                    H5free_memory(cs);
                }
            }
            H5Tclose(t);
            H5Aclose(aid);
        }
        if (did >= 0) H5Dclose(did);
        root = nil;
        [f close];
    }
    return out;
}

static BOOL overwriteSignatureAsV1(NSString *path, const char *dsetPath,
                                    NSString *unprefixed)
{
    BOOL ok = NO;
    @autoreleasepool {
        TTIOHDF5File *f = [TTIOHDF5File openAtPath:path error:NULL];
        TTIOHDF5Group *root = [f rootGroup];
        hid_t did = H5Dopen2(root.groupId, dsetPath, H5P_DEFAULT);
        if (did >= 0) {
            if (H5Aexists(did, "ttio_signature") > 0) {
                H5Adelete(did, "ttio_signature");
            }
            hid_t strType = H5Tcopy(H5T_C_S1);
            H5Tset_size(strType, H5T_VARIABLE);
            hid_t scalar = H5Screate(H5S_SCALAR);
            hid_t aid = H5Acreate2(did, "ttio_signature", strType, scalar,
                                   H5P_DEFAULT, H5P_DEFAULT);
            const char *cs = [unprefixed UTF8String];
            herr_t rc = H5Awrite(aid, strType, &cs);
            H5Aclose(aid); H5Sclose(scalar); H5Tclose(strType);
            H5Dclose(did);
            ok = (rc >= 0);
        }
        root = nil;
        [f close];
    }
    return ok;
}

static NSData *computeV1NativeMac(NSString *path, const char *dsetPath,
                                   NSData *key)
{
    NSData *out = nil;
    @autoreleasepool {
        TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:NULL];
        TTIOHDF5Group *root = [f rootGroup];
        hid_t did = H5Dopen2(root.groupId, dsetPath, H5P_DEFAULT);
        hid_t typeId = H5Dget_type(did);
        hid_t space = H5Dget_space(did);
        hsize_t dims[16] = {0};
        int rank = H5Sget_simple_extent_ndims(space);
        H5Sget_simple_extent_dims(space, dims, NULL);
        hsize_t total = 1;
        for (int i = 0; i < rank; i++) total *= dims[i];
        size_t typeSize = H5Tget_size(typeId);
        NSMutableData *buf = [NSMutableData dataWithLength:(NSUInteger)total * typeSize];
        H5Dread(did, typeId, H5S_ALL, H5S_ALL, H5P_DEFAULT, buf.mutableBytes);
        H5Sclose(space); H5Tclose(typeId); H5Dclose(did);
        root = nil;
        [f close];

        unsigned char mac[EVP_MAX_MD_SIZE];
        unsigned int macLen = 0;
        HMAC(EVP_sha256(), key.bytes, (int)key.length,
             buf.bytes, buf.length, mac, &macLen);
        out = [[NSData alloc] initWithBytes:mac length:macLen];
    }
    return out;
}

void testMilestone18(void)
{
    // ---- 1. v2 round trip on an atomic float64 channel ----
    NSString *path = m18path(@"v2rt");
    unlink([path fileSystemRepresentation]);

    TTIOSpectralDataset *ds =
        [[TTIOSpectralDataset alloc] initWithTitle:@"m18"
                                isaInvestigationId:@""
                                            msRuns:@{@"run_0001": m18BuildRun()}
                                           nmrRuns:@{}
                                   identifications:@[]
                                   quantifications:@[]
                                 provenanceRecords:@[]
                                       transitions:nil];
    NSError *err = nil;
    PASS([ds writeToFilePath:path error:&err], "M18 dataset writes to disk");

    NSData *key = m18Key();
    NSString *mzPath = @"/study/ms_runs/run_0001/signal_channels/mz_values";
    NSString *intPath = @"/study/ms_runs/run_0001/signal_channels/intensity_values";

    err = nil;
    PASS([TTIOSignatureManager signDataset:intPath inFile:path withKey:key error:&err],
         "sign intensity_values with canonical (v2) path");

    NSString *stored = readSignatureString(path, intPath.UTF8String);
    PASS(stored != nil, "signature attribute present after signing");
    PASS([stored hasPrefix:@"v2:"], "signature carries v2 prefix");

    err = nil;
    PASS([TTIOSignatureManager verifyDataset:intPath
                                      inFile:path
                                     withKey:key
                                       error:&err],
         "canonical (v2) signature verifies with correct key");
    PASS(err == nil, "no error on successful verify");

    NSData *wrong = [NSData dataWithBytes:
        (const uint8_t[32]){0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,
                            16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31}
                                   length:32];
    err = nil;
    PASS(![TTIOSignatureManager verifyDataset:intPath
                                       inFile:path
                                      withKey:wrong
                                        error:&err],
         "canonical signature rejects wrong key");
    PASS(err != nil, "wrong-key verification populates error");

    // ---- 2. feature flags include opt_canonical_signatures ----
    @autoreleasepool {
        TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:NULL];
        NSArray *features = [TTIOFeatureFlags featuresForRoot:[f rootGroup]];
        PASS([features containsObject:@"opt_canonical_signatures"],
             "opt_canonical_signatures flag present after signing");
        PASS([features containsObject:@"opt_digital_signatures"],
             "opt_digital_signatures flag still present");
        [f close];
    }

    // ---- 3. v1 backward compatibility path ----
    //
    // Compute the v1 native-bytes MAC ourselves, overwrite the v2
    // attribute with an unprefixed base64, and confirm the verifier
    // accepts it via the fallback path.
    @autoreleasepool {
        NSData *v1Mac = computeV1NativeMac(path, intPath.UTF8String, key);
        NSString *v1B64 = [v1Mac base64EncodedStringWithOptions:0];
        PASS(overwriteSignatureAsV1(path, intPath.UTF8String, v1B64),
             "overwrite @ttio_signature with unprefixed v1 base64");

        NSString *now = readSignatureString(path, intPath.UTF8String);
        PASS(![now hasPrefix:@"v2:"], "signature is now unprefixed (v1 form)");

        NSError *err2 = nil;
        PASS([TTIOSignatureManager verifyDataset:intPath
                                          inFile:path
                                         withKey:key
                                           error:&err2],
             "legacy v1 signature still verifies via fallback");
        PASS(err2 == nil, "v1 fallback verify produces no error");
    }

    // ---- 4. Sign a second dataset, tamper, expect failure ----
    @autoreleasepool {
        NSError *err2 = nil;
        PASS([TTIOSignatureManager signDataset:mzPath inFile:path withKey:key error:&err2],
             "sign mz_values with v2");

        // Overwrite one value inside mz_values.
        TTIOHDF5File *f = [TTIOHDF5File openAtPath:path error:NULL];
        hid_t did = H5Dopen2([f rootGroup].groupId, mzPath.UTF8String, H5P_DEFAULT);
        hid_t t   = H5Dget_type(did);
        hid_t sp  = H5Dget_space(did);
        hsize_t dims[1] = {0};
        H5Sget_simple_extent_dims(sp, dims, NULL);
        NSMutableData *buf = [NSMutableData dataWithLength:dims[0] * sizeof(double)];
        H5Dread(did, t, H5S_ALL, H5S_ALL, H5P_DEFAULT, buf.mutableBytes);
        double *p = (double *)buf.mutableBytes;
        p[0] += 1.0;
        H5Dwrite(did, t, H5S_ALL, H5S_ALL, H5P_DEFAULT, buf.bytes);
        H5Sclose(sp); H5Tclose(t); H5Dclose(did);
        [f close];

        NSError *verr = nil;
        PASS(![TTIOSignatureManager verifyDataset:mzPath
                                           inFile:path
                                          withKey:key
                                            error:&verr],
             "tampered mz_values fails canonical verify");
    }
    unlink([path fileSystemRepresentation]);

    // ---- 5. Canonical signature on a compound dataset ----
    //
    // /study/identifications exists whenever the dataset carries
    // identification records. It contains VL strings and numeric
    // fields — exactly the mix M18 has to handle.
    NSString *path2 = m18path(@"compound");
    unlink([path2 fileSystemRepresentation]);

    TTIOIdentification *a =
        [[TTIOIdentification alloc] initWithRunName:@"run_0001"
                                        spectrumIndex:0
                                       chemicalEntity:@"CHEBI:15000"
                                      confidenceScore:0.73
                                        evidenceChain:@[@"MS:1002217"]];
    TTIOIdentification *b =
        [[TTIOIdentification alloc] initWithRunName:@"run_0001"
                                        spectrumIndex:2
                                       chemicalEntity:@"CHEBI:15377"
                                      confidenceScore:0.91
                                        evidenceChain:@[@"PRIDE:0000033"]];
    TTIOSpectralDataset *ds2 =
        [[TTIOSpectralDataset alloc] initWithTitle:@"m18c"
                                isaInvestigationId:@""
                                            msRuns:@{@"run_0001": m18BuildRun()}
                                           nmrRuns:@{}
                                   identifications:@[a, b]
                                   quantifications:@[]
                                 provenanceRecords:@[]
                                       transitions:nil];
    err = nil;
    PASS([ds2 writeToFilePath:path2 error:&err],
         "M18 compound dataset writes to disk");

    NSString *identsPath = @"/study/identifications";
    err = nil;
    PASS([TTIOSignatureManager signDataset:identsPath
                                    inFile:path2
                                   withKey:key
                                     error:&err],
         "sign /study/identifications compound with v2");

    NSString *stored2 = readSignatureString(path2, identsPath.UTF8String);
    PASS([stored2 hasPrefix:@"v2:"], "compound signature uses v2 prefix");

    err = nil;
    PASS([TTIOSignatureManager verifyDataset:identsPath
                                      inFile:path2
                                     withKey:key
                                       error:&err],
         "compound v2 signature verifies");

    // A compound record-level tamper (modify spectrum_index) breaks
    // the signature. We run it via a separate reopen.
    @autoreleasepool {
        TTIOHDF5File *f = [TTIOHDF5File openAtPath:path2 error:NULL];
        hid_t did = H5Dopen2([f rootGroup].groupId,
                             identsPath.UTF8String, H5P_DEFAULT);
        hid_t t = H5Dget_type(did);
        size_t recSize = H5Tget_size(t);
        hid_t sp = H5Dget_space(did);
        hsize_t dims[1] = {0};
        H5Sget_simple_extent_dims(sp, dims, NULL);
        void *buf = calloc((size_t)dims[0], recSize);
        H5Dread(did, t, H5S_ALL, H5S_ALL, H5P_DEFAULT, buf);
        int nmembers = H5Tget_nmembers(t);
        size_t siOffset = 0;
        for (int i = 0; i < nmembers; i++) {
            char *n = H5Tget_member_name(t, i);
            if (n && strcmp(n, "spectrum_index") == 0) {
                siOffset = H5Tget_member_offset(t, i);
            }
            if (n) H5free_memory(n);
        }
        uint32_t *si0 = (uint32_t *)((uint8_t *)buf + siOffset);
        *si0 = (*si0) + 99;
        H5Dwrite(did, t, H5S_ALL, H5S_ALL, H5P_DEFAULT, buf);
        H5Dvlen_reclaim(t, sp, H5P_DEFAULT, buf);
        free(buf);
        H5Sclose(sp); H5Tclose(t); H5Dclose(did);
        [f close];

        NSError *verr = nil;
        PASS(![TTIOSignatureManager verifyDataset:identsPath
                                           inFile:path2
                                          withKey:key
                                            error:&verr],
             "tampered compound record fails v2 verify");
    }
    unlink([path2 fileSystemRepresentation]);
}
