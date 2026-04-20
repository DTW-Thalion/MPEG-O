/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "MPGOPerAUEncryption.h"

#include <openssl/evp.h>
#include <openssl/rand.h>
#include <string.h>

static NSString *const kDomain = @"MPGOPerAUEncryptionErrorDomain";
static const NSInteger kErrCrypto = 10;

static NSError *makeErr(NSInteger code, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static NSError *makeErr(NSInteger code, NSString *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    return [NSError errorWithDomain:kDomain code:code
                            userInfo:@{NSLocalizedDescriptionKey: msg}];
}


// ---------------------------------------------------------------- segments

@implementation MPGOChannelSegment
- (instancetype)initWithOffset:(uint64_t)offset
                          length:(uint32_t)length
                              iv:(NSData *)iv
                             tag:(NSData *)tag
                      ciphertext:(NSData *)ciphertext
{
    if ((self = [super init])) {
        _offset = offset;
        _length = length;
        _iv = [iv copy];
        _tag = [tag copy];
        _ciphertext = [ciphertext copy];
    }
    return self;
}
@end


@implementation MPGOHeaderSegment
- (instancetype)initWithIV:(NSData *)iv tag:(NSData *)tag ciphertext:(NSData *)ciphertext
{
    if ((self = [super init])) {
        _iv = [iv copy];
        _tag = [tag copy];
        _ciphertext = [ciphertext copy];
    }
    return self;
}
@end


@implementation MPGOAUHeaderPlaintext
@end


// ---------------------------------------------------------------- helpers

static void appendU16LE(NSMutableData *d, uint16_t v)
{
    uint8_t b[2] = {(uint8_t)(v & 0xFFu), (uint8_t)((v >> 8) & 0xFFu)};
    [d appendBytes:b length:2];
}
static void appendU32LE(NSMutableData *d, uint32_t v)
{
    uint8_t b[4];
    b[0] = (uint8_t)(v & 0xFFu);
    b[1] = (uint8_t)((v >> 8) & 0xFFu);
    b[2] = (uint8_t)((v >> 16) & 0xFFu);
    b[3] = (uint8_t)((v >> 24) & 0xFFu);
    [d appendBytes:b length:4];
}


// ---------------------------------------------------------------- impl

@implementation MPGOPerAUEncryption

+ (NSData *)aadForChannel:(NSString *)channelName
                  datasetId:(uint16_t)datasetId
                 auSequence:(uint32_t)auSequence
{
    NSMutableData *d = [NSMutableData dataWithCapacity:6 + channelName.length];
    appendU16LE(d, datasetId);
    appendU32LE(d, auSequence);
    [d appendData:[channelName dataUsingEncoding:NSUTF8StringEncoding]];
    return d;
}

+ (NSData *)aadForHeaderWithDatasetId:(uint16_t)datasetId
                             auSequence:(uint32_t)auSequence
{
    NSMutableData *d = [NSMutableData dataWithCapacity:12];
    appendU16LE(d, datasetId);
    appendU32LE(d, auSequence);
    [d appendBytes:"header" length:6];
    return d;
}

+ (NSData *)aadForPixelWithDatasetId:(uint16_t)datasetId
                            auSequence:(uint32_t)auSequence
{
    NSMutableData *d = [NSMutableData dataWithCapacity:11];
    appendU16LE(d, datasetId);
    appendU32LE(d, auSequence);
    [d appendBytes:"pixel" length:5];
    return d;
}


#pragma mark - AES-GCM

+ (NSData *)randomIVWithError:(NSError **)error
{
    uint8_t iv[12];
    if (RAND_bytes(iv, 12) != 1) {
        if (error) *error = makeErr(kErrCrypto, @"RAND_bytes failed");
        return nil;
    }
    return [NSData dataWithBytes:iv length:12];
}

+ (NSData *)encryptWithPlaintext:(NSData *)plaintext
                               key:(NSData *)key
                                iv:(NSData *)iv
                               aad:(NSData *)aad
                            outTag:(NSData **)outTag
                             error:(NSError **)error
{
    if (key.length != 32) {
        if (error) *error = makeErr(kErrCrypto,
            @"AES-256-GCM key must be 32 bytes, got %lu", (unsigned long)key.length);
        return nil;
    }
    if (iv.length != 12) {
        if (error) *error = makeErr(kErrCrypto,
            @"IV must be 12 bytes, got %lu", (unsigned long)iv.length);
        return nil;
    }

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) { if (error) *error = makeErr(kErrCrypto, @"EVP_CIPHER_CTX_new failed"); return nil; }

    if (EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL) != 1 ||
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, 12, NULL) != 1 ||
        EVP_EncryptInit_ex(ctx, NULL, NULL, key.bytes, iv.bytes) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        if (error) *error = makeErr(kErrCrypto, @"EVP_EncryptInit_ex failed");
        return nil;
    }

    int outLen = 0;
    if (aad.length > 0) {
        if (EVP_EncryptUpdate(ctx, NULL, &outLen, aad.bytes, (int)aad.length) != 1) {
            EVP_CIPHER_CTX_free(ctx);
            if (error) *error = makeErr(kErrCrypto, @"EVP_EncryptUpdate(aad) failed");
            return nil;
        }
    }

    NSMutableData *out = [NSMutableData dataWithLength:plaintext.length + 16];
    int totalLen = 0;
    if (EVP_EncryptUpdate(ctx, out.mutableBytes, &outLen,
                            plaintext.bytes, (int)plaintext.length) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        if (error) *error = makeErr(kErrCrypto, @"EVP_EncryptUpdate failed");
        return nil;
    }
    totalLen = outLen;
    if (EVP_EncryptFinal_ex(ctx, (uint8_t *)out.mutableBytes + totalLen, &outLen) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        if (error) *error = makeErr(kErrCrypto, @"EVP_EncryptFinal_ex failed");
        return nil;
    }
    totalLen += outLen;
    out.length = (NSUInteger)totalLen;

    uint8_t tag[16];
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, 16, tag) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        if (error) *error = makeErr(kErrCrypto, @"EVP_CTRL_GCM_GET_TAG failed");
        return nil;
    }
    EVP_CIPHER_CTX_free(ctx);

    if (outTag) *outTag = [NSData dataWithBytes:tag length:16];
    return out;
}

+ (NSData *)decryptWithCiphertext:(NSData *)ciphertext
                                key:(NSData *)key
                                 iv:(NSData *)iv
                                tag:(NSData *)tag
                                aad:(NSData *)aad
                              error:(NSError **)error
{
    if (key.length != 32 || iv.length != 12 || tag.length != 16) {
        if (error) *error = makeErr(kErrCrypto,
            @"bad key/iv/tag lengths: key=%lu iv=%lu tag=%lu",
            (unsigned long)key.length, (unsigned long)iv.length,
            (unsigned long)tag.length);
        return nil;
    }

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) { if (error) *error = makeErr(kErrCrypto, @"EVP_CIPHER_CTX_new failed"); return nil; }

    if (EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL) != 1 ||
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, 12, NULL) != 1 ||
        EVP_DecryptInit_ex(ctx, NULL, NULL, key.bytes, iv.bytes) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        if (error) *error = makeErr(kErrCrypto, @"EVP_DecryptInit_ex failed");
        return nil;
    }

    int outLen = 0;
    if (aad.length > 0) {
        if (EVP_DecryptUpdate(ctx, NULL, &outLen, aad.bytes, (int)aad.length) != 1) {
            EVP_CIPHER_CTX_free(ctx);
            if (error) *error = makeErr(kErrCrypto, @"EVP_DecryptUpdate(aad) failed");
            return nil;
        }
    }

    NSMutableData *out = [NSMutableData dataWithLength:ciphertext.length];
    int totalLen = 0;
    if (EVP_DecryptUpdate(ctx, out.mutableBytes, &outLen,
                            ciphertext.bytes, (int)ciphertext.length) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        if (error) *error = makeErr(kErrCrypto, @"EVP_DecryptUpdate failed");
        return nil;
    }
    totalLen = outLen;

    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, 16, (void *)tag.bytes) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        if (error) *error = makeErr(kErrCrypto, @"EVP_CTRL_GCM_SET_TAG failed");
        return nil;
    }
    if (EVP_DecryptFinal_ex(ctx, (uint8_t *)out.mutableBytes + totalLen, &outLen) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        if (error) *error = makeErr(kErrCrypto, @"AES-GCM authentication failed");
        return nil;
    }
    totalLen += outLen;
    out.length = (NSUInteger)totalLen;
    EVP_CIPHER_CTX_free(ctx);
    return out;
}


#pragma mark - Channel segments

+ (NSArray<MPGOChannelSegment *> *)
    encryptChannelToSegments:(NSData *)plaintextFloat64
                      offsets:(const uint64_t *)offsets
                      lengths:(const uint32_t *)lengths
                     nSpectra:(NSUInteger)nSpectra
                    datasetId:(uint16_t)datasetId
                  channelName:(NSString *)channelName
                          key:(NSData *)key
                        error:(NSError **)error
{
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:nSpectra];
    const uint8_t *all = (const uint8_t *)plaintextFloat64.bytes;
    for (NSUInteger i = 0; i < nSpectra; i++) {
        NSUInteger byteOffset = (NSUInteger)offsets[i] * 8;
        NSUInteger byteLength = (NSUInteger)lengths[i] * 8;
        NSData *chunk = [NSData dataWithBytes:all + byteOffset length:byteLength];
        NSData *aad = [self aadForChannel:channelName
                                  datasetId:datasetId
                                 auSequence:(uint32_t)i];
        NSData *iv = [self randomIVWithError:error];
        if (!iv) return nil;
        NSData *tag = nil;
        NSData *ct = [self encryptWithPlaintext:chunk
                                             key:key
                                              iv:iv
                                             aad:aad
                                          outTag:&tag
                                           error:error];
        if (!ct) return nil;
        MPGOChannelSegment *seg =
            [[MPGOChannelSegment alloc] initWithOffset:offsets[i]
                                                  length:lengths[i]
                                                      iv:iv
                                                     tag:tag
                                              ciphertext:ct];
        [out addObject:seg];
    }
    return out;
}

+ (NSData *)decryptChannelFromSegments:(NSArray<MPGOChannelSegment *> *)segments
                              datasetId:(uint16_t)datasetId
                            channelName:(NSString *)channelName
                                    key:(NSData *)key
                                  error:(NSError **)error
{
    NSMutableData *out = [NSMutableData data];
    for (NSUInteger i = 0; i < segments.count; i++) {
        MPGOChannelSegment *seg = segments[i];
        NSData *aad = [self aadForChannel:channelName
                                  datasetId:datasetId
                                 auSequence:(uint32_t)i];
        NSData *plain = [self decryptWithCiphertext:seg.ciphertext
                                                  key:key
                                                   iv:seg.iv
                                                  tag:seg.tag
                                                  aad:aad
                                                error:error];
        if (!plain) return nil;
        if (plain.length != (NSUInteger)seg.length * 8) {
            if (error) *error = makeErr(kErrCrypto,
                @"channel %@ segment %lu: decrypted %lu bytes, expected %u",
                channelName, (unsigned long)i,
                (unsigned long)plain.length, (unsigned)seg.length * 8);
            return nil;
        }
        [out appendData:plain];
    }
    return out;
}


#pragma mark - Header segments

+ (NSData *)packAUHeaderPlaintext:(MPGOAUHeaderPlaintext *)h
{
    NSMutableData *d = [NSMutableData dataWithCapacity:36];
    uint8_t prefix[3] = {h.acquisitionMode, h.msLevel, (uint8_t)(h.polarity & 0xFF)};
    [d appendBytes:prefix length:3];
    double rt = h.retentionTime; [d appendBytes:&rt length:8];
    double pmz = h.precursorMz; [d appendBytes:&pmz length:8];
    uint8_t pc = h.precursorCharge; [d appendBytes:&pc length:1];
    double im = h.ionMobility; [d appendBytes:&im length:8];
    double bpi = h.basePeakIntensity; [d appendBytes:&bpi length:8];
    return d;
}

+ (MPGOAUHeaderPlaintext *)unpackAUHeaderPlaintext:(NSData *)bytes
{
    if (bytes.length != 36) return nil;
    const uint8_t *p = (const uint8_t *)bytes.bytes;
    MPGOAUHeaderPlaintext *h = [[MPGOAUHeaderPlaintext alloc] init];
    h.acquisitionMode = p[0];
    h.msLevel = p[1];
    // polarity is int32 semantically, packed here as u8 (-1 stored as 0xFF).
    int8_t polSigned = (int8_t)p[2];
    h.polarity = (int32_t)polSigned;
    double rt, pmz, im, bpi;
    memcpy(&rt,  p + 3, 8);
    memcpy(&pmz, p + 11, 8);
    h.precursorCharge = p[19];
    memcpy(&im,  p + 20, 8);
    memcpy(&bpi, p + 28, 8);
    h.retentionTime = rt;
    h.precursorMz = pmz;
    h.ionMobility = im;
    h.basePeakIntensity = bpi;
    return h;
}

+ (NSArray<MPGOHeaderSegment *> *)
    encryptHeaderSegments:(NSArray<MPGOAUHeaderPlaintext *> *)rows
                 datasetId:(uint16_t)datasetId
                       key:(NSData *)key
                     error:(NSError **)error
{
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:rows.count];
    for (NSUInteger i = 0; i < rows.count; i++) {
        NSData *plain = [self packAUHeaderPlaintext:rows[i]];
        NSData *aad = [self aadForHeaderWithDatasetId:datasetId
                                             auSequence:(uint32_t)i];
        NSData *iv = [self randomIVWithError:error];
        if (!iv) return nil;
        NSData *tag = nil;
        NSData *ct = [self encryptWithPlaintext:plain
                                             key:key
                                              iv:iv
                                             aad:aad
                                          outTag:&tag
                                           error:error];
        if (!ct) return nil;
        MPGOHeaderSegment *seg =
            [[MPGOHeaderSegment alloc] initWithIV:iv tag:tag ciphertext:ct];
        [out addObject:seg];
    }
    return out;
}

+ (NSArray<MPGOAUHeaderPlaintext *> *)
    decryptHeaderSegments:(NSArray<MPGOHeaderSegment *> *)segments
                 datasetId:(uint16_t)datasetId
                       key:(NSData *)key
                     error:(NSError **)error
{
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:segments.count];
    for (NSUInteger i = 0; i < segments.count; i++) {
        MPGOHeaderSegment *seg = segments[i];
        NSData *aad = [self aadForHeaderWithDatasetId:datasetId
                                             auSequence:(uint32_t)i];
        NSData *plain = [self decryptWithCiphertext:seg.ciphertext
                                                  key:key
                                                   iv:seg.iv
                                                  tag:seg.tag
                                                  aad:aad
                                                error:error];
        if (!plain) return nil;
        MPGOAUHeaderPlaintext *h = [self unpackAUHeaderPlaintext:plain];
        if (!h) {
            if (error) *error = makeErr(kErrCrypto, @"header plaintext not 36 bytes");
            return nil;
        }
        [out addObject:h];
    }
    return out;
}

@end
