/*
 * TTIOKeyRotationManager.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOKeyRotationManager
 * Declared In:   Protection/TTIOKeyRotationManager.h
 *
 * Envelope encryption + key rotation. DEK + KEK key-wrapping with
 * O(1) rotation and a key_history audit trail.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOKeyRotationManager.h"
#import "TTIOEncryptionManager.h"
#import "TTIOPostQuantumCrypto.h"
#import "TTIOCipherSuite.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Dataset.h"
#import "HDF5/TTIOHDF5Errors.h"
#import "HDF5/TTIOFeatureFlags.h"
#import "ValueClasses/TTIOEnums.h"

// v1.1 wrapped DEK layout (legacy): 32 ciphertext bytes + 12-byte IV
// + 16-byte tag = 60 bytes total. v0.7 M47 default is the v1.2
// versioned blob (see packBlobV2 below for the layout).
static const NSUInteger TTIO_KR_DEK_LEN      = 32;
static const NSUInteger TTIO_KR_IV_LEN       = 12;
static const NSUInteger TTIO_KR_TAG_LEN      = 16;
static const NSUInteger TTIO_KR_V11_LEN      = 60;
// v1.2 versioned blob:
//   +0  2  magic        = 0x4D 0x57 ("MW" — TTIO Wrap)
//   +2  1  version      = 0x02
//   +3  2  algorithm_id (big-endian)
//                0x0000 = AES-256-GCM
//                0x0001 = ML-KEM-1024  (reserved, M49)
//   +5  4  ciphertext_len (big-endian)
//   +9  2  metadata_len   (big-endian)
//  +11  M  metadata  (AES-GCM: IV ‖ tag, M=28)
//  +11+M C  ciphertext
// Readers dispatch on total length: exactly 60 bytes ⇒ v1.1,
// anything else ⇒ v1.2.
static const NSUInteger TTIO_KR_V12_HEADER_LEN = 11;
static const uint16_t   TTIO_WK_ALG_AES_256_GCM = 0x0000;
static const uint16_t   TTIO_WK_ALG_ML_KEM_1024 = 0x0001;  // reserved (M49)

static NSString *const kKEKAlgorithmAES  = @"aes-256-gcm";
static NSString *const kKEKAlgorithmMLKEM = @"ml-kem-1024";

// v0.8 M49.1: ML-KEM-1024 envelope blob. Metadata = kem_ct(1568) ||
// aes_iv(12) || aes_tag(16) = 1596 bytes. Ciphertext = AES-GCM wrapped
// DEK = 32 bytes. Total blob length = 11 + 1596 + 32 = 1639 bytes.
static const NSUInteger TTIO_MLKEM_CT_LEN       = 1568;
static const NSUInteger TTIO_MLKEM_METADATA_LEN = 1596;  // = 1568 + 12 + 16
static const NSUInteger TTIO_MLKEM_BLOB_LEN     = 1639;  // = 11 + 1596 + 32

static void wkPutBE16(uint8_t *p, uint16_t v)
{
    p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)(v & 0xFF);
}

static void wkPutBE32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);  p[3] = (uint8_t)(v & 0xFF);
}

static uint16_t wkGetBE16(const uint8_t *p)
{
    return (uint16_t)((p[0] << 8) | p[1]);
}

static uint32_t wkGetBE32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16)
         | ((uint32_t)p[2] << 8)  | (uint32_t)p[3];
}

static NSString *iso8601Now(void)
{
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    fmt.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    return [fmt stringFromDate:[NSDate date]];
}

@implementation TTIOKeyRotationManager
{
    TTIOHDF5File *_file;
}

+ (instancetype)managerWithFile:(TTIOHDF5File *)file
{
    TTIOKeyRotationManager *m = [[self alloc] init];
    m->_file = file;
    return m;
}

#pragma mark - Helpers

// Returns an open /protection/ group, creating it on demand.
- (TTIOHDF5Group *)protectionGroupCreatingIfNeeded:(BOOL)create error:(NSError **)error
{
    TTIOHDF5Group *root = [_file rootGroup];
    if ([root hasChildNamed:@"protection"]) {
        return [root openGroupNamed:@"protection" error:error];
    }
    if (!create) return nil;
    return [root createGroupNamed:@"protection" error:error];
}

// Returns an open /protection/key_info group, creating it on demand.
- (TTIOHDF5Group *)keyInfoGroupCreatingIfNeeded:(BOOL)create error:(NSError **)error
{
    TTIOHDF5Group *prot = [self protectionGroupCreatingIfNeeded:create error:error];
    if (!prot) return nil;
    if ([prot hasChildNamed:@"key_info"]) {
        return [prot openGroupNamed:@"key_info" error:error];
    }
    if (!create) return nil;
    return [prot createGroupNamed:@"key_info" error:error];
}

// Pack a v1.2 wrapped-key blob. Public so M51 parity tooling and the
// M49 PQC preview can emit PQC-algorithm-id blobs.
+ (NSData *)packBlobV2:(uint16_t)algorithmId
             ciphertext:(NSData *)ciphertext
               metadata:(NSData *)metadata
                  error:(NSError **)error
{
    if (metadata.length > 0xFFFF) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"v1.2 wrapped-key metadata exceeds 64 KB");
        return nil;
    }
    NSUInteger totalLen = TTIO_KR_V12_HEADER_LEN + metadata.length
                         + ciphertext.length;
    NSMutableData *out = [NSMutableData dataWithLength:totalLen];
    uint8_t *p = out.mutableBytes;
    p[0] = 'M'; p[1] = 'W';
    p[2] = 0x02;  // version
    wkPutBE16(p + 3, algorithmId);
    wkPutBE32(p + 5, (uint32_t)ciphertext.length);
    wkPutBE16(p + 9, (uint16_t)metadata.length);
    memcpy(p + TTIO_KR_V12_HEADER_LEN, metadata.bytes, metadata.length);
    memcpy(p + TTIO_KR_V12_HEADER_LEN + metadata.length,
           ciphertext.bytes, ciphertext.length);
    return out;
}

// Parse a v1.2 wrapped-key blob. Returns NO + populated NSError on
// malformed input. On success, algorithmId + metadata + ciphertext
// are filled.
+ (BOOL)unpackBlobV2:(NSData *)blob
          algorithmId:(uint16_t *)outAlgorithmId
             metadata:(NSData **)outMetadata
           ciphertext:(NSData **)outCiphertext
                error:(NSError **)error
{
    if (blob.length < TTIO_KR_V12_HEADER_LEN) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"v1.2 wrapped-key blob too short (%lu bytes)",
            (unsigned long)blob.length);
        return NO;
    }
    const uint8_t *p = blob.bytes;
    if (p[0] != 'M' || p[1] != 'W') {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"v1.2 wrapped-key blob: bad magic");
        return NO;
    }
    if (p[2] != 0x02) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"v1.2 wrapped-key blob: unknown version 0x%02x", p[2]);
        return NO;
    }
    uint16_t alg    = wkGetBE16(p + 3);
    uint32_t ctLen  = wkGetBE32(p + 5);
    uint16_t mdLen  = wkGetBE16(p + 9);
    if (blob.length != (NSUInteger)(TTIO_KR_V12_HEADER_LEN + mdLen + ctLen)) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"v1.2 wrapped-key blob length mismatch: "
            @"header declares metadata=%u ciphertext=%u but payload is %lu",
            mdLen, ctLen,
            (unsigned long)(blob.length - TTIO_KR_V12_HEADER_LEN));
        return NO;
    }
    if (outAlgorithmId) *outAlgorithmId = alg;
    if (outMetadata) {
        *outMetadata = [blob subdataWithRange:
            NSMakeRange(TTIO_KR_V12_HEADER_LEN, mdLen)];
    }
    if (outCiphertext) {
        *outCiphertext = [blob subdataWithRange:
            NSMakeRange(TTIO_KR_V12_HEADER_LEN + mdLen, ctLen)];
    }
    return YES;
}

// Wrap a 32-byte plaintext (the DEK) under the given KEK using AES-256-GCM.
// v0.7 M47: default output is the v1.2 versioned blob (71 bytes for
// AES-GCM). Pass legacyV1=YES to emit the v1.1 60-byte layout for
// backward-compat fixture generation.
- (NSData *)wrapDEK:(NSData *)dek
            withKEK:(NSData *)kek
            legacyV1:(BOOL)legacyV1
              error:(NSError **)error
{
    if (dek.length != TTIO_KR_DEK_LEN || kek.length != TTIO_KR_DEK_LEN) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"wrapDEK: DEK and KEK must both be 32 bytes");
        return nil;
    }
    NSData *iv = nil, *tag = nil;
    NSData *cipher =
        [TTIOEncryptionManager encryptData:dek
                                    withKey:kek
                                         iv:&iv
                                    authTag:&tag
                                      error:error];
    if (!cipher || iv.length != TTIO_KR_IV_LEN || tag.length != TTIO_KR_TAG_LEN) {
        return nil;
    }
    if (legacyV1) {
        NSMutableData *out = [NSMutableData dataWithCapacity:TTIO_KR_V11_LEN];
        [out appendData:cipher];
        [out appendData:iv];
        [out appendData:tag];
        return out;
    }
    NSMutableData *metadata = [NSMutableData dataWithCapacity:
        TTIO_KR_IV_LEN + TTIO_KR_TAG_LEN];
    [metadata appendData:iv];
    [metadata appendData:tag];
    return [TTIOKeyRotationManager packBlobV2:TTIO_WK_ALG_AES_256_GCM
                                    ciphertext:cipher
                                      metadata:metadata
                                         error:error];
}

// Convenience: v1.2 wrap (default for v0.7+).
- (NSData *)wrapDEK:(NSData *)dek withKEK:(NSData *)kek error:(NSError **)error
{
    return [self wrapDEK:dek withKEK:kek legacyV1:NO error:error];
}

// v0.8 M49.1: wrap the DEK under ML-KEM-1024. `publicKey` must be the
// 1568-byte ML-KEM encapsulation public key. Returns a v1.2 blob with
// algorithm_id=0x0001. Always emits the AEAD-inner-wrap chain
// (encapsulate → AES-256-GCM wrap under shared secret).
- (NSData *)wrapDEKWithMLKEMPublicKey:(NSData *)publicKey
                                   dek:(NSData *)dek
                                 error:(NSError **)error
{
    if (dek.length != TTIO_KR_DEK_LEN) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"wrapDEK (ML-KEM): DEK must be 32 bytes (got %lu)",
            (unsigned long)dek.length);
        return nil;
    }
    if (![TTIOCipherSuite validatePublicKey:publicKey
                                   algorithm:kKEKAlgorithmMLKEM
                                       error:error]) {
        return nil;
    }
    TTIOPQCKemEncapResult *enc =
        [TTIOPostQuantumCrypto kemEncapsulateWithPublicKey:publicKey
                                                     error:error];
    if (!enc) return nil;

    // Wrap the DEK under the 32-byte shared secret with AES-256-GCM.
    NSData *iv = nil, *tag = nil;
    NSData *cipher =
        [TTIOEncryptionManager encryptData:dek
                                    withKey:enc.sharedSecret
                                         iv:&iv
                                    authTag:&tag
                                      error:error];
    if (!cipher
        || iv.length != TTIO_KR_IV_LEN
        || tag.length != TTIO_KR_TAG_LEN) {
        return nil;
    }
    NSMutableData *metadata = [NSMutableData dataWithCapacity:TTIO_MLKEM_METADATA_LEN];
    [metadata appendData:enc.ciphertext];  // 1568
    [metadata appendData:iv];              //   12
    [metadata appendData:tag];             //   16
    NSAssert(metadata.length == TTIO_MLKEM_METADATA_LEN,
             @"ML-KEM metadata length mismatch");
    return [TTIOKeyRotationManager packBlobV2:TTIO_WK_ALG_ML_KEM_1024
                                    ciphertext:cipher
                                      metadata:metadata
                                         error:error];
}

// v0.8 M49.1: inverse of -wrapDEKWithMLKEMPublicKey:. `privateKey` is
// the 3168-byte ML-KEM decapsulation key.
- (NSData *)unwrapMLKEMBlob:(NSData *)wrapped
          withPrivateKey:(NSData *)privateKey
                   error:(NSError **)error
{
    if (![TTIOCipherSuite validatePrivateKey:privateKey
                                    algorithm:kKEKAlgorithmMLKEM
                                        error:error]) {
        return nil;
    }
    uint16_t alg = 0;
    NSData *md = nil, *ct = nil;
    if (![TTIOKeyRotationManager unpackBlobV2:wrapped
                                    algorithmId:&alg
                                       metadata:&md
                                     ciphertext:&ct
                                          error:error]) {
        return nil;
    }
    if (alg != TTIO_WK_ALG_ML_KEM_1024) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"ML-KEM unwrap: expected algorithm_id=0x0001, got 0x%04x",
            alg);
        return nil;
    }
    if (md.length != TTIO_MLKEM_METADATA_LEN) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"ML-KEM metadata must be %lu bytes (kem_ct || iv || tag); "
            @"got %lu",
            (unsigned long)TTIO_MLKEM_METADATA_LEN,
            (unsigned long)md.length);
        return nil;
    }
    if (ct.length != TTIO_KR_DEK_LEN) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"ML-KEM wrapped DEK ciphertext must be %lu bytes; got %lu",
            (unsigned long)TTIO_KR_DEK_LEN, (unsigned long)ct.length);
        return nil;
    }
    NSData *kemCt = [md subdataWithRange:NSMakeRange(0, TTIO_MLKEM_CT_LEN)];
    NSData *iv    = [md subdataWithRange:
        NSMakeRange(TTIO_MLKEM_CT_LEN, TTIO_KR_IV_LEN)];
    NSData *tag   = [md subdataWithRange:
        NSMakeRange(TTIO_MLKEM_CT_LEN + TTIO_KR_IV_LEN, TTIO_KR_TAG_LEN)];

    NSData *sharedSecret =
        [TTIOPostQuantumCrypto kemDecapsulateWithPrivateKey:privateKey
                                                  ciphertext:kemCt
                                                       error:error];
    if (!sharedSecret) return nil;

    return [TTIOEncryptionManager decryptData:ct
                                       withKey:sharedSecret
                                            iv:iv
                                       authTag:tag
                                         error:error];
}

// Ensure opt_pqc_preview is present on the root feature list. Idempotent.
- (BOOL)markPQCPreviewOnRootWithError:(NSError **)error
{
    TTIOHDF5Group *root = [_file rootGroup];
    NSArray<NSString *> *features = [TTIOFeatureFlags featuresForRoot:root];
    NSString *flag = [TTIOFeatureFlags featurePQCPreview];
    if ([features containsObject:flag]) return YES;
    NSMutableArray *updated = [features mutableCopy] ?: [NSMutableArray array];
    [updated addObject:flag];
    NSString *version = [TTIOFeatureFlags formatVersionForRoot:root] ?: @"1.2";
    return [TTIOFeatureFlags writeFormatVersion:version
                                        features:updated
                                          toRoot:root
                                           error:error];
}

// Inverse of wrapDEK:. Dispatches on blob length: exactly 60 bytes
// ⇒ v1.1 legacy, anything else ⇒ v1.2. Returns the 32-byte plaintext
// DEK or nil on auth failure / malformed input / unsupported algorithm.
- (NSData *)unwrapBlob:(NSData *)wrapped withKEK:(NSData *)kek error:(NSError **)error
{
    NSData *cipher, *iv, *tag;
    if (wrapped.length == TTIO_KR_V11_LEN) {
        // v1.1 legacy path.
        cipher = [wrapped subdataWithRange:NSMakeRange(0, TTIO_KR_DEK_LEN)];
        iv     = [wrapped subdataWithRange:NSMakeRange(TTIO_KR_DEK_LEN, TTIO_KR_IV_LEN)];
        tag    = [wrapped subdataWithRange:NSMakeRange(TTIO_KR_DEK_LEN + TTIO_KR_IV_LEN,
                                                         TTIO_KR_TAG_LEN)];
    } else {
        uint16_t alg = 0;
        NSData *md = nil, *ct = nil;
        if (![TTIOKeyRotationManager unpackBlobV2:wrapped
                                        algorithmId:&alg
                                           metadata:&md
                                         ciphertext:&ct
                                              error:error]) {
            return nil;
        }
        if (alg != TTIO_WK_ALG_AES_256_GCM) {
            if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
                @"v1.2 wrapped-key blob uses algorithm_id=0x%04x which "
                @"this build does not support (enable pqc_preview for "
                @"ML-KEM-1024 in M49+)", alg);
            return nil;
        }
        if (md.length != TTIO_KR_IV_LEN + TTIO_KR_TAG_LEN) {
            if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
                @"v1.2 AES-GCM metadata must be 28 bytes; got %lu",
                (unsigned long)md.length);
            return nil;
        }
        if (ct.length != TTIO_KR_DEK_LEN) {
            if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
                @"v1.2 AES-GCM ciphertext must be 32 bytes; got %lu",
                (unsigned long)ct.length);
            return nil;
        }
        cipher = ct;
        iv     = [md subdataWithRange:NSMakeRange(0, TTIO_KR_IV_LEN)];
        tag    = [md subdataWithRange:NSMakeRange(TTIO_KR_IV_LEN, TTIO_KR_TAG_LEN)];
    }
    return [TTIOEncryptionManager decryptData:cipher
                                       withKey:kek
                                            iv:iv
                                       authTag:tag
                                         error:error];
}

// Read the wrapped blob from /protection/key_info/dek_wrapped.
- (NSData *)readWrappedBlob:(TTIOHDF5Group *)keyInfo error:(NSError **)error
{
    TTIOHDF5Dataset *ds = [keyInfo openDatasetNamed:@"dek_wrapped" error:error];
    if (!ds) return nil;
    NSData *raw = [ds readDataWithError:error];
    return raw;
}

// Write (or overwrite) the wrapped blob at /protection/key_info/dek_wrapped.
// v0.7 M47: blob length now varies (v1.1 = 60 bytes, v1.2 AES-GCM =
// 71 bytes, v1.2 ML-KEM = 1579 bytes). Pad to int32 boundary and
// store the real byte length in @dek_wrapped_bytes so readers can
// recover it precisely; pre-v0.7 readers default to 60 bytes and
// tolerate the extra padding harmlessly.
- (BOOL)writeWrappedBlob:(NSData *)blob
                  group:(TTIOHDF5Group *)keyInfo
                  error:(NSError **)error
{
    if ([keyInfo hasChildNamed:@"dek_wrapped"]) {
        if (![keyInfo deleteChildNamed:@"dek_wrapped" error:error]) return NO;
    }
    NSUInteger padded = ((blob.length + 3) / 4) * 4;
    NSMutableData *padBuf = [NSMutableData dataWithLength:padded];
    memcpy(padBuf.mutableBytes, blob.bytes, blob.length);
    TTIOHDF5Dataset *ds =
        [keyInfo createDatasetNamed:@"dek_wrapped"
                           precision:TTIOPrecisionInt32
                              length:padded / sizeof(int32_t)
                           chunkSize:0
                    compressionLevel:0
                               error:error];
    if (!ds) return NO;
    if (![ds writeData:padBuf error:error]) return NO;
    return [keyInfo setIntegerAttribute:@"dek_wrapped_bytes"
                                   value:(int64_t)blob.length
                                   error:error];
}

// Read the wrapped blob with v0.7+ length awareness. Pre-v0.7 files
// lack @dek_wrapped_bytes and are always exactly 60 bytes.
- (NSData *)readWrappedBlobWithLength:(TTIOHDF5Group *)keyInfo
                                 error:(NSError **)error
{
    NSData *raw = [self readWrappedBlob:keyInfo error:error];
    if (!raw) return nil;
    BOOL exists = NO;
    int64_t declared = [keyInfo integerAttributeNamed:@"dek_wrapped_bytes"
                                                  exists:&exists
                                                   error:NULL];
    if (!exists) declared = TTIO_KR_V11_LEN;
    if (declared <= 0 || (NSUInteger)declared > raw.length) {
        return raw;  // sentinel / corruption: hand back the raw bytes.
    }
    return [raw subdataWithRange:NSMakeRange(0, (NSUInteger)declared)];
}

- (NSString *)readCurrentKEKId:(TTIOHDF5Group *)keyInfo
{
    return [keyInfo stringAttributeNamed:@"kek_id" error:NULL];
}

- (NSString *)readWrappedAt:(TTIOHDF5Group *)keyInfo
{
    return [keyInfo stringAttributeNamed:@"wrapped_at" error:NULL];
}

#pragma mark - Public API

- (BOOL)hasEnvelopeEncryption
{
    NSError *err = nil;
    TTIOHDF5Group *ki = [self keyInfoGroupCreatingIfNeeded:NO error:&err];
    if (!ki) return NO;
    return [ki hasChildNamed:@"dek_wrapped"];
}

- (NSData *)enableEnvelopeEncryptionWithKEK:(NSData *)kek
                                      kekId:(NSString *)kekId
                                      error:(NSError **)error
{
    return [self enableEnvelopeEncryptionWithKEK:kek
                                           kekId:kekId
                                       algorithm:kKEKAlgorithmAES
                                           error:error];
}

- (NSData *)enableEnvelopeEncryptionWithKEK:(NSData *)kek
                                      kekId:(NSString *)kekId
                                   algorithm:(NSString *)algorithm
                                       error:(NSError **)error
{
    // Fresh random DEK — AES-256 regardless of the wrap algorithm
    // (HANDOFF binding #43).
    NSMutableData *dek = [NSMutableData dataWithLength:TTIO_KR_DEK_LEN];
    arc4random_buf(dek.mutableBytes, TTIO_KR_DEK_LEN);

    NSData *wrapped = nil;
    if ([algorithm isEqualToString:kKEKAlgorithmAES]) {
        if (kek.length != TTIO_KR_DEK_LEN) {
            if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
                @"enableEnvelopeEncryption: AES KEK must be 32 bytes");
            return nil;
        }
        wrapped = [self wrapDEK:dek withKEK:kek error:error];
    } else if ([algorithm isEqualToString:kKEKAlgorithmMLKEM]) {
        wrapped = [self wrapDEKWithMLKEMPublicKey:kek dek:dek error:error];
    } else {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"enableEnvelopeEncryption: algorithm %@ not supported",
            algorithm);
        return nil;
    }
    if (!wrapped) return nil;

    TTIOHDF5Group *ki = [self keyInfoGroupCreatingIfNeeded:YES error:error];
    if (!ki) return nil;
    if (![self writeWrappedBlob:wrapped group:ki error:error]) return nil;

    if (![ki setStringAttribute:@"kek_id" value:(kekId ?: @"") error:error]) return nil;
    if (![ki setStringAttribute:@"kek_algorithm" value:algorithm error:error]) return nil;
    if (![ki setStringAttribute:@"wrapped_at" value:iso8601Now() error:error]) return nil;
    if (![ki setStringAttribute:@"key_history_json" value:@"[]" error:error]) return nil;

    if ([algorithm isEqualToString:kKEKAlgorithmMLKEM]) {
        if (![self markPQCPreviewOnRootWithError:error]) return nil;
    }

    return [dek copy];
}

- (NSData *)unwrapDEKWithKEK:(NSData *)kek error:(NSError **)error
{
    return [self unwrapDEKWithKEK:kek
                         algorithm:kKEKAlgorithmAES
                             error:error];
}

- (NSData *)unwrapDEKWithKEK:(NSData *)kek
                    algorithm:(NSString *)algorithm
                        error:(NSError **)error
{
    TTIOHDF5Group *ki = [self keyInfoGroupCreatingIfNeeded:NO error:error];
    if (!ki) {
        if (error && !*error) *error = TTIOMakeError(TTIOErrorFileOpen,
            @"unwrapDEK: /protection/key_info missing");
        return nil;
    }
    NSData *wrapped = [self readWrappedBlobWithLength:ki error:error];
    if (!wrapped) return nil;

    if ([algorithm isEqualToString:kKEKAlgorithmAES]) {
        return [self unwrapBlob:wrapped withKEK:kek error:error];
    }
    if ([algorithm isEqualToString:kKEKAlgorithmMLKEM]) {
        return [self unwrapMLKEMBlob:wrapped
                      withPrivateKey:kek
                               error:error];
    }
    if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
        @"unwrapDEK: algorithm %@ not supported", algorithm);
    return nil;
}

- (BOOL)rotateToKEK:(NSData *)newKEK
              kekId:(NSString *)newKEKId
             oldKEK:(NSData *)oldKEK
              error:(NSError **)error
{
    return [self rotateToKEK:newKEK
                       kekId:newKEKId
                      oldKEK:oldKEK
                oldAlgorithm:kKEKAlgorithmAES
                newAlgorithm:kKEKAlgorithmAES
                       error:error];
}

- (BOOL)rotateToKEK:(NSData *)newKEK
              kekId:(NSString *)newKEKId
             oldKEK:(NSData *)oldKEK
        oldAlgorithm:(NSString *)oldAlgorithm
        newAlgorithm:(NSString *)newAlgorithm
              error:(NSError **)error
{
    // Recover the DEK under the old algorithm/KEK — authenticates the
    // rotation source.
    NSData *dek = [self unwrapDEKWithKEK:oldKEK
                                algorithm:oldAlgorithm
                                    error:error];
    if (!dek) return NO;

    NSData *wrapped = nil;
    if ([newAlgorithm isEqualToString:kKEKAlgorithmAES]) {
        if (newKEK.length != TTIO_KR_DEK_LEN) {
            if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
                @"rotateToKEK: AES KEK must be 32 bytes");
            return NO;
        }
        wrapped = [self wrapDEK:dek withKEK:newKEK error:error];
    } else if ([newAlgorithm isEqualToString:kKEKAlgorithmMLKEM]) {
        wrapped = [self wrapDEKWithMLKEMPublicKey:newKEK dek:dek error:error];
    } else {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"rotateToKEK: algorithm %@ not supported", newAlgorithm);
        return NO;
    }
    if (!wrapped) return NO;

    TTIOHDF5Group *ki = [self keyInfoGroupCreatingIfNeeded:NO error:error];
    if (!ki) return NO;

    // Snapshot the outgoing attributes so we can append an entry to the
    // key history before clobbering them.
    NSString *oldKekId = [self readCurrentKEKId:ki] ?: @"";
    NSString *oldWrappedAt = [self readWrappedAt:ki] ?: @"";
    NSString *oldAlgAttr =
        [ki stringAttributeNamed:@"kek_algorithm" error:NULL] ?: oldAlgorithm;
    NSString *historyJson =
        [ki stringAttributeNamed:@"key_history_json" error:NULL] ?: @"[]";
    NSData *hJsonData = [historyJson dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableArray *entries =
        [NSJSONSerialization JSONObjectWithData:hJsonData
                                         options:NSJSONReadingMutableContainers
                                           error:NULL];
    if (![entries isKindOfClass:[NSMutableArray class]]) entries = [NSMutableArray array];
    [entries addObject:@{
        @"timestamp":     oldWrappedAt,
        @"kek_id":        oldKekId,
        @"kek_algorithm": oldAlgAttr,
    }];
    NSData *newHistoryData =
        [NSJSONSerialization dataWithJSONObject:entries options:0 error:NULL];
    NSString *newHistoryJson =
        [[NSString alloc] initWithData:newHistoryData encoding:NSUTF8StringEncoding];

    if (![self writeWrappedBlob:wrapped group:ki error:error]) return NO;
    if (![ki setStringAttribute:@"kek_id" value:(newKEKId ?: @"") error:error]) return NO;
    if (![ki setStringAttribute:@"kek_algorithm" value:newAlgorithm error:error]) return NO;
    if (![ki setStringAttribute:@"wrapped_at" value:iso8601Now() error:error]) return NO;
    if (![ki setStringAttribute:@"key_history_json" value:newHistoryJson error:error]) return NO;

    if ([newAlgorithm isEqualToString:kKEKAlgorithmMLKEM]) {
        if (![self markPQCPreviewOnRootWithError:error]) return NO;
    }

    return YES;
}

- (NSArray<NSDictionary *> *)keyHistory
{
    TTIOHDF5Group *ki = [self keyInfoGroupCreatingIfNeeded:NO error:NULL];
    if (!ki) return @[];
    NSString *json = [ki stringAttributeNamed:@"key_history_json" error:NULL];
    if (json.length == 0) return @[];
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [arr isKindOfClass:[NSArray class]] ? arr : @[];
}

@end
