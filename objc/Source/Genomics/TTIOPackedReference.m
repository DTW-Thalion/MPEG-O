/*
 * TTIOPackedReference.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOPackedReference
 * Inherits From: NSObject
 * Declared In:   Genomics/TTIOPackedReference.h
 *
 * Packed storage for embedded reference chromosomes: 2-bit ACGT body
 * plus a run mask for everything else. Exception bytes are recorded
 * as maximal runs of (uint32 BE position, uint32 BE length) plus
 * their original bytes, so a multi-megabase N run costs 8 bytes and
 * its body rather than a per-byte mask.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import "TTIOPackedReference.h"
#import "ValueClasses/TTIOEnums.h"
#import "HDF5/TTIOHDF5Errors.h"

static const uint8_t kVersion = 0x01;
static const NSUInteger kHeaderLen = 9;

/* 255 marks a non-ACGT byte; otherwise the 2-bit code. Filled in
   +initialize (runtime-serialised) — no libdispatch dependency. */
static uint8_t _codeTable256[256];

static const uint8_t *_codeTable(void)
{
    return _codeTable256;
}

static void _putU32BE(NSMutableData *d, uint32_t v)
{
    uint8_t b[4] = { (uint8_t)(v >> 24), (uint8_t)(v >> 16),
                     (uint8_t)(v >> 8),  (uint8_t)v };
    [d appendBytes:b length:4];
}

static uint32_t _getU32BE(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16)
         | ((uint32_t)p[2] << 8)  | (uint32_t)p[3];
}

@implementation TTIOPackedReference

+ (void)initialize
{
    if (self != [TTIOPackedReference class]) return;
    memset(_codeTable256, 255, sizeof(_codeTable256));
    _codeTable256['A'] = 0;
    _codeTable256['C'] = 1;
    _codeTable256['G'] = 2;
    _codeTable256['T'] = 3;
}

+ (double)packableFraction:(NSData *)data
{
    if (data.length == 0) return 1.0;
    const uint8_t *code = _codeTable();
    const uint8_t *bytes = data.bytes;
    NSUInteger acgt = 0;
    for (NSUInteger i = 0; i < data.length; i++) {
        if (code[bytes[i]] != 255) acgt++;
    }
    return (double)acgt / (double)data.length;
}

+ (NSData *)encode:(NSData *)data
{
    const uint8_t *code = _codeTable();
    const uint8_t *bytes = data.bytes;
    NSUInteger n = data.length;

    // Maximal exception runs.
    NSMutableData *runTable = [NSMutableData data];
    NSMutableData *runBytes = [NSMutableData data];
    uint32_t runCount = 0;
    NSUInteger runTotal = 0;
    NSUInteger i = 0;
    while (i < n) {
        if (code[bytes[i]] == 255) {
            NSUInteger s = i;
            while (i < n && code[bytes[i]] == 255) i++;
            _putU32BE(runTable, (uint32_t)s);
            _putU32BE(runTable, (uint32_t)(i - s));
            [runBytes appendBytes:bytes + s length:i - s];
            runCount++;
            runTotal += i - s;
        } else {
            i++;
        }
    }

    NSUInteger nAcgt = n - runTotal;
    NSUInteger bodyLen = (nAcgt + 3) / 4;
    NSMutableData *out = [NSMutableData dataWithCapacity:
        kHeaderLen + runTable.length + runBytes.length + bodyLen];
    [out appendBytes:&kVersion length:1];
    _putU32BE(out, (uint32_t)n);
    _putU32BE(out, runCount);
    [out appendData:runTable];
    [out appendData:runBytes];

    uint8_t acc = 0;
    int slot = 0;
    NSMutableData *body = [NSMutableData dataWithLength:bodyLen];
    uint8_t *bp = body.mutableBytes;
    NSUInteger written = 0;
    for (NSUInteger p = 0; p < n; p++) {
        uint8_t c = code[bytes[p]];
        if (c == 255) continue;
        acc = (uint8_t)((acc << 2) | c);
        if (++slot == 4) {
            bp[written++] = acc;
            acc = 0; slot = 0;
        }
    }
    if (slot != 0) bp[written] = (uint8_t)(acc << (2 * (4 - slot)));
    [out appendData:body];
    return out;
}

+ (NSData *)decode:(NSData *)stream error:(NSError **)error
{
    if (stream.length < kHeaderLen) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"packed reference stream shorter than its header");
        return nil;
    }
    const uint8_t *p = stream.bytes;
    if (p[0] != kVersion) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"unknown packed reference version 0x%02x", p[0]);
        return nil;
    }
    uint32_t n = _getU32BE(p + 1);
    uint32_t runCount = _getU32BE(p + 5);
    NSUInteger off = kHeaderLen;
    if (stream.length < off + (NSUInteger)runCount * 8) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"packed reference stream truncated in run table");
        return nil;
    }

    NSMutableData *outData = [NSMutableData dataWithLength:n];
    uint8_t *out = outData.mutableBytes;
    NSMutableData *excData = [NSMutableData dataWithLength:n];
    uint8_t *exc = excData.mutableBytes;

    uint32_t (*runsPos)[2] = calloc(runCount ? runCount : 1, sizeof(uint32_t[2]));
    int64_t prevEnd = -1;
    NSUInteger runTotal = 0;
    for (uint32_t r = 0; r < runCount; r++) {
        uint32_t pos = _getU32BE(p + off);
        uint32_t len = _getU32BE(p + off + 4);
        off += 8;
        if (len == 0 || (int64_t)pos <= prevEnd || (uint64_t)pos + len > n) {
            free(runsPos);
            if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
                @"malformed exception run table");
            return nil;
        }
        runsPos[r][0] = pos;
        runsPos[r][1] = len;
        prevEnd = (int64_t)pos + len - 1;
        runTotal += len;
    }
    if (stream.length < off + runTotal) {
        free(runsPos);
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"packed reference stream truncated in run bytes");
        return nil;
    }
    for (uint32_t r = 0; r < runCount; r++) {
        memcpy(out + runsPos[r][0], p + off, runsPos[r][1]);
        memset(exc + runsPos[r][0], 1, runsPos[r][1]);
        off += runsPos[r][1];
    }
    free(runsPos);

    NSUInteger nAcgt = n - runTotal;
    NSUInteger bodyLen = (nAcgt + 3) / 4;
    if (stream.length < off + bodyLen) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"packed reference stream truncated in body");
        return nil;
    }
    static const uint8_t lut[4] = { 'A', 'C', 'G', 'T' };
    NSUInteger consumed = 0;
    uint8_t bodyByte = 0;
    int slot = 4;
    for (NSUInteger q = 0; q < n; q++) {
        if (exc[q]) continue;
        if (slot == 4) {
            bodyByte = p[off++];
            slot = 0;
        }
        out[q] = lut[(bodyByte >> (6 - 2 * slot)) & 0x3];
        slot++;
        consumed++;
    }
    (void)consumed;
    return outData;
}

+ (NSData *)payloadForSequence:(NSData *)seq
                   datasetName:(NSString **)outName
{
    if ([self packableFraction:seq] >= 0.5) {
        NSData *candidate = [self encode:seq];
        if (candidate.length < seq.length) {
            *outName = @"data_packed";
            return candidate;
        }
    }
    *outName = @"data";
    return seq;
}

+ (BOOL)writeChromosomeDataset:(id<TTIOStorageGroup>)chromGroup
                      sequence:(NSData *)seq
                         error:(NSError **)error
{
    NSString *name = nil;
    NSData *payload = [self payloadForSequence:seq datasetName:&name];
    id<TTIOStorageDataset> ds =
        [chromGroup createDatasetNamed:name
                             precision:TTIOPrecisionUInt8
                                length:payload.length
                             chunkSize:65536
                           compression:TTIOCompressionZlib
                      compressionLevel:6
                                 error:error];
    if (ds == nil) return NO;
    return [ds writeAll:payload error:error];
}

+ (NSData *)readChromosomeBytes:(id<TTIOStorageGroup>)chromGroup
                          error:(NSError **)error
{
    if ([chromGroup hasChildNamed:@"data_packed"]) {
        id<TTIOStorageDataset> ds =
            [chromGroup openDatasetNamed:@"data_packed" error:error];
        if (ds == nil) return nil;
        id raw = [ds readAll:error];
        if (![raw isKindOfClass:[NSData class]]) return nil;
        return [self decode:(NSData *)raw error:error];
    }
    id<TTIOStorageDataset> ds =
        [chromGroup openDatasetNamed:@"data" error:error];
    if (ds == nil) return nil;
    id raw = [ds readAll:error];
    if (![raw isKindOfClass:[NSData class]]) return nil;
    return (NSData *)raw;
}

@end
