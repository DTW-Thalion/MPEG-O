#import "MPGOEncryptionManager.h"
#import "HDF5/MPGOHDF5File.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Dataset.h"
#import "HDF5/MPGOHDF5Errors.h"
#import "HDF5/MPGOHDF5Types.h"
#import "ValueClasses/MPGOEnums.h"
#import <openssl/evp.h>
#import <openssl/rand.h>
#import <openssl/err.h>
#import <hdf5.h>

#define MPGO_AES_KEY_LEN 32
#define MPGO_AES_IV_LEN  12
#define MPGO_AES_TAG_LEN 16

@implementation MPGOEncryptionManager

#pragma mark - Low-level primitives

+ (NSData *)encryptData:(NSData *)plaintext
                withKey:(NSData *)key
                     iv:(NSData **)outIv
                authTag:(NSData **)outTag
                  error:(NSError **)error
{
    if (key.length != MPGO_AES_KEY_LEN) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"AES-256-GCM requires a 32-byte key, got %lu", (unsigned long)key.length);
        return nil;
    }

    unsigned char iv[MPGO_AES_IV_LEN];
    if (RAND_bytes(iv, MPGO_AES_IV_LEN) != 1) {
        if (error) *error = MPGOMakeError(MPGOErrorUnknown, @"RAND_bytes failed");
        return nil;
    }

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) {
        if (error) *error = MPGOMakeError(MPGOErrorUnknown, @"EVP_CIPHER_CTX_new failed");
        return nil;
    }

    NSMutableData *out = [NSMutableData dataWithLength:plaintext.length + 16];
    int outLen = 0, totalLen = 0;

    if (EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL) != 1 ||
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, MPGO_AES_IV_LEN, NULL) != 1 ||
        EVP_EncryptInit_ex(ctx, NULL, NULL, key.bytes, iv) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        if (error) *error = MPGOMakeError(MPGOErrorUnknown, @"EVP_EncryptInit_ex failed");
        return nil;
    }

    if (EVP_EncryptUpdate(ctx, out.mutableBytes, &outLen,
                          plaintext.bytes, (int)plaintext.length) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        if (error) *error = MPGOMakeError(MPGOErrorUnknown, @"EVP_EncryptUpdate failed");
        return nil;
    }
    totalLen = outLen;

    if (EVP_EncryptFinal_ex(ctx, (uint8_t *)out.mutableBytes + totalLen, &outLen) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        if (error) *error = MPGOMakeError(MPGOErrorUnknown, @"EVP_EncryptFinal_ex failed");
        return nil;
    }
    totalLen += outLen;
    out.length = (NSUInteger)totalLen;

    unsigned char tag[MPGO_AES_TAG_LEN];
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, MPGO_AES_TAG_LEN, tag) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        if (error) *error = MPGOMakeError(MPGOErrorUnknown, @"EVP_CTRL_GCM_GET_TAG failed");
        return nil;
    }
    EVP_CIPHER_CTX_free(ctx);

    if (outIv)  *outIv  = [NSData dataWithBytes:iv  length:MPGO_AES_IV_LEN];
    if (outTag) *outTag = [NSData dataWithBytes:tag length:MPGO_AES_TAG_LEN];
    return out;
}

+ (NSData *)decryptData:(NSData *)ciphertext
                withKey:(NSData *)key
                     iv:(NSData *)iv
                authTag:(NSData *)authTag
                  error:(NSError **)error
{
    if (key.length != MPGO_AES_KEY_LEN || iv.length != MPGO_AES_IV_LEN ||
        authTag.length != MPGO_AES_TAG_LEN) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"AES-256-GCM decrypt: bad key/iv/tag lengths");
        return nil;
    }

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) {
        if (error) *error = MPGOMakeError(MPGOErrorUnknown, @"EVP_CIPHER_CTX_new failed");
        return nil;
    }

    NSMutableData *out = [NSMutableData dataWithLength:ciphertext.length + 16];
    int outLen = 0, totalLen = 0;

    if (EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL) != 1 ||
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, MPGO_AES_IV_LEN, NULL) != 1 ||
        EVP_DecryptInit_ex(ctx, NULL, NULL, key.bytes, iv.bytes) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        if (error) *error = MPGOMakeError(MPGOErrorUnknown, @"EVP_DecryptInit_ex failed");
        return nil;
    }

    if (EVP_DecryptUpdate(ctx, out.mutableBytes, &outLen,
                          ciphertext.bytes, (int)ciphertext.length) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        if (error) *error = MPGOMakeError(MPGOErrorUnknown, @"EVP_DecryptUpdate failed");
        return nil;
    }
    totalLen = outLen;

    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, MPGO_AES_TAG_LEN,
                            (void *)authTag.bytes) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        if (error) *error = MPGOMakeError(MPGOErrorUnknown, @"EVP_CTRL_GCM_SET_TAG failed");
        return nil;
    }

    int finalRc = EVP_DecryptFinal_ex(ctx, (uint8_t *)out.mutableBytes + totalLen, &outLen);
    EVP_CIPHER_CTX_free(ctx);

    if (finalRc != 1) {
        // GCM tag mismatch — this is the wrong-key path.
        if (error) *error = MPGOMakeError(MPGOErrorUnknown,
            @"AES-256-GCM authenticated decryption failed (tag mismatch)");
        return nil;
    }
    totalLen += outLen;
    out.length = (NSUInteger)totalLen;
    return out;
}

#pragma mark - Channel-level helpers

+ (BOOL)encryptIntensityChannelInRun:(NSString *)runName
                          atFilePath:(NSString *)path
                             withKey:(NSData *)key
                               error:(NSError **)error
{
    MPGOHDF5File *file = [MPGOHDF5File openAtPath:path error:error];
    if (!file) return NO;

    MPGOHDF5Group *runGroup = [[file rootGroup] openGroupNamed:runName error:error];
    if (!runGroup) return NO;
    MPGOHDF5Group *channels = [runGroup openGroupNamed:@"signal_channels" error:error];
    if (!channels) return NO;

    MPGOHDF5Dataset *intensityDS = [channels openDatasetNamed:@"intensity_values" error:error];
    if (!intensityDS) return NO;

    NSUInteger originalCount = intensityDS.length;
    NSData *plaintext = [intensityDS readDataWithError:error];
    if (!plaintext) return NO;

    NSData *iv = nil, *tag = nil;
    NSData *ciphertext = [self encryptData:plaintext
                                   withKey:key
                                        iv:&iv
                                   authTag:&tag
                                     error:error];
    if (!ciphertext) return NO;

    // Drop the original plaintext dataset, write the ciphertext + metadata.
    intensityDS = nil;  // close handle before unlinking
    H5Ldelete(channels.groupId, "intensity_values", H5P_DEFAULT);

    // The 1-D wrapper API only handles typed elements; use Int32 as a
    // raw byte container (4 bytes per element, padded with zeros).
    NSMutableData *padded = [NSMutableData dataWithData:ciphertext];
    while (padded.length % 4 != 0) {
        uint8_t zero = 0;
        [padded appendBytes:&zero length:1];
    }
    MPGOHDF5Dataset *encDS =
        [channels createDatasetNamed:@"intensity_values_encrypted"
                           precision:MPGOPrecisionInt32
                              length:padded.length / 4
                           chunkSize:0
                    compressionLevel:0
                               error:error];
    if (!encDS) return NO;
    if (![encDS writeData:padded error:error]) return NO;

    if (![channels setIntegerAttribute:@"intensity_ciphertext_bytes"
                                 value:(int64_t)ciphertext.length error:error]) return NO;
    if (![channels setIntegerAttribute:@"intensity_original_count"
                                 value:(int64_t)originalCount error:error]) return NO;
    if (![channels setStringAttribute:@"intensity_algorithm"
                                value:@"AES-256-GCM" error:error]) return NO;

    // IV and tag as small uint8 packed into Int32 datasets too (for the
    // current 1-D wrapper). The Int32 dataset just holds raw bytes;
    // the IV is 12 bytes (3 int32s), the tag is 16 bytes (4 int32s).
    MPGOHDF5Dataset *ivDS =
        [channels createDatasetNamed:@"intensity_iv"
                           precision:MPGOPrecisionInt32
                              length:3
                           chunkSize:0
                    compressionLevel:0
                               error:error];
    if (!ivDS) return NO;
    if (![ivDS writeData:iv error:error]) return NO;

    MPGOHDF5Dataset *tagDS =
        [channels createDatasetNamed:@"intensity_tag"
                           precision:MPGOPrecisionInt32
                              length:4
                           chunkSize:0
                    compressionLevel:0
                               error:error];
    if (!tagDS) return NO;
    if (![tagDS writeData:tag error:error]) return NO;

    return [file close];
}

+ (NSData *)decryptIntensityChannelInRun:(NSString *)runName
                              atFilePath:(NSString *)path
                                 withKey:(NSData *)key
                                   error:(NSError **)error
{
    MPGOHDF5File *file = [MPGOHDF5File openReadOnlyAtPath:path error:error];
    if (!file) return nil;
    MPGOHDF5Group *runGroup = [[file rootGroup] openGroupNamed:runName error:error];
    if (!runGroup) return nil;
    MPGOHDF5Group *channels = [runGroup openGroupNamed:@"signal_channels" error:error];
    if (!channels) return nil;

    BOOL exists = NO;
    int64_t cipherBytes =
        [channels integerAttributeNamed:@"intensity_ciphertext_bytes"
                                 exists:&exists error:error];
    if (!exists) {
        if (error) *error = MPGOMakeError(MPGOErrorAttributeRead,
            @"channel is not encrypted (no intensity_ciphertext_bytes)");
        return nil;
    }

    MPGOHDF5Dataset *encDS = [channels openDatasetNamed:@"intensity_values_encrypted" error:error];
    if (!encDS) return nil;
    NSData *padded = [encDS readDataWithError:error];
    if (!padded) return nil;
    NSData *cipher = [padded subdataWithRange:NSMakeRange(0, (NSUInteger)cipherBytes)];

    MPGOHDF5Dataset *ivDS = [channels openDatasetNamed:@"intensity_iv" error:error];
    if (!ivDS) return nil;
    NSData *ivPad = [ivDS readDataWithError:error];
    NSData *iv    = [ivPad subdataWithRange:NSMakeRange(0, MPGO_AES_IV_LEN)];

    MPGOHDF5Dataset *tagDS = [channels openDatasetNamed:@"intensity_tag" error:error];
    if (!tagDS) return nil;
    NSData *tagPad = [tagDS readDataWithError:error];
    NSData *tag    = [tagPad subdataWithRange:NSMakeRange(0, MPGO_AES_TAG_LEN)];

    return [self decryptData:cipher withKey:key iv:iv authTag:tag error:error];
}

+ (BOOL)isIntensityChannelEncryptedInRun:(NSString *)runName atFilePath:(NSString *)path
{
    MPGOHDF5File *file = [MPGOHDF5File openReadOnlyAtPath:path error:NULL];
    if (!file) return NO;
    MPGOHDF5Group *runGroup = [[file rootGroup] openGroupNamed:runName error:NULL];
    if (!runGroup) return NO;
    MPGOHDF5Group *channels = [runGroup openGroupNamed:@"signal_channels" error:NULL];
    if (!channels) return NO;
    BOOL has = [channels hasChildNamed:@"intensity_values_encrypted"];
    return has;
}

+ (BOOL)decryptIntensityChannelInRunInPlace:(NSString *)runName
                                 atFilePath:(NSString *)path
                                    withKey:(NSData *)key
                                      error:(NSError **)error
{
    if (key.length != MPGO_AES_KEY_LEN) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"AES-256-GCM requires a 32-byte key, got %lu",
            (unsigned long)key.length);
        return NO;
    }

    MPGOHDF5File *file = [MPGOHDF5File openAtPath:path error:error];
    if (!file) return NO;

    MPGOHDF5Group *runGroup = [[file rootGroup] openGroupNamed:runName error:error];
    if (!runGroup) { [file close]; return NO; }
    MPGOHDF5Group *channels =
        [runGroup openGroupNamed:@"signal_channels" error:error];
    if (!channels) { [file close]; return NO; }

    // Idempotent path: plaintext already, nothing to do.
    if (![channels hasChildNamed:@"intensity_values_encrypted"]) {
        return [file close];
    }

    BOOL cipherBytesExists = NO;
    int64_t cipherBytes =
        [channels integerAttributeNamed:@"intensity_ciphertext_bytes"
                                 exists:&cipherBytesExists
                                  error:error];
    if (!cipherBytesExists) {
        if (error) *error = MPGOMakeError(MPGOErrorAttributeRead,
            @"intensity_values_encrypted present but intensity_ciphertext_bytes is missing");
        [file close];
        return NO;
    }

    BOOL originalCountExists = NO;
    int64_t originalCount =
        [channels integerAttributeNamed:@"intensity_original_count"
                                 exists:&originalCountExists
                                  error:error];
    if (!originalCountExists) {
        if (error) *error = MPGOMakeError(MPGOErrorAttributeRead,
            @"intensity_values_encrypted present but intensity_original_count is missing");
        [file close];
        return NO;
    }

    MPGOHDF5Dataset *encDS =
        [channels openDatasetNamed:@"intensity_values_encrypted" error:error];
    if (!encDS) { [file close]; return NO; }
    NSData *padded = [encDS readDataWithError:error];
    if (!padded) { [file close]; return NO; }
    if ((NSUInteger)cipherBytes > padded.length) {
        if (error) *error = MPGOMakeError(MPGOErrorAttributeRead,
            @"intensity_ciphertext_bytes (%lld) exceeds encrypted dataset length (%lu)",
            (long long)cipherBytes, (unsigned long)padded.length);
        [file close];
        return NO;
    }
    NSData *cipher = [padded subdataWithRange:NSMakeRange(0, (NSUInteger)cipherBytes)];

    MPGOHDF5Dataset *ivDS = [channels openDatasetNamed:@"intensity_iv" error:error];
    if (!ivDS) { [file close]; return NO; }
    NSData *ivPad = [ivDS readDataWithError:error];
    if (!ivPad) { [file close]; return NO; }
    NSData *iv = [ivPad subdataWithRange:NSMakeRange(0, MPGO_AES_IV_LEN)];

    MPGOHDF5Dataset *tagDS = [channels openDatasetNamed:@"intensity_tag" error:error];
    if (!tagDS) { [file close]; return NO; }
    NSData *tagPad = [tagDS readDataWithError:error];
    if (!tagPad) { [file close]; return NO; }
    NSData *tag = [tagPad subdataWithRange:NSMakeRange(0, MPGO_AES_TAG_LEN)];

    NSData *plaintext = [self decryptData:cipher
                                  withKey:key
                                       iv:iv
                                  authTag:tag
                                    error:error];
    if (!plaintext) { [file close]; return NO; }
    if (plaintext.length != (NSUInteger)originalCount * sizeof(double)) {
        if (error) *error = MPGOMakeError(MPGOErrorUnknown,
            @"decrypted plaintext length (%lu) does not match intensity_original_count*8 (%lld)",
            (unsigned long)plaintext.length,
            (long long)((int64_t)originalCount * (int64_t)sizeof(double)));
        [file close];
        return NO;
    }

    // Release dataset handles before unlinking.
    encDS = nil;
    ivDS = nil;
    tagDS = nil;

    if (![channels deleteChildNamed:@"intensity_values_encrypted" error:error]) {
        [file close];
        return NO;
    }
    if (![channels deleteChildNamed:@"intensity_iv" error:error]) {
        [file close];
        return NO;
    }
    if (![channels deleteChildNamed:@"intensity_tag" error:error]) {
        [file close];
        return NO;
    }
    if (![channels deleteAttributeNamed:@"intensity_ciphertext_bytes" error:error]) {
        [file close];
        return NO;
    }
    if (![channels deleteAttributeNamed:@"intensity_original_count" error:error]) {
        [file close];
        return NO;
    }
    if (![channels deleteAttributeNamed:@"intensity_algorithm" error:error]) {
        [file close];
        return NO;
    }

    MPGOHDF5Dataset *plainDS =
        [channels createDatasetNamed:@"intensity_values"
                           precision:MPGOPrecisionFloat64
                              length:(NSUInteger)originalCount
                           chunkSize:0
                    compressionLevel:0
                               error:error];
    if (!plainDS) { [file close]; return NO; }
    if (![plainDS writeData:plaintext error:error]) { [file close]; return NO; }

    return [file close];
}

@end
