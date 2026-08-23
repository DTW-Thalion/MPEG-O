/*
 * TTIOFloatDeltaZstd.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOFloatDeltaZstd
 * Inherits From: NSObject
 * Declared In:   Codecs/TTIOFloatDeltaZstd.h
 *
 * FLOAT_DELTA_ZSTD (codec id 17). Wire format FDZ1 per the spec:
 * 22-byte header + per block { transform(u8), body_length(u32 LE),
 * one zstd frame }. Bit 0 of the transform is a prefix delta on the
 * uint64 bit view; bit 1 puts the values in the frame as plain
 * little-endian uint64 rather than 8 byte planes.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import "TTIOFloatDeltaZstd.h"
#import "HDF5/TTIOHDF5Errors.h"
#import <zstd.h>
#import <string.h>

static const uint8_t kVersion = 0x01;
static const NSUInteger kHeaderLen = 22;
static const NSUInteger kBlockSize = 1u << 20;
static const uint8_t kTransformNone = 0x00;
/* Bit 0: prefix delta on the uint64 bit view. Bit 1: the values go into
 * the zstd frame as plain little-endian uint64 instead of 8 byte
 * planes. The transpose pays on intensity arrays and costs on m/z, so
 * both are chosen per block by exact size. */
static const uint8_t kTransformDelta = 0x01;
static const uint8_t kTransformPlain = 0x02;
static const uint8_t kTransformMask  = 0x03;
static const int kZstdLevel = 9;

static void putU32LE(NSMutableData *d, uint32_t v)
{
    uint8_t b[4] = { (uint8_t)v, (uint8_t)(v >> 8),
                     (uint8_t)(v >> 16), (uint8_t)(v >> 24) };
    [d appendBytes:b length:4];
}

static void putU64LE(NSMutableData *d, uint64_t v)
{
    uint8_t b[8];
    for (int i = 0; i < 8; i++) b[i] = (uint8_t)(v >> (8 * i));
    [d appendBytes:b length:8];
}

static uint32_t getU32LE(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8)
         | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t getU64LE(const uint8_t *p)
{
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
    return v;
}

static void transpose(const uint64_t *u, NSUInteger len, uint8_t *out)
{
    for (int plane = 0; plane < 8; plane++) {
        uint8_t *dst = out + (NSUInteger)plane * len;
        int shift = plane * 8;
        for (NSUInteger i = 0; i < len; i++) {
            dst[i] = (uint8_t)(u[i] >> shift);
        }
    }
}

static void untranspose(const uint8_t *planes, NSUInteger len, uint64_t *out)
{
    memset(out, 0, len * sizeof(uint64_t));
    for (int plane = 0; plane < 8; plane++) {
        const uint8_t *src = planes + (NSUInteger)plane * len;
        int shift = plane * 8;
        for (NSUInteger i = 0; i < len; i++) {
            out[i] |= ((uint64_t)src[i]) << shift;
        }
    }
}

static void packPlainLE(const uint64_t *u, NSUInteger len, uint8_t *out)
{
    for (NSUInteger i = 0; i < len; i++) {
        uint64_t v = u[i];
        uint8_t *dst = out + i * 8;
        for (int b = 0; b < 8; b++) dst[b] = (uint8_t)(v >> (8 * b));
    }
}

static void unpackPlainLE(const uint8_t *p, NSUInteger len, uint64_t *out)
{
    for (NSUInteger i = 0; i < len; i++) out[i] = getU64LE(p + i * 8);
}

/* zstd-compress buf; returns nil on failure. */
static NSData *zstdFrame(const uint8_t *buf, NSUInteger len)
{
    size_t bound = ZSTD_compressBound(len);
    NSMutableData *out = [NSMutableData dataWithLength:bound];
    size_t n = ZSTD_compress(out.mutableBytes, bound, buf, len, kZstdLevel);
    if (ZSTD_isError(n)) return nil;
    [out setLength:n];
    return out;
}

@implementation TTIOFDZEncodedBlock
- (instancetype)initWithTransform:(uint8_t)transform body:(NSData *)body
{
    self = [super init];
    if (self) { _transform = transform; _body = [body copy]; }
    return self;
}
@end

@implementation TTIOFDZBlockTable {
    NSMutableData *_offsets;
    NSMutableData *_transforms;
    NSMutableData *_lengths;
}
- (instancetype)initWithValues:(uint64_t)n blockSize:(uint32_t)bs blocks:(uint32_t)nb
{
    self = [super init];
    if (self) {
        _nValues = n; _blockSize = bs; _nBlocks = nb;
        _offsets = [NSMutableData dataWithLength:nb * sizeof(uint64_t)];
        _transforms = [NSMutableData dataWithLength:nb];
        _lengths = [NSMutableData dataWithLength:nb * sizeof(uint32_t)];
    }
    return self;
}
- (void)setBlock:(NSUInteger)k offset:(uint64_t)off transform:(uint8_t)t length:(uint32_t)len
{
    ((uint64_t *)_offsets.mutableBytes)[k] = off;
    ((uint8_t *)_transforms.mutableBytes)[k] = t;
    ((uint32_t *)_lengths.mutableBytes)[k] = len;
}
- (uint64_t)offsetAt:(NSUInteger)k { return ((const uint64_t *)_offsets.bytes)[k]; }
- (uint8_t)transformAt:(NSUInteger)k { return ((const uint8_t *)_transforms.bytes)[k]; }
- (uint32_t)lengthAt:(NSUInteger)k { return ((const uint32_t *)_lengths.bytes)[k]; }
- (NSUInteger)blockValues:(NSUInteger)k
{
    uint64_t start = (uint64_t)k * _blockSize;
    return (NSUInteger)MIN((uint64_t)_blockSize, _nValues - start);
}
@end

@implementation TTIOFloatDeltaZstd

+ (NSUInteger)blockSize { return kBlockSize; }

+ (NSData *)headerBytesForValues:(uint64_t)nValues blocks:(uint32_t)nBlocks
{
    NSMutableData *out = [NSMutableData dataWithCapacity:kHeaderLen];
    [out appendBytes:"FDZ1" length:4];
    uint8_t vf[2] = { kVersion, 0 };
    [out appendBytes:vf length:2];
    putU64LE(out, nValues);
    putU32LE(out, (uint32_t)kBlockSize);
    putU32LE(out, nBlocks);
    return out;
}

+ (TTIOFDZEncodedBlock *)encodeBlock:(NSData *)values
{
    if (values.length % 8 != 0 || values.length / 8 > kBlockSize) return nil;
    NSUInteger len = values.length / 8;
    const uint64_t *u = (const uint64_t *)values.bytes;
    NSUInteger scratchLen = len > 0 ? len : 1;
    uint64_t *delta = malloc(scratchLen * sizeof(uint64_t));
    uint8_t *scratch = malloc(scratchLen * 8);
    if (!delta || !scratch) { free(delta); free(scratch); return nil; }

    if (len > 0) delta[0] = u[0];
    for (NSUInteger i = 1; i < len; i++) delta[i] = u[i] - u[i - 1];

    /* The four candidates, in transform-code order. The plain body of
     * the undelta'd values is the input bytes themselves. */
    transpose(u, len, scratch);
    NSData *bodies[4];
    bodies[kTransformNone] = zstdFrame(scratch, len * 8);
    transpose(delta, len, scratch);
    bodies[kTransformDelta] = zstdFrame(scratch, len * 8);
    bodies[kTransformPlain] = zstdFrame(values.bytes, len * 8);
    packPlainLE(delta, len, scratch);
    bodies[kTransformPlain | kTransformDelta] = zstdFrame(scratch, len * 8);
    free(delta);
    free(scratch);

    uint8_t best = kTransformNone;
    for (uint8_t t = 0; t <= kTransformMask; t++) {
        if (!bodies[t]) return nil;
        if (bodies[t].length < bodies[best].length) best = t;
    }
    return [[TTIOFDZEncodedBlock alloc] initWithTransform:best body:bodies[best]];
}

+ (NSData *)blockBytes:(TTIOFDZEncodedBlock *)block
{
    NSMutableData *out = [NSMutableData dataWithCapacity:5 + block.body.length];
    uint8_t t = block.transform;
    [out appendBytes:&t length:1];
    putU32LE(out, (uint32_t)block.body.length);
    [out appendData:block.body];
    return out;
}

+ (NSData *)encodeFloat64:(NSData *)values
{
    if (values.length % 8 != 0) return nil;
    NSUInteger n = values.length / 8;
    NSUInteger nBlocks = (n + kBlockSize - 1) / kBlockSize;
    NSMutableData *out = [NSMutableData data];
    [out appendData:[self headerBytesForValues:n blocks:(uint32_t)nBlocks]];
    for (NSUInteger bi = 0; bi < nBlocks; bi++) {
        NSUInteger off = bi * kBlockSize;
        NSUInteger len = MIN(kBlockSize, n - off);
        NSData *slice = [values subdataWithRange:NSMakeRange(off * 8, len * 8)];
        TTIOFDZEncodedBlock *b = [self encodeBlock:slice];
        if (!b) return nil;
        [out appendData:[self blockBytes:b]];
    }
    return out;
}

+ (TTIOFDZBlockTable *)readBlockTableWithReader:(TTIOFDZByteRangeReader)reader
                                          error:(NSError **)error
{
    NSData *hdr = reader(0, kHeaderLen);
    const uint8_t *p = hdr.bytes;
    if (hdr.length < kHeaderLen || memcmp(p, "FDZ1", 4) != 0) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument, @"not an FDZ1 stream");
        return nil;
    }
    if (p[4] != kVersion) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"unknown FDZ1 version 0x%02x", p[4]);
        return nil;
    }
    uint64_t n64 = getU64LE(p + 6);
    uint32_t blockSize = getU32LE(p + 14);
    uint32_t nBlocks = getU32LE(p + 18);
    if (blockSize == 0 || nBlocks != (n64 + blockSize - 1) / blockSize) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument, @"malformed FDZ1 header");
        return nil;
    }
    TTIOFDZBlockTable *t = [[TTIOFDZBlockTable alloc] initWithValues:n64 blockSize:blockSize blocks:nBlocks];
    uint64_t pos = kHeaderLen;
    for (uint32_t k = 0; k < nBlocks; k++) {
        NSData *bh = reader((NSUInteger)pos, 5);
        if (bh.length < 5) {
            if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
                @"FDZ1 stream truncated at block header");
            return nil;
        }
        const uint8_t *b = bh.bytes;
        uint32_t len = getU32LE(b + 1);
        [t setBlock:k offset:pos + 5 transform:b[0] length:len];
        pos += 5 + len;
    }
    return t;
}

+ (NSData *)decodeBlock:(NSUInteger)k
                  table:(TTIOFDZBlockTable *)t
                 reader:(TTIOFDZByteRangeReader)reader
                  error:(NSError **)error
{
    if (k >= t.nBlocks) {
        if (error) *error = TTIOMakeError(TTIOErrorOutOfRange, @"FDZ1 block %lu out of range", (unsigned long)k);
        return nil;
    }
    NSUInteger len = [t blockValues:k];
    NSData *body = reader((NSUInteger)[t offsetAt:k], [t lengthAt:k]);
    if (body.length != [t lengthAt:k]) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument, @"FDZ1 stream truncated in block body");
        return nil;
    }
    uint8_t transform = [t transformAt:k];
    if (transform & ~kTransformMask) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"unknown FDZ1 transform 0x%02x", transform);
        return nil;
    }
    NSMutableData *outData = [NSMutableData dataWithLength:len * sizeof(uint64_t)];
    uint64_t *out = outData.mutableBytes;
    uint8_t *raw = malloc(len > 0 ? len * 8 : 1);
    if (!raw) return nil;
    size_t inflated = ZSTD_decompress(raw, len * 8, body.bytes, body.length);
    if (ZSTD_isError(inflated) || inflated != len * 8) {
        free(raw);
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument, @"FDZ1 block inflated to the wrong size");
        return nil;
    }
    if (transform & kTransformPlain) {
        unpackPlainLE(raw, len, out);
    } else {
        untranspose(raw, len, out);
    }
    free(raw);
    if (transform & kTransformDelta) {
        for (NSUInteger i = 1; i < len; i++) out[i] += out[i - 1];
    }
    return outData;
}

+ (NSData *)decodeStream:(NSData *)stream error:(NSError **)error
{
    const uint8_t *p = stream.bytes;
    if (stream.length < kHeaderLen || memcmp(p, "FDZ1", 4) != 0) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"not an FDZ1 stream");
        return nil;
    }
    if (p[4] != kVersion) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"unknown FDZ1 version 0x%02x", p[4]);
        return nil;
    }
    uint64_t n64 = getU64LE(p + 6);
    uint32_t blockSize = getU32LE(p + 14);
    uint32_t nBlocks = getU32LE(p + 18);
    if (blockSize == 0 || n64 > (uint64_t)NSUIntegerMax
        || nBlocks != (n64 + blockSize - 1) / blockSize) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"malformed FDZ1 header");
        return nil;
    }
    NSUInteger n = (NSUInteger)n64;
    NSMutableData *outData = [NSMutableData dataWithLength:n * sizeof(uint64_t)];
    uint64_t *out = outData.mutableBytes;
    NSUInteger scratchLen = MIN((NSUInteger)blockSize, n > 0 ? n : 1);
    uint8_t *planes = malloc(scratchLen * 8);
    if (!planes) return nil;

    NSUInteger off = kHeaderLen;
    for (uint32_t bi = 0; bi < nBlocks; bi++) {
        if (off + 5 > stream.length) {
            free(planes);
            if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
                @"FDZ1 stream truncated at block header");
            return nil;
        }
        uint8_t transform = p[off];
        if (transform & ~kTransformMask) {
            free(planes);
            if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
                @"unknown FDZ1 transform 0x%02x", transform);
            return nil;
        }
        uint32_t bodyLen = getU32LE(p + off + 1);
        off += 5;
        if (off + bodyLen > stream.length) {
            free(planes);
            if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
                @"FDZ1 stream truncated in block body");
            return nil;
        }
        NSUInteger blkOff = (NSUInteger)bi * blockSize;
        NSUInteger len = MIN((NSUInteger)blockSize, n - blkOff);
        size_t inflated = ZSTD_decompress(planes, len * 8, p + off, bodyLen);
        if (ZSTD_isError(inflated) || inflated != len * 8) {
            free(planes);
            if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
                @"FDZ1 block inflated to the wrong size");
            return nil;
        }
        off += bodyLen;
        if (transform & kTransformPlain) {
            unpackPlainLE(planes, len, out + blkOff);
        } else {
            untranspose(planes, len, out + blkOff);
        }
        if (transform & kTransformDelta) {
            for (NSUInteger i = 1; i < len; i++) {
                out[blkOff + i] += out[blkOff + i - 1];
            }
        }
    }
    free(planes);
    if (off != stream.length) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"trailing bytes after the last FDZ1 block");
        return nil;
    }
    return outData;
}

@end
