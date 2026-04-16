#import "MPGOKeyRotationManager.h"
#import "MPGOEncryptionManager.h"
#import "HDF5/MPGOHDF5File.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Dataset.h"
#import "HDF5/MPGOHDF5Errors.h"
#import "ValueClasses/MPGOEnums.h"

// Wrapped DEK layout is 32 ciphertext bytes + 12-byte IV + 16-byte tag.
static const NSUInteger MPGO_KR_DEK_LEN     = 32;
static const NSUInteger MPGO_KR_IV_LEN      = 12;
static const NSUInteger MPGO_KR_TAG_LEN     = 16;
static const NSUInteger MPGO_KR_WRAPPED_LEN = 60;

static NSString *const kKEKAlgorithm = @"aes-256-gcm";

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

// Wrap a 32-byte plaintext (the DEK) under the given KEK using AES-256-GCM.
// Returns a 60-byte NSData: [32 ciphertext | 12 iv | 16 tag].
- (NSData *)wrapDEK:(NSData *)dek withKEK:(NSData *)kek error:(NSError **)error
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
    NSMutableData *out = [NSMutableData dataWithCapacity:MPGO_KR_WRAPPED_LEN];
    [out appendData:cipher];
    [out appendData:iv];
    [out appendData:tag];
    return out;
}

// Inverse of wrapDEK:. Returns the 32-byte plaintext DEK or nil on auth failure.
- (NSData *)unwrapBlob:(NSData *)wrapped withKEK:(NSData *)kek error:(NSError **)error
{
    if (wrapped.length != MPGO_KR_WRAPPED_LEN) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"unwrapDEK: wrapped blob must be exactly 60 bytes");
        return nil;
    }
    NSData *cipher = [wrapped subdataWithRange:NSMakeRange(0, MPGO_KR_DEK_LEN)];
    NSData *iv     = [wrapped subdataWithRange:NSMakeRange(MPGO_KR_DEK_LEN, MPGO_KR_IV_LEN)];
    NSData *tag    = [wrapped subdataWithRange:NSMakeRange(MPGO_KR_DEK_LEN + MPGO_KR_IV_LEN,
                                                             MPGO_KR_TAG_LEN)];
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
// Deletes any existing dataset first so rotation works in place.
- (BOOL)writeWrappedBlob:(NSData *)blob
                  group:(MPGOHDF5Group *)keyInfo
                  error:(NSError **)error
{
    if ([keyInfo hasChildNamed:@"dek_wrapped"]) {
        if (![keyInfo deleteChildNamed:@"dek_wrapped" error:error]) return NO;
    }
    // 60 bytes = 15 int32 lanes. Precision choice is irrelevant; we
    // treat the dataset as an opaque byte blob on the read side.
    MPGOHDF5Dataset *ds =
        [keyInfo createDatasetNamed:@"dek_wrapped"
                           precision:MPGOPrecisionInt32
                              length:MPGO_KR_WRAPPED_LEN / sizeof(int32_t)
                           chunkSize:0
                    compressionLevel:0
                               error:error];
    if (!ds) return NO;
    return [ds writeData:blob error:error];
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
    NSData *wrapped = [self readWrappedBlob:ki error:error];
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
