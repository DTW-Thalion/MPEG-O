/*
 * TTIOCanonicalBytes.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOCanonicalBytes
 * Inherits From: NSObject
 * Conforms To:   NSObject (NSObject)
 * Declared In:   Providers/TTIOCanonicalBytes.h
 *
 * Canonical byte-layout helpers shared by every storage provider's
 * -readCanonicalBytes: implementation. Primitives go little-endian;
 * compound rows walk in storage order, fields in declaration order
 * with VL strings as u32_le(length) || utf-8_bytes.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "TTIOCanonicalBytes.h"

static BOOL hostIsLittleEndian(void)
{
    uint32_t probe = 1;
    return *(uint8_t *)&probe == 1;
}

static NSUInteger elementSizeForPrecision(TTIOPrecision p)
{
    switch (p) {
        case TTIOPrecisionFloat32:    return 4;
        case TTIOPrecisionFloat64:    return 8;
        case TTIOPrecisionInt32:      return 4;
        case TTIOPrecisionInt64:      return 8;
        case TTIOPrecisionUInt32:     return 4;
        case TTIOPrecisionComplex128: return 16;
        case TTIOPrecisionUInt8:      return 1;
        case TTIOPrecisionUInt16:     return 2;  // L1
    }
    return 0;
}

static void byteswapInPlace(void *buf, NSUInteger count, NSUInteger width)
{
    uint8_t *p = (uint8_t *)buf;
    for (NSUInteger i = 0; i < count; i++, p += width) {
        for (NSUInteger a = 0, b = width - 1; a < b; a++, b--) {
            uint8_t t = p[a]; p[a] = p[b]; p[b] = t;
        }
    }
}

@implementation TTIOCanonicalBytes

+ (NSData *)canonicalBytesForNumericData:(NSData *)data
                                precision:(TTIOPrecision)precision
{
    NSUInteger elementSize = elementSizeForPrecision(precision);
    if (elementSize == 0 || data.length == 0) return [data copy];
    if (hostIsLittleEndian()) return [data copy];

    // Big-endian host: swap every element. Complex128 is two float64s
    // (real, imag) so we swap each half independently.
    NSUInteger n = data.length / elementSize;
    NSUInteger swapWidth = (precision == TTIOPrecisionComplex128) ? 8 : elementSize;
    NSUInteger nSwaps = n * (elementSize / swapWidth);

    NSMutableData *out = [data mutableCopy];
    byteswapInPlace(out.mutableBytes, nSwaps, swapWidth);
    return out;
}

+ (NSData *)canonicalBytesForCompoundRows:(NSArray<NSDictionary<NSString *, id> *> *)rows
                                    fields:(NSArray<TTIOCompoundField *> *)fields
{
    NSMutableData *out = [NSMutableData data];
    for (NSDictionary<NSString *, id> *row in rows) {
        for (TTIOCompoundField *f in fields) {
            id value = row[f.name];
            switch (f.kind) {
                case TTIOCompoundFieldKindVLString: {
                    NSData *payload = nil;
                    if ([value isKindOfClass:[NSString class]]) {
                        payload = [value dataUsingEncoding:NSUTF8StringEncoding];
                    } else if ([value isKindOfClass:[NSData class]]) {
                        payload = value;
                    } else {
                        payload = [NSData data];
                    }
                    uint32_t len = (uint32_t)payload.length;
                    // Always little-endian on the wire.
                    uint8_t lenLE[4] = {
                        (uint8_t)(len & 0xFF),
                        (uint8_t)((len >> 8) & 0xFF),
                        (uint8_t)((len >> 16) & 0xFF),
                        (uint8_t)((len >> 24) & 0xFF),
                    };
                    [out appendBytes:lenLE length:4];
                    if (len > 0) [out appendData:payload];
                    break;
                }
                case TTIOCompoundFieldKindFloat64: {
                    double d = [value doubleValue];
                    if (hostIsLittleEndian()) {
                        [out appendBytes:&d length:8];
                    } else {
                        uint8_t buf[8];
                        memcpy(buf, &d, 8);
                        for (int a = 0, b = 7; a < b; a++, b--) {
                            uint8_t t = buf[a]; buf[a] = buf[b]; buf[b] = t;
                        }
                        [out appendBytes:buf length:8];
                    }
                    break;
                }
                case TTIOCompoundFieldKindUInt32: {
                    uint32_t v = (uint32_t)[value unsignedIntValue];
                    uint8_t buf[4] = {
                        (uint8_t)(v & 0xFF),
                        (uint8_t)((v >> 8) & 0xFF),
                        (uint8_t)((v >> 16) & 0xFF),
                        (uint8_t)((v >> 24) & 0xFF),
                    };
                    [out appendBytes:buf length:4];
                    break;
                }
                case TTIOCompoundFieldKindInt64: {
                    int64_t v = (int64_t)[value longLongValue];
                    uint8_t buf[8];
                    for (int i = 0; i < 8; i++) {
                        buf[i] = (uint8_t)((v >> (8 * i)) & 0xFF);
                    }
                    [out appendBytes:buf length:8];
                    break;
                }
            }
        }
    }
    return out;
}

@end
