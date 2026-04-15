#import "MPGOSignatureManager.h"
#import "HDF5/MPGOHDF5File.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Errors.h"
#import "HDF5/MPGOFeatureFlags.h"
#import <hdf5.h>
#import <openssl/hmac.h>
#import <openssl/evp.h>
#import <string.h>

@implementation MPGOSignatureManager

#pragma mark - Primitive

+ (NSData *)hmacSHA256OfData:(NSData *)data withKey:(NSData *)key
{
    unsigned char mac[EVP_MAX_MD_SIZE];
    unsigned int macLen = 0;
    HMAC(EVP_sha256(),
         key.bytes, (int)key.length,
         data.bytes, data.length,
         mac, &macLen);
    return [NSData dataWithBytes:mac length:macLen];
}

#pragma mark - Helpers

static hid_t openDatasetByPath(hid_t fid, NSString *path)
{
    // H5Dopen2 accepts absolute paths "/a/b/c".
    return H5Dopen2(fid, [path UTF8String], H5P_DEFAULT);
}

static NSData *readDatasetAsBytes(hid_t did)
{
    hid_t typeId = H5Dget_type(did);
    size_t typeSize = H5Tget_size(typeId);

    hid_t space = H5Dget_space(did);
    int rank = H5Sget_simple_extent_ndims(space);
    hsize_t dims[16] = {0};
    H5Sget_simple_extent_dims(space, dims, NULL);

    NSUInteger total = 1;
    for (int i = 0; i < rank; i++) total *= (NSUInteger)dims[i];
    NSUInteger totalBytes = total * typeSize;

    NSMutableData *buf = [NSMutableData dataWithLength:totalBytes];
    H5Dread(did, typeId, H5S_ALL, H5S_ALL, H5P_DEFAULT, buf.mutableBytes);

    H5Sclose(space);
    H5Tclose(typeId);
    return buf;
}

static BOOL writeStringAttribute(hid_t locId, const char *name, NSString *value)
{
    if (H5Aexists(locId, name) > 0) H5Adelete(locId, name);
    hid_t strType = H5Tcopy(H5T_C_S1);
    H5Tset_size(strType, H5T_VARIABLE);
    hid_t scalar = H5Screate(H5S_SCALAR);
    hid_t attr = H5Acreate2(locId, name, strType, scalar, H5P_DEFAULT, H5P_DEFAULT);
    const char *cs = [value UTF8String];
    herr_t rc = H5Awrite(attr, strType, &cs);
    H5Aclose(attr);
    H5Sclose(scalar);
    H5Tclose(strType);
    return rc >= 0;
}

static NSString *readStringAttribute(hid_t locId, const char *name)
{
    if (H5Aexists(locId, name) <= 0) return nil;
    hid_t attr = H5Aopen(locId, name, H5P_DEFAULT);
    hid_t t = H5Aget_type(attr);
    NSString *out = @"";
    if (H5Tis_variable_str(t) > 0) {
        char *cs = NULL;
        H5Aread(attr, t, &cs);
        if (cs) {
            out = [NSString stringWithUTF8String:cs];
            H5free_memory(cs);
        }
    } else {
        // Fixed-size string: MPGOHDF5Group.setStringAttribute writes
        // these by default.
        size_t size = H5Tget_size(t);
        char *buf = (char *)calloc(size + 1, 1);
        if (H5Aread(attr, t, buf) >= 0) {
            out = [NSString stringWithUTF8String:buf];
        }
        free(buf);
    }
    H5Tclose(t);
    H5Aclose(attr);
    return out;
}

static BOOL ensureSignatureFeatureFlag(MPGOHDF5Group *root, NSError **error)
{
    NSArray *features = [MPGOFeatureFlags featuresForRoot:root];
    if ([features containsObject:[MPGOFeatureFlags featureDigitalSignatures]]) {
        return YES;
    }
    NSMutableArray *updated = [features mutableCopy];
    [updated addObject:[MPGOFeatureFlags featureDigitalSignatures]];
    NSString *version = [MPGOFeatureFlags formatVersionForRoot:root] ?: @"1.1";
    return [MPGOFeatureFlags writeFormatVersion:version
                                       features:updated
                                         toRoot:root
                                          error:error];
}

#pragma mark - Dataset signing

+ (BOOL)signDataset:(NSString *)datasetPath
             inFile:(NSString *)filePath
            withKey:(NSData *)hmacKey
              error:(NSError **)error
{
    MPGOHDF5File *file = [MPGOHDF5File openAtPath:filePath error:error];
    if (!file) return NO;

    hid_t did = openDatasetByPath([file rootGroup].groupId, datasetPath);
    if (did < 0) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetOpen,
            @"cannot open dataset %@ for signing", datasetPath);
        [file close];
        return NO;
    }

    NSData *bytes = readDatasetAsBytes(did);
    NSData *mac = [self hmacSHA256OfData:bytes withKey:hmacKey];
    NSString *b64 = [mac base64EncodedStringWithOptions:0];

    BOOL ok = writeStringAttribute(did, "mpgo_signature", b64);
    H5Dclose(did);
    if (!ok) {
        if (error) *error = MPGOMakeError(MPGOErrorAttributeWrite,
            @"failed to write @mpgo_signature on %@", datasetPath);
        [file close];
        return NO;
    }

    // Ensure the root feature flags include opt_digital_signatures.
    ensureSignatureFeatureFlag([file rootGroup], error);
    return [file close];
}

+ (BOOL)verifyDataset:(NSString *)datasetPath
               inFile:(NSString *)filePath
              withKey:(NSData *)hmacKey
                error:(NSError **)error
{
    MPGOHDF5File *file = [MPGOHDF5File openReadOnlyAtPath:filePath error:error];
    if (!file) return NO;

    hid_t did = openDatasetByPath([file rootGroup].groupId, datasetPath);
    if (did < 0) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetOpen,
            @"cannot open dataset %@ for verification", datasetPath);
        [file close];
        return NO;
    }

    NSString *storedB64 = readStringAttribute(did, "mpgo_signature");
    if (!storedB64) {
        H5Dclose(did);
        [file close];
        if (error) *error = MPGOMakeError(MPGOErrorAttributeRead,
            @"dataset %@ has no @mpgo_signature attribute", datasetPath);
        return NO;
    }
    NSData *storedMac = [[NSData alloc] initWithBase64EncodedString:storedB64
                                                              options:0];

    NSData *bytes = readDatasetAsBytes(did);
    NSData *computedMac = [self hmacSHA256OfData:bytes withKey:hmacKey];
    H5Dclose(did);
    [file close];

    if (!storedMac || ![storedMac isEqualToData:computedMac]) {
        if (error) *error = MPGOMakeError(MPGOErrorAttributeRead,
            @"signature mismatch on %@ (tampered or wrong key)", datasetPath);
        return NO;
    }
    return YES;
}

#pragma mark - Provenance signing

+ (BOOL)signProvenanceInRun:(NSString *)runPath
                     inFile:(NSString *)filePath
                    withKey:(NSData *)hmacKey
                      error:(NSError **)error
{
    MPGOHDF5File *file = [MPGOHDF5File openAtPath:filePath error:error];
    if (!file) return NO;

    hid_t gid = H5Gopen2([file rootGroup].groupId, [runPath UTF8String], H5P_DEFAULT);
    if (gid < 0) {
        if (error) *error = MPGOMakeError(MPGOErrorGroupOpen,
            @"cannot open run %@ for provenance signing", runPath);
        [file close];
        return NO;
    }

    NSString *json = readStringAttribute(gid, "provenance_json");
    if (!json) {
        H5Gclose(gid);
        [file close];
        if (error) *error = MPGOMakeError(MPGOErrorAttributeRead,
            @"run %@ has no @provenance_json to sign", runPath);
        return NO;
    }
    NSData *jsonBytes = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSData *mac = [self hmacSHA256OfData:jsonBytes withKey:hmacKey];
    NSString *b64 = [mac base64EncodedStringWithOptions:0];

    BOOL ok = writeStringAttribute(gid, "provenance_signature", b64);
    H5Gclose(gid);
    if (!ok) {
        if (error) *error = MPGOMakeError(MPGOErrorAttributeWrite,
            @"failed to write @provenance_signature on %@", runPath);
        [file close];
        return NO;
    }

    ensureSignatureFeatureFlag([file rootGroup], error);
    return [file close];
}

+ (BOOL)verifyProvenanceInRun:(NSString *)runPath
                       inFile:(NSString *)filePath
                      withKey:(NSData *)hmacKey
                        error:(NSError **)error
{
    MPGOHDF5File *file = [MPGOHDF5File openReadOnlyAtPath:filePath error:error];
    if (!file) return NO;

    hid_t gid = H5Gopen2([file rootGroup].groupId, [runPath UTF8String], H5P_DEFAULT);
    if (gid < 0) {
        if (error) *error = MPGOMakeError(MPGOErrorGroupOpen,
            @"cannot open run %@ for provenance verification", runPath);
        [file close];
        return NO;
    }

    NSString *json = readStringAttribute(gid, "provenance_json");
    NSString *storedB64 = readStringAttribute(gid, "provenance_signature");
    H5Gclose(gid);
    [file close];

    if (!json || !storedB64) {
        if (error) *error = MPGOMakeError(MPGOErrorAttributeRead,
            @"run %@ missing provenance_json or provenance_signature", runPath);
        return NO;
    }
    NSData *jsonBytes = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSData *computedMac = [self hmacSHA256OfData:jsonBytes withKey:hmacKey];
    NSData *storedMac = [[NSData alloc] initWithBase64EncodedString:storedB64
                                                              options:0];
    if (!storedMac || ![storedMac isEqualToData:computedMac]) {
        if (error) *error = MPGOMakeError(MPGOErrorAttributeRead,
            @"provenance signature mismatch on %@", runPath);
        return NO;
    }
    return YES;
}

@end
