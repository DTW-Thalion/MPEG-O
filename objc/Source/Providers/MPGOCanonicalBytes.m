/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "MPGOCanonicalBytes.h"

static BOOL hostIsLittleEndian(void)
{
    uint32_t probe = 1;
    return *(uint8_t *)&probe == 1;
}

static NSUInteger elementSizeForPrecision(MPGOPrecision p)
{
    switch (p) {
        case MPGOPrecisionFloat32:    return 4;
        case MPGOPrecisionFloat64:    return 8;
        case MPGOPrecisionInt32:      return 4;
        case MPGOPrecisionInt64:      return 8;
        case MPGOPrecisionUInt32:     return 4;
        case MPGOPrecisionComplex128: return 16;
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

@implementation MPGOCanonicalBytes

+ (NSData *)canonicalBytesForNumericData:(NSData *)data
                                precision:(MPGOPrecision)precision
{
    NSUInteger elementSize = elementSizeForPrecision(precision);
    if (elementSize == 0 || data.length == 0) return [data copy];
    if (hostIsLittleEndian()) return [data copy];

    // Big-endian host: swap every element. Complex128 is two float64s
    // (real, imag) so we swap each half independently.
    NSUInteger n = data.length / elementSize;
    NSUInteger swapWidth = (precision == MPGOPrecisionComplex128) ? 8 : elementSize;
    NSUInteger nSwaps = n * (elementSize / swapWidth);

    NSMutableData *out = [data mutableCopy];
    byteswapInPlace(out.mutableBytes, nSwaps, swapWidth);
    return out;
}

+ (NSData *)canonicalBytesForCompoundRows:(NSArray<NSDictionary<NSString *, id> *> *)rows
                                    fields:(NSArray<MPGOCompoundField *> *)fields
{
    NSMutableData *out = [NSMutableData data];
    for (NSDictionary<NSString *, id> *row in rows) {
        for (MPGOCompoundField *f in fields) {
            id value = row[f.name];
            switch (f.kind) {
                case MPGOCompoundFieldKindVLString: {
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
                case MPGOCompoundFieldKindFloat64: {
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
                case MPGOCompoundFieldKindUInt32: {
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
                case MPGOCompoundFieldKindInt64: {
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
