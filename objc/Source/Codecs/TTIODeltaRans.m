/*
 * TTIODeltaRans.m — DELTA_RANS_ORDER0 codec (M95, codec id 11).
 *
 * Delta + zigzag + unsigned LEB128 varint + rANS order-0.
 *
 * Wire format: 8-byte header (magic "DRA0", version 1, element_size,
 * 2 reserved zero bytes) followed by rANS order-0 encoded body.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import "Codecs/TTIODeltaRans.h"
#import "Codecs/TTIORans.h"
#include <stdint.h>
#include <string.h>

static const uint8_t kMagic[4] = {'D', 'R', 'A', '0'};
static const uint8_t kVersion = 1;
static const NSUInteger kHeaderLen = 8;

// ---------------------------------------------------------------------------
// LE integer helpers
// ---------------------------------------------------------------------------

static int64_t read_le_i64(const uint8_t *p)
{
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
    return (int64_t)v;
}

static int32_t read_le_i32(const uint8_t *p)
{
    uint32_t v = 0;
    for (int i = 3; i >= 0; i--) v = (v << 8) | p[i];
    return (int32_t)v;
}

static int8_t read_le_i8(const uint8_t *p)
{
    return (int8_t)p[0];
}

static void write_le_i64(uint8_t *p, int64_t v)
{
    uint64_t u = (uint64_t)v;
    for (int i = 0; i < 8; i++) { p[i] = u & 0xFF; u >>= 8; }
}

static void write_le_i32(uint8_t *p, int32_t v)
{
    uint32_t u = (uint32_t)v;
    for (int i = 0; i < 4; i++) { p[i] = u & 0xFF; u >>= 8; }
}

static void write_le_i8(uint8_t *p, int8_t v)
{
    p[0] = (uint8_t)v;
}

// ---------------------------------------------------------------------------
// Zigzag
// ---------------------------------------------------------------------------

static uint64_t zigzag_encode_64(int64_t v)
{
    return (uint64_t)((v << 1) ^ (v >> 63));
}

static int64_t zigzag_decode_64(uint64_t zz)
{
    return (int64_t)((zz >> 1) ^ -(int64_t)(zz & 1));
}

// ---------------------------------------------------------------------------
// Varint (unsigned LEB128)
// ---------------------------------------------------------------------------

/* Upper bound on varint bytes for a 64-bit value: 10 bytes. */
static NSUInteger varint_encode(uint64_t value, uint8_t *buf)
{
    NSUInteger n = 0;
    while (value > 0x7F) {
        buf[n++] = (uint8_t)((value & 0x7F) | 0x80);
        value >>= 7;
    }
    buf[n++] = (uint8_t)(value & 0x7F);
    return n;
}

// ---------------------------------------------------------------------------
// Error helper
// ---------------------------------------------------------------------------

static NSError *deltaRansError(NSInteger code, NSString *desc)
{
    return [NSError errorWithDomain:@"TTIODeltaRansError"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: desc}];
}

// ---------------------------------------------------------------------------
// Encode
// ---------------------------------------------------------------------------

NSData *TTIODeltaRansEncode(NSData *data, uint8_t elementSize,
                            NSError * _Nullable * _Nullable error)
{
    if (elementSize != 1 && elementSize != 4 && elementSize != 8) {
        if (error) *error = deltaRansError(1,
            [NSString stringWithFormat:@"DELTA_RANS: element_size must be 1, 4, or 8, got %u",
             (unsigned)elementSize]);
        return nil;
    }

    NSUInteger dataLen = data.length;
    if (dataLen % elementSize != 0) {
        if (error) *error = deltaRansError(2,
            [NSString stringWithFormat:@"DELTA_RANS: data length %lu not a multiple of element_size %u",
             (unsigned long)dataLen, (unsigned)elementSize]);
        return nil;
    }

    NSUInteger nElements = dataLen / elementSize;
    const uint8_t *raw = (const uint8_t *)data.bytes;

    /* Build header. */
    uint8_t header[8];
    memcpy(header, kMagic, 4);
    header[4] = kVersion;
    header[5] = elementSize;
    header[6] = 0;
    header[7] = 0;

    if (nElements == 0) {
        /* Encode empty varint stream through rANS. */
        NSData *emptyBody = TTIORansEncode([NSData data], 0);
        NSMutableData *result = [NSMutableData dataWithCapacity:kHeaderLen + emptyBody.length];
        [result appendBytes:header length:kHeaderLen];
        [result appendData:emptyBody];
        return result;
    }

    /* Parse LE integers, compute deltas, zigzag, varint. */
    /* Max varint bytes: 10 per element for 64-bit zigzag values. */
    NSMutableData *varintBuf = [NSMutableData dataWithCapacity:nElements * 10];
    uint8_t vbuf[10];

    int64_t prev = 0;
    int bits = elementSize * 8;

    for (NSUInteger i = 0; i < nElements; i++) {
        int64_t value;
        switch (elementSize) {
            case 1:  value = read_le_i8(raw + i);     break;
            case 4:  value = read_le_i32(raw + i * 4); break;
            default: value = read_le_i64(raw + i * 8); break;
        }

        int64_t delta = value - prev;

        /* For sub-64-bit element sizes, wrap the delta into the signed range. */
        if (bits < 64) {
            int64_t half = (int64_t)1 << (bits - 1);
            int64_t full = (int64_t)1 << bits;
            if (delta < -half)       delta += full;
            else if (delta >= half)  delta -= full;
        }

        /* Zigzag encode. For sub-64-bit, shift by (bits-1) to match Python. */
        uint64_t zz;
        if (bits < 64) {
            zz = (uint64_t)(((delta << 1) ^ (delta >> (bits - 1))) & (((int64_t)1 << bits) - 1));
        } else {
            zz = zigzag_encode_64(delta);
        }

        NSUInteger vlen = varint_encode(zz, vbuf);
        [varintBuf appendBytes:vbuf length:vlen];

        prev = value;
    }

    /* rANS order-0 encode the varint stream. */
    NSData *ransBody = TTIORansEncode(varintBuf, 0);

    NSMutableData *result = [NSMutableData dataWithCapacity:kHeaderLen + ransBody.length];
    [result appendBytes:header length:kHeaderLen];
    [result appendData:ransBody];
    return result;
}

// ---------------------------------------------------------------------------
// Decode
// ---------------------------------------------------------------------------

NSData * _Nullable TTIODeltaRansDecode(NSData *encoded,
                                       NSError * _Nullable * _Nullable error)
{
    if (encoded.length < kHeaderLen) {
        if (error) *error = deltaRansError(10,
            @"DELTA_RANS: encoded data too short for header");
        return nil;
    }

    const uint8_t *hdr = (const uint8_t *)encoded.bytes;
    if (memcmp(hdr, kMagic, 4) != 0) {
        if (error) *error = deltaRansError(11,
            @"DELTA_RANS: bad magic (expected DRA0)");
        return nil;
    }
    if (hdr[4] != kVersion) {
        if (error) *error = deltaRansError(12,
            [NSString stringWithFormat:@"DELTA_RANS: unsupported version %u (expected %u)",
             (unsigned)hdr[4], (unsigned)kVersion]);
        return nil;
    }
    uint8_t elementSize = hdr[5];
    if (elementSize != 1 && elementSize != 4 && elementSize != 8) {
        if (error) *error = deltaRansError(13,
            [NSString stringWithFormat:@"DELTA_RANS: invalid element_size %u",
             (unsigned)elementSize]);
        return nil;
    }

    /* Extract body (everything after header) and rANS decode. */
    NSData *body = [encoded subdataWithRange:NSMakeRange(kHeaderLen,
                                              encoded.length - kHeaderLen)];
    NSError *ransErr = nil;
    NSData *varintData = TTIORansDecode(body, &ransErr);
    if (!varintData) {
        if (error) *error = deltaRansError(14,
            [NSString stringWithFormat:@"DELTA_RANS: rANS decode failed: %@",
             ransErr.localizedDescription]);
        return nil;
    }

    if (varintData.length == 0) {
        return [NSData data];
    }

    /* Decode varints. */
    const uint8_t *vdata = (const uint8_t *)varintData.bytes;
    NSUInteger vlen = varintData.length;
    NSMutableArray *zigzagValues = [NSMutableArray array];
    NSUInteger pos = 0;

    while (pos < vlen) {
        uint64_t value = 0;
        unsigned shift = 0;
        while (YES) {
            if (pos >= vlen) {
                if (error) *error = deltaRansError(15,
                    @"DELTA_RANS: truncated varint");
                return nil;
            }
            uint8_t b = vdata[pos++];
            value |= (uint64_t)(b & 0x7F) << shift;
            if ((b & 0x80) == 0) break;
            shift += 7;
        }
        [zigzagValues addObject:@(value)];
    }

    NSUInteger nElements = zigzagValues.count;
    int bits = elementSize * 8;
    int64_t half = (bits < 64) ? ((int64_t)1 << (bits - 1)) : 0;
    uint64_t mask = (bits < 64) ? (((uint64_t)1 << bits) - 1) : UINT64_MAX;

    /* Zigzag decode + prefix-sum + serialize as LE. */
    NSMutableData *output = [NSMutableData dataWithLength:nElements * elementSize];
    uint8_t *out = (uint8_t *)output.mutableBytes;

    int64_t prev = 0;
    for (NSUInteger i = 0; i < nElements; i++) {
        uint64_t zz = [zigzagValues[i] unsignedLongLongValue];
        int64_t delta = zigzag_decode_64(zz);

        if (bits < 64) {
            if (delta >= half)       delta -= ((int64_t)1 << bits);
            else if (delta < -half)  delta += ((int64_t)1 << bits);
        }

        int64_t value = prev + delta;
        if (bits < 64) {
            value &= (int64_t)mask;
            if (value >= half) value -= ((int64_t)1 << bits);
        }

        switch (elementSize) {
            case 1:  write_le_i8(out + i, (int8_t)value);           break;
            case 4:  write_le_i32(out + i * 4, (int32_t)value);     break;
            default: write_le_i64(out + i * 8, value);              break;
        }

        prev = value;
    }

    return output;
}
