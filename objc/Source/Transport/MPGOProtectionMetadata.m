/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "MPGOProtectionMetadata.h"
#import <string.h>

static inline void appendU16LE(NSMutableData *b, uint16_t v)
{
    uint8_t out[2] = {(uint8_t)(v & 0xFFu), (uint8_t)((v >> 8) & 0xFFu)};
    [b appendBytes:out length:2];
}
static inline void appendU32LE(NSMutableData *b, uint32_t v)
{
    uint8_t out[4];
    out[0] = (uint8_t)(v & 0xFFu);
    out[1] = (uint8_t)((v >> 8) & 0xFFu);
    out[2] = (uint8_t)((v >> 16) & 0xFFu);
    out[3] = (uint8_t)((v >> 24) & 0xFFu);
    [b appendBytes:out length:4];
}
static inline uint16_t readU16(const uint8_t *b)
{
    return (uint16_t)((uint32_t)b[0] | ((uint32_t)b[1] << 8));
}
static inline uint32_t readU32(const uint8_t *b)
{
    return (uint32_t)b[0]
         | ((uint32_t)b[1] << 8)
         | ((uint32_t)b[2] << 16)
         | ((uint32_t)b[3] << 24);
}
static void appendLEString(NSMutableData *buf, NSString *s, int width)
{
    NSData *d = [(s ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    if (width == 2) appendU16LE(buf, (uint16_t)d.length);
    else            appendU32LE(buf, (uint32_t)d.length);
    [buf appendData:d];
}
static NSString *readLEString(const uint8_t *bytes, NSUInteger length,
                                NSUInteger *offset, int width)
{
    NSUInteger off = *offset;
    uint32_t len;
    if (width == 2) {
        if (off + 2 > length) return nil;
        len = readU16(&bytes[off]); off += 2;
    } else {
        if (off + 4 > length) return nil;
        len = readU32(&bytes[off]); off += 4;
    }
    if (off + len > length) return nil;
    NSString *s = [[NSString alloc] initWithBytes:&bytes[off] length:len
                                           encoding:NSUTF8StringEncoding];
    *offset = off + len;
    return s ?: @"";
}


@implementation MPGOProtectionMetadata

- (instancetype)initWithCipherSuite:(NSString *)cipherSuite
                         kekAlgorithm:(NSString *)kekAlgorithm
                          wrappedDek:(NSData *)wrappedDek
                   signatureAlgorithm:(NSString *)signatureAlgorithm
                            publicKey:(NSData *)publicKey
{
    if ((self = [super init])) {
        _cipherSuite = [cipherSuite copy];
        _kekAlgorithm = [kekAlgorithm copy];
        _wrappedDek = [wrappedDek copy];
        _signatureAlgorithm = [signatureAlgorithm copy];
        _publicKey = [publicKey copy];
    }
    return self;
}

- (NSData *)encode
{
    NSMutableData *buf = [NSMutableData data];
    appendLEString(buf, _cipherSuite, 2);
    appendLEString(buf, _kekAlgorithm, 2);
    appendU32LE(buf, (uint32_t)_wrappedDek.length);
    [buf appendData:_wrappedDek];
    appendLEString(buf, _signatureAlgorithm, 2);
    appendU32LE(buf, (uint32_t)_publicKey.length);
    [buf appendData:_publicKey];
    return buf;
}

+ (instancetype)decodeFromData:(NSData *)data
{
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger length = data.length;
    NSUInteger offset = 0;
    NSString *cs = readLEString(bytes, length, &offset, 2);
    NSString *kek = readLEString(bytes, length, &offset, 2);
    if (offset + 4 > length) return nil;
    uint32_t wrappedLen = readU32(&bytes[offset]); offset += 4;
    if (offset + wrappedLen > length) return nil;
    NSData *wrapped = [NSData dataWithBytes:&bytes[offset] length:wrappedLen];
    offset += wrappedLen;
    NSString *sig = readLEString(bytes, length, &offset, 2);
    if (offset + 4 > length) return nil;
    uint32_t pkLen = readU32(&bytes[offset]); offset += 4;
    if (offset + pkLen > length) return nil;
    NSData *pk = [NSData dataWithBytes:&bytes[offset] length:pkLen];
    return [[self alloc] initWithCipherSuite:(cs ?: @"")
                                  kekAlgorithm:(kek ?: @"")
                                   wrappedDek:wrapped
                            signatureAlgorithm:(sig ?: @"")
                                     publicKey:pk];
}

@end
