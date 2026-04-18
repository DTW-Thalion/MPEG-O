#import "MPGOKeyRotationManager.h"
#import "MPGOEncryptionManager.h"
#import "HDF5/MPGOHDF5File.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Dataset.h"
#import "HDF5/MPGOHDF5Errors.h"
#import "ValueClasses/MPGOEnums.h"

// v1.1 wrapped DEK layout (legacy): 32 ciphertext bytes + 12-byte IV
// + 16-byte tag = 60 bytes total. v0.7 M47 default is the v1.2
// versioned blob (see packBlobV2 below for the layout).
static const NSUInteger MPGO_KR_DEK_LEN      = 32;
static const NSUInteger MPGO_KR_IV_LEN       = 12;
static const NSUInteger MPGO_KR_TAG_LEN      = 16;
static const NSUInteger MPGO_KR_V11_LEN      = 60;
// v1.2 versioned blob:
//   +0  2  magic        = 0x4D 0x57 ("MW" — MPGO Wrap)
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
static const NSUInteger MPGO_KR_V12_HEADER_LEN = 11;
static const uint16_t   MPGO_WK_ALG_AES_256_GCM = 0x0000;
static const uint16_t   MPGO_WK_ALG_ML_KEM_1024 = 0x0001;  // reserved (M49)

static NSString *const kKEKAlgorithm = @"aes-256-gcm";

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

@implementation MPGOKeyRotationManager
{
    MPGOHDF5File *_file;
}

+ (instancetype)managerWithFile:(MPGOHDF5File *)file
{
    MPGOKeyRotationManager *m = [[self alloc] init];
    m->_file = file;
    return m;
}

#pragma mark - Helpers

// Returns an open /protection/ group, creating it on demand.
- (MPGOHDF5Group *)protectionGroupCreatingIfNeeded:(BOOL)create error:(NSError **)error
{
    MPGOHDF5Group *root = [_file rootGroup];
    if ([root hasChildNamed:@"protection"]) {
        return [root openGroupNamed:@"protection" error:error];
    }
    if (!create) return nil;
    return [root createGroupNamed:@"protection" error:error];
}

// Returns an open /protection/key_info group, creating it on demand.
- (MPGOHDF5Group *)keyInfoGroupCreatingIfNeeded:(BOOL)create error:(NSError **)error
{
    MPGOHDF5Group *prot = [self protectionGroupCreatingIfNeeded:create error:error];
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
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"v1.2 wrapped-key metadata exceeds 64 KB");
        return nil;
    }
    NSUInteger totalLen = MPGO_KR_V12_HEADER_LEN + metadata.length
                         + ciphertext.length;
    NSMutableData *out = [NSMutableData dataWithLength:totalLen];
    uint8_t *p = out.mutableBytes;
    p[0] = 'M'; p[1] = 'W';
    p[2] = 0x02;  // version
    wkPutBE16(p + 3, algorithmId);
    wkPutBE32(p + 5, (uint32_t)ciphertext.length);
    wkPutBE16(p + 9, (uint16_t)metadata.length);
    memcpy(p + MPGO_KR_V12_HEADER_LEN, metadata.bytes, metadata.length);
    memcpy(p + MPGO_KR_V12_HEADER_LEN + metadata.length,
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
    if (blob.length < MPGO_KR_V12_HEADER_LEN) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"v1.2 wrapped-key blob too short (%lu bytes)",
            (unsigned long)blob.length);
        return NO;
    }
    const uint8_t *p = blob.bytes;
    if (p[0] != 'M' || p[1] != 'W') {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"v1.2 wrapped-key blob: bad magic");
        return NO;
    }
    if (p[2] != 0x02) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"v1.2 wrapped-key blob: unknown version 0x%02x", p[2]);
        return NO;
    }
    uint16_t alg    = wkGetBE16(p + 3);
    uint32_t ctLen  = wkGetBE32(p + 5);
    uint16_t mdLen  = wkGetBE16(p + 9);
    if (blob.length != (NSUInteger)(MPGO_KR_V12_HEADER_LEN + mdLen + ctLen)) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"v1.2 wrapped-key blob length mismatch: "
            @"header declares metadata=%u ciphertext=%u but payload is %lu",
            mdLen, ctLen,
            (unsigned long)(blob.length - MPGO_KR_V12_HEADER_LEN));
        return NO;
    }
    if (outAlgorithmId) *outAlgorithmId = alg;
    if (outMetadata) {
        *outMetadata = [blob subdataWithRange:
            NSMakeRange(MPGO_KR_V12_HEADER_LEN, mdLen)];
    }
    if (outCiphertext) {
        *outCiphertext = [blob subdataWithRange:
            NSMakeRange(MPGO_KR_V12_HEADER_LEN + mdLen, ctLen)];
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
    if (dek.length != MPGO_KR_DEK_LEN || kek.length != MPGO_KR_DEK_LEN) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"wrapDEK: DEK and KEK must both be 32 bytes");
        return nil;
    }
    NSData *iv = nil, *tag = nil;
    NSData *cipher =
        [MPGOEncryptionManager encryptData:dek
                                    withKey:kek
                                         iv:&iv
                                    authTag:&tag
                                      error:error];
    if (!cipher || iv.length != MPGO_KR_IV_LEN || tag.length != MPGO_KR_TAG_LEN) {
        return nil;
    }
    if (legacyV1) {
        NSMutableData *out = [NSMutableData dataWithCapacity:MPGO_KR_V11_LEN];
        [out appendData:cipher];
        [out appendData:iv];
        [out appendData:tag];
        return out;
    }
    NSMutableData *metadata = [NSMutableData dataWithCapacity:
        MPGO_KR_IV_LEN + MPGO_KR_TAG_LEN];
    [metadata appendData:iv];
    [metadata appendData:tag];
    return [MPGOKeyRotationManager packBlobV2:MPGO_WK_ALG_AES_256_GCM
                                    ciphertext:cipher
                                      metadata:metadata
                                         error:error];
}

// Convenience: v1.2 wrap (default for v0.7+).
- (NSData *)wrapDEK:(NSData *)dek withKEK:(NSData *)kek error:(NSError **)error
{
    return [self wrapDEK:dek withKEK:kek legacyV1:NO error:error];
}

// Inverse of wrapDEK:. Dispatches on blob length: exactly 60 bytes
// ⇒ v1.1 legacy, anything else ⇒ v1.2. Returns the 32-byte plaintext
// DEK or nil on auth failure / malformed input / unsupported algorithm.
- (NSData *)unwrapBlob:(NSData *)wrapped withKEK:(NSData *)kek error:(NSError **)error
{
    NSData *cipher, *iv, *tag;
    if (wrapped.length == MPGO_KR_V11_LEN) {
        // v1.1 legacy path.
        cipher = [wrapped subdataWithRange:NSMakeRange(0, MPGO_KR_DEK_LEN)];
        iv     = [wrapped subdataWithRange:NSMakeRange(MPGO_KR_DEK_LEN, MPGO_KR_IV_LEN)];
        tag    = [wrapped subdataWithRange:NSMakeRange(MPGO_KR_DEK_LEN + MPGO_KR_IV_LEN,
                                                         MPGO_KR_TAG_LEN)];
    } else {
        uint16_t alg = 0;
        NSData *md = nil, *ct = nil;
        if (![MPGOKeyRotationManager unpackBlobV2:wrapped
                                        algorithmId:&alg
                                           metadata:&md
                                         ciphertext:&ct
                                              error:error]) {
            return nil;
        }
        if (alg != MPGO_WK_ALG_AES_256_GCM) {
            if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
                @"v1.2 wrapped-key blob uses algorithm_id=0x%04x which "
                @"this build does not support (enable pqc_preview for "
                @"ML-KEM-1024 in M49+)", alg);
            return nil;
        }
        if (md.length != MPGO_KR_IV_LEN + MPGO_KR_TAG_LEN) {
            if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
                @"v1.2 AES-GCM metadata must be 28 bytes; got %lu",
                (unsigned long)md.length);
            return nil;
        }
        if (ct.length != MPGO_KR_DEK_LEN) {
            if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
                @"v1.2 AES-GCM ciphertext must be 32 bytes; got %lu",
                (unsigned long)ct.length);
            return nil;
        }
        cipher = ct;
        iv     = [md subdataWithRange:NSMakeRange(0, MPGO_KR_IV_LEN)];
        tag    = [md subdataWithRange:NSMakeRange(MPGO_KR_IV_LEN, MPGO_KR_TAG_LEN)];
    }
    return [MPGOEncryptionManager decryptData:cipher
                                       withKey:kek
                                            iv:iv
                                       authTag:tag
                                         error:error];
}

// Read the wrapped blob from /protection/key_info/dek_wrapped.
- (NSData *)readWrappedBlob:(MPGOHDF5Group *)keyInfo error:(NSError **)error
{
    MPGOHDF5Dataset *ds = [keyInfo openDatasetNamed:@"dek_wrapped" error:error];
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
                  group:(MPGOHDF5Group *)keyInfo
                  error:(NSError **)error
{
    if ([keyInfo hasChildNamed:@"dek_wrapped"]) {
        if (![keyInfo deleteChildNamed:@"dek_wrapped" error:error]) return NO;
    }
    NSUInteger padded = ((blob.length + 3) / 4) * 4;
    NSMutableData *padBuf = [NSMutableData dataWithLength:padded];
    memcpy(padBuf.mutableBytes, blob.bytes, blob.length);
    MPGOHDF5Dataset *ds =
        [keyInfo createDatasetNamed:@"dek_wrapped"
                           precision:MPGOPrecisionInt32
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
- (NSData *)readWrappedBlobWithLength:(MPGOHDF5Group *)keyInfo
                                 error:(NSError **)error
{
    NSData *raw = [self readWrappedBlob:keyInfo error:error];
    if (!raw) return nil;
    BOOL exists = NO;
    int64_t declared = [keyInfo integerAttributeNamed:@"dek_wrapped_bytes"
                                                  exists:&exists
                                                   error:NULL];
    if (!exists) declared = MPGO_KR_V11_LEN;
    if (declared <= 0 || (NSUInteger)declared > raw.length) {
        return raw;  // sentinel / corruption: hand back the raw bytes.
    }
    return [raw subdataWithRange:NSMakeRange(0, (NSUInteger)declared)];
}

- (NSString *)readCurrentKEKId:(MPGOHDF5Group *)keyInfo
{
    return [keyInfo stringAttributeNamed:@"kek_id" error:NULL];
}

- (NSString *)readWrappedAt:(MPGOHDF5Group *)keyInfo
{
    return [keyInfo stringAttributeNamed:@"wrapped_at" error:NULL];
}

#pragma mark - Public API

- (BOOL)hasEnvelopeEncryption
{
    NSError *err = nil;
    MPGOHDF5Group *ki = [self keyInfoGroupCreatingIfNeeded:NO error:&err];
    if (!ki) return NO;
    return [ki hasChildNamed:@"dek_wrapped"];
}

- (NSData *)enableEnvelopeEncryptionWithKEK:(NSData *)kek
                                      kekId:(NSString *)kekId
                                      error:(NSError **)error
{
    if (kek.length != MPGO_KR_DEK_LEN) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"enableEnvelopeEncryption: KEK must be 32 bytes");
        return nil;
    }
    // Fresh random DEK via the same CSPRNG path MPGOEncryptionManager uses
    // to generate its IVs: request an encryption of the zero vector, which
    // simply returns the plaintext back XOR-free and yields random IV/tag
    // state. For DEK we just call arc4random_buf.
    NSMutableData *dek = [NSMutableData dataWithLength:MPGO_KR_DEK_LEN];
    arc4random_buf(dek.mutableBytes, MPGO_KR_DEK_LEN);

    NSData *wrapped = [self wrapDEK:dek withKEK:kek error:error];
    if (!wrapped) return nil;

    MPGOHDF5Group *ki = [self keyInfoGroupCreatingIfNeeded:YES error:error];
    if (!ki) return nil;
    if (![self writeWrappedBlob:wrapped group:ki error:error]) return nil;

    if (![ki setStringAttribute:@"kek_id" value:(kekId ?: @"") error:error]) return nil;
    if (![ki setStringAttribute:@"kek_algorithm" value:kKEKAlgorithm error:error]) return nil;
    if (![ki setStringAttribute:@"wrapped_at" value:iso8601Now() error:error]) return nil;
    if (![ki setStringAttribute:@"key_history_json" value:@"[]" error:error]) return nil;

    return [dek copy];
}

- (NSData *)unwrapDEKWithKEK:(NSData *)kek error:(NSError **)error
{
    MPGOHDF5Group *ki = [self keyInfoGroupCreatingIfNeeded:NO error:error];
    if (!ki) {
        if (error && !*error) *error = MPGOMakeError(MPGOErrorFileOpen,
            @"unwrapDEK: /protection/key_info missing");
        return nil;
    }
    NSData *wrapped = [self readWrappedBlobWithLength:ki error:error];
    if (!wrapped) return nil;
    return [self unwrapBlob:wrapped withKEK:kek error:error];
}

- (BOOL)rotateToKEK:(NSData *)newKEK
              kekId:(NSString *)newKEKId
             oldKEK:(NSData *)oldKEK
              error:(NSError **)error
{
    // Recover the DEK with the old KEK; reject the rotation if the old
    // KEK doesn't authenticate the wrapped blob.
    NSData *dek = [self unwrapDEKWithKEK:oldKEK error:error];
    if (!dek) return NO;

    NSData *wrapped = [self wrapDEK:dek withKEK:newKEK error:error];
    if (!wrapped) return NO;

    MPGOHDF5Group *ki = [self keyInfoGroupCreatingIfNeeded:NO error:error];
    if (!ki) return NO;

    // Snapshot the outgoing attributes so we can append an entry to the
    // key history before clobbering them.
    NSString *oldKekId = [self readCurrentKEKId:ki] ?: @"";
    NSString *oldWrappedAt = [self readWrappedAt:ki] ?: @"";
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
        @"kek_algorithm": kKEKAlgorithm,
    }];
    NSData *newHistoryData =
        [NSJSONSerialization dataWithJSONObject:entries options:0 error:NULL];
    NSString *newHistoryJson =
        [[NSString alloc] initWithData:newHistoryData encoding:NSUTF8StringEncoding];

    // Overwrite dek_wrapped with the freshly wrapped blob.
    if (![self writeWrappedBlob:wrapped group:ki error:error]) return NO;

    // setStringAttribute deletes-and-recreates so these updates are idempotent.
    if (![ki setStringAttribute:@"kek_id" value:(newKEKId ?: @"") error:error]) return NO;
    if (![ki setStringAttribute:@"kek_algorithm" value:kKEKAlgorithm error:error]) return NO;
    if (![ki setStringAttribute:@"wrapped_at" value:iso8601Now() error:error]) return NO;
    if (![ki setStringAttribute:@"key_history_json" value:newHistoryJson error:error]) return NO;

    return YES;
}

- (NSArray<NSDictionary *> *)keyHistory
{
    MPGOHDF5Group *ki = [self keyInfoGroupCreatingIfNeeded:NO error:NULL];
    if (!ki) return @[];
    NSString *json = [ki stringAttributeNamed:@"key_history_json" error:NULL];
    if (json.length == 0) return @[];
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [arr isKindOfClass:[NSArray class]] ? arr : @[];
}

@end
