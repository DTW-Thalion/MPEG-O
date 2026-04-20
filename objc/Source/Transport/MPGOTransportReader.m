/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "MPGOTransportReader.h"
#import "Dataset/MPGOSpectralDataset.h"
#import "Dataset/MPGOWrittenRun.h"
#import "ValueClasses/MPGOEnums.h"
#import <string.h>
#import <zlib.h>

// ---------------------------------------------------------------- LE helpers

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

static NSString *readLEString(const uint8_t *bytes, NSUInteger length,
                              NSUInteger *offset, int width)
{
    NSUInteger off = *offset;
    uint32_t strLen = 0;
    if (width == 2) {
        if (off + 2 > length) return nil;
        strLen = readU16(&bytes[off]);
        off += 2;
    } else {
        if (off + 4 > length) return nil;
        strLen = readU32(&bytes[off]);
        off += 4;
    }
    if (off + strLen > length) return nil;
    NSString *s = [[NSString alloc] initWithBytes:&bytes[off]
                                            length:strLen
                                          encoding:NSUTF8StringEncoding];
    *offset = off + strLen;
    return s ?: @"";
}

// ---------------------------------------------------------------- record

@implementation MPGOTransportPacketRecord

- (instancetype)initWithHeader:(MPGOTransportPacketHeader *)h payload:(NSData *)p
{
    if ((self = [super init])) {
        _header = h;
        _payload = [p copy];
    }
    return self;
}

@end

// ---------------------------------------------------------------- reader

@implementation MPGOTransportReader
{
    NSData *_buffer;
}

- (instancetype)initWithInputPath:(NSString *)path
{
    if ((self = [super init])) {
        _buffer = [NSData dataWithContentsOfFile:path];
    }
    return self;
}

- (instancetype)initWithData:(NSData *)data
{
    if ((self = [super init])) {
        _buffer = [data copy];
    }
    return self;
}

- (NSArray<MPGOTransportPacketRecord *> *)readAllPacketsWithError:(NSError **)error
{
    if (!_buffer) {
        if (error) *error = [NSError errorWithDomain:MPGOTransportErrorDomain
                                                 code:MPGOTransportErrorTruncated
                                             userInfo:@{NSLocalizedDescriptionKey:
                             @"empty input"}];
        return nil;
    }
    const uint8_t *bytes = (const uint8_t *)_buffer.bytes;
    NSUInteger length = _buffer.length;
    NSUInteger offset = 0;
    NSMutableArray<MPGOTransportPacketRecord *> *out = [NSMutableArray array];

    while (offset < length) {
        if (length - offset < MPGOTransportHeaderSize) {
            if (error) *error = [NSError errorWithDomain:MPGOTransportErrorDomain
                                                     code:MPGOTransportErrorTruncated
                                                 userInfo:@{NSLocalizedDescriptionKey:
                                 @"truncated packet header"}];
            return nil;
        }
        MPGOTransportPacketHeader *hdr =
            [MPGOTransportPacketHeader decodeFromBytes:&bytes[offset]
                                                 length:length - offset
                                                  error:error];
        if (!hdr) return nil;
        offset += MPGOTransportHeaderSize;

        if (length - offset < hdr.payloadLength) {
            if (error) *error = [NSError errorWithDomain:MPGOTransportErrorDomain
                                                     code:MPGOTransportErrorTruncated
                                                 userInfo:@{NSLocalizedDescriptionKey:
                                 @"truncated payload"}];
            return nil;
        }
        NSData *payload = [NSData dataWithBytes:&bytes[offset]
                                          length:hdr.payloadLength];
        offset += hdr.payloadLength;

        if (hdr.flags & MPGOTransportPacketFlagHasChecksum) {
            if (length - offset < 4) {
                if (error) *error = [NSError errorWithDomain:MPGOTransportErrorDomain
                                                         code:MPGOTransportErrorTruncated
                                                     userInfo:@{NSLocalizedDescriptionKey:
                                     @"truncated CRC-32C"}];
                return nil;
            }
            uint32_t expected = readU32(&bytes[offset]);
            offset += 4;
            uint32_t actual = MPGOTransportCRC32C((const uint8_t *)payload.bytes,
                                                     payload.length);
            if (expected != actual) {
                if (error) *error = [NSError errorWithDomain:MPGOTransportErrorDomain
                                                         code:MPGOTransportErrorChecksumFailed
                                                     userInfo:@{NSLocalizedDescriptionKey:
                                     [NSString stringWithFormat:@"CRC-32C mismatch: expected 0x%08x, got 0x%08x",
                                         expected, actual]}];
                return nil;
            }
        }

        MPGOTransportPacketRecord *rec =
            [[MPGOTransportPacketRecord alloc] initWithHeader:hdr payload:payload];
        [out addObject:rec];

        if (hdr.packetType == MPGOTransportPacketEndOfStream) break;
    }

    return out;
}

// ---------------------------------------------------------------- materialize

static MPGOPolarity polarityFromWire(uint8_t w)
{
    switch (w) {
        case 0: return MPGOPolarityPositive;
        case 1: return MPGOPolarityNegative;
        default: return MPGOPolarityUnknown;
    }
}

typedef struct {
    uint16_t datasetId;
    NSString *name;
    uint8_t acquisitionMode;
    NSString *spectrumClass;
    NSArray<NSString *> *channelNames;
    uint32_t expectedAUCount;
} DatasetMetaStruct;

- (BOOL)writeMpgoToPath:(NSString *)outputPath error:(NSError **)error
{
    NSArray<MPGOTransportPacketRecord *> *packets =
        [self readAllPacketsWithError:error];
    if (!packets) return NO;

    NSString *title = @"";
    NSString *isa = @"";

    NSMutableDictionary<NSNumber *, NSDictionary *> *datasetMetas =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSMutableDictionary *> *runData =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSNumber *> *lastSeq =
        [NSMutableDictionary dictionary];
    BOOL sawStreamHeader = NO;

    for (MPGOTransportPacketRecord *rec in packets) {
        MPGOTransportPacketHeader *h = rec.header;
        const uint8_t *bytes = (const uint8_t *)rec.payload.bytes;
        NSUInteger len = rec.payload.length;
        NSUInteger off = 0;

        if (h.packetType == MPGOTransportPacketStreamHeader) {
            if (sawStreamHeader) continue;
            sawStreamHeader = YES;
            NSString *formatVersion = readLEString(bytes, len, &off, 2); (void)formatVersion;
            title = readLEString(bytes, len, &off, 2) ?: @"";
            isa = readLEString(bytes, len, &off, 2) ?: @"";
            if (off + 2 > len) break;
            uint16_t nFeatures = readU16(&bytes[off]); off += 2;
            for (uint16_t i = 0; i < nFeatures; i++) {
                (void)readLEString(bytes, len, &off, 2);
            }
            // n_datasets (not needed on the read side)
            continue;
        }
        if (!sawStreamHeader) {
            if (error) *error = [NSError errorWithDomain:MPGOTransportErrorDomain
                                                     code:MPGOTransportErrorMissingStreamHeader
                                                 userInfo:@{NSLocalizedDescriptionKey:
                                 @"first packet must be StreamHeader"}];
            return NO;
        }

        if (h.packetType == MPGOTransportPacketDatasetHeader) {
            if (off + 2 > len) continue;
            uint16_t did = readU16(&bytes[off]); off += 2;
            NSString *name = readLEString(bytes, len, &off, 2);
            if (off + 1 > len) continue;
            uint8_t acqMode = bytes[off]; off += 1;
            NSString *spectrumClass = readLEString(bytes, len, &off, 2);
            if (off + 1 > len) continue;
            uint8_t nch = bytes[off]; off += 1;
            NSMutableArray<NSString *> *chNames = [NSMutableArray array];
            for (uint8_t i = 0; i < nch; i++) {
                NSString *c = readLEString(bytes, len, &off, 2);
                if (c) [chNames addObject:c];
            }
            (void)readLEString(bytes, len, &off, 4);  // instrument_json
            // expected_au_count
            uint32_t expected = 0;
            if (off + 4 <= len) { expected = readU32(&bytes[off]); off += 4; }

            datasetMetas[@(did)] = @{
                @"name": name ?: @"",
                @"acquisitionMode": @(acqMode),
                @"spectrumClass": spectrumClass ?: @"MPGOMassSpectrum",
                @"channelNames": [chNames copy],
                @"expectedAUCount": @(expected),
            };

            NSMutableDictionary *rd = [NSMutableDictionary dictionary];
            rd[@"runningOffset"] = @(0);
            rd[@"offsets"] = [NSMutableArray array];
            rd[@"lengths"] = [NSMutableArray array];
            rd[@"retentionTimes"] = [NSMutableArray array];
            rd[@"msLevels"] = [NSMutableArray array];
            rd[@"polarities"] = [NSMutableArray array];
            rd[@"precursorMzs"] = [NSMutableArray array];
            rd[@"precursorCharges"] = [NSMutableArray array];
            rd[@"basePeakIntensities"] = [NSMutableArray array];
            NSMutableDictionary *chans = [NSMutableDictionary dictionary];
            for (NSString *c in chNames) chans[c] = [NSMutableData data];
            rd[@"channels"] = chans;
            runData[@(did)] = rd;
            continue;
        }

        if (h.packetType == MPGOTransportPacketAccessUnit) {
            NSNumber *didKey = @(h.datasetId);
            NSDictionary *meta = datasetMetas[didKey];
            if (!meta) {
                if (error) *error = [NSError errorWithDomain:MPGOTransportErrorDomain
                                                         code:MPGOTransportErrorUnexpectedPayload
                                                     userInfo:@{NSLocalizedDescriptionKey:
                                     [NSString stringWithFormat:@"AccessUnit before DatasetHeader for id %u",
                                         (unsigned)h.datasetId]}];
                return NO;
            }
            NSNumber *prev = lastSeq[didKey];
            if (prev && h.auSequence <= prev.unsignedIntValue) {
                if (error) *error = [NSError errorWithDomain:MPGOTransportErrorDomain
                                                         code:MPGOTransportErrorNonMonotonicAU
                                                     userInfo:@{NSLocalizedDescriptionKey:
                                     [NSString stringWithFormat:@"non-monotonic au_sequence in dataset %u",
                                         (unsigned)h.datasetId]}];
                return NO;
            }
            lastSeq[didKey] = @(h.auSequence);

            NSError *auErr = nil;
            MPGOAccessUnit *au =
                [MPGOAccessUnit decodeFromBytes:bytes length:len error:&auErr];
            if (!au) {
                if (error) *error = auErr;
                return NO;
            }

            NSMutableDictionary *rd = runData[didKey];
            NSMutableDictionary<NSString *, NSMutableData *> *chans = rd[@"channels"];
            NSUInteger spectrumLength = 0;
            for (MPGOTransportChannelData *ch in au.channels) {
                if (ch.precision != MPGOPrecisionFloat64) {
                    if (error) *error = [NSError errorWithDomain:MPGOTransportErrorDomain
                                                             code:MPGOTransportErrorUnexpectedPayload
                                                         userInfo:@{NSLocalizedDescriptionKey:
                                         @"reader supports FLOAT64 precision only"}];
                    return NO;
                }
                NSData *decoded = ch.data;
                if (ch.compression == MPGOCompressionZlib) {
                    // Allocate a generous output buffer. For
                    // float64 payloads the decompressed size is
                    // ch.nElements * 8 exactly.
                    NSMutableData *out = [NSMutableData dataWithLength:(NSUInteger)ch.nElements * 8];
                    uLongf destLen = out.length;
                    int rc = uncompress((Bytef *)out.mutableBytes, &destLen,
                                         (const Bytef *)ch.data.bytes, (uLong)ch.data.length);
                    if (rc != Z_OK) {
                        if (error) *error = [NSError errorWithDomain:MPGOTransportErrorDomain
                                                                 code:MPGOTransportErrorUnexpectedPayload
                                                             userInfo:@{NSLocalizedDescriptionKey:
                                             [NSString stringWithFormat:@"zlib inflate failed: rc=%d",
                                                 rc]}];
                        return NO;
                    }
                    [out setLength:destLen];
                    decoded = out;
                } else if (ch.compression != MPGOCompressionNone) {
                    if (error) *error = [NSError errorWithDomain:MPGOTransportErrorDomain
                                                             code:MPGOTransportErrorUnexpectedPayload
                                                         userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"unsupported compression on reader: %u",
                                             (unsigned)ch.compression]}];
                    return NO;
                }
                NSMutableData *sink = chans[ch.name];
                if (!sink) {
                    sink = [NSMutableData data];
                    chans[ch.name] = sink;
                }
                [sink appendData:decoded];
                NSUInteger n = decoded.length / 8;
                if (spectrumLength != 0 && spectrumLength != n) {
                    if (error) *error = [NSError errorWithDomain:MPGOTransportErrorDomain
                                                             code:MPGOTransportErrorUnexpectedPayload
                                                         userInfo:@{NSLocalizedDescriptionKey:
                                         @"channels have mismatched lengths in AU"}];
                    return NO;
                }
                spectrumLength = n;
            }

            uint64_t curOffset = ((NSNumber *)rd[@"runningOffset"]).unsignedLongLongValue;
            [(NSMutableArray *)rd[@"offsets"] addObject:@(curOffset)];
            [(NSMutableArray *)rd[@"lengths"] addObject:@((uint32_t)spectrumLength)];
            rd[@"runningOffset"] = @(curOffset + spectrumLength);
            [(NSMutableArray *)rd[@"retentionTimes"] addObject:@(au.retentionTime)];
            [(NSMutableArray *)rd[@"msLevels"] addObject:@((int32_t)au.msLevel)];
            [(NSMutableArray *)rd[@"polarities"]
                addObject:@((int32_t)polarityFromWire(au.polarity))];
            [(NSMutableArray *)rd[@"precursorMzs"] addObject:@(au.precursorMz)];
            [(NSMutableArray *)rd[@"precursorCharges"]
                addObject:@((int32_t)au.precursorCharge)];
            [(NSMutableArray *)rd[@"basePeakIntensities"]
                addObject:@(au.basePeakIntensity)];
            continue;
        }

        if (h.packetType == MPGOTransportPacketEndOfDataset) continue;
        if (h.packetType == MPGOTransportPacketEndOfStream) break;
        // Annotation/Provenance/Chromatogram/Protection — skipped in M67.
    }

    // Build MPGOWrittenRun objects.
    NSMutableDictionary<NSString *, MPGOWrittenRun *> *runs =
        [NSMutableDictionary dictionary];
    for (NSNumber *didKey in datasetMetas) {
        NSDictionary *meta = datasetMetas[didKey];
        NSDictionary *rd = runData[didKey];
        NSMutableDictionary *channelDataOut = [NSMutableDictionary dictionary];
        for (NSString *c in (NSArray *)meta[@"channelNames"]) {
            NSMutableData *src = rd[@"channels"][c];
            channelDataOut[c] = src ? [src copy] : [NSData data];
        }

        NSArray *offArr = rd[@"offsets"];
        NSMutableData *offsetsData = [NSMutableData dataWithCapacity:offArr.count * 8];
        for (NSNumber *n in offArr) {
            uint64_t v = n.unsignedLongLongValue;
            [offsetsData appendBytes:&v length:8];
        }
        NSArray *lenArr = rd[@"lengths"];
        NSMutableData *lengthsData = [NSMutableData dataWithCapacity:lenArr.count * 4];
        for (NSNumber *n in lenArr) {
            uint32_t v = n.unsignedIntValue;
            [lengthsData appendBytes:&v length:4];
        }
        NSArray *rtArr = rd[@"retentionTimes"];
        NSMutableData *rtData = [NSMutableData dataWithCapacity:rtArr.count * 8];
        for (NSNumber *n in rtArr) {
            double v = n.doubleValue;
            [rtData appendBytes:&v length:8];
        }
        NSArray *msArr = rd[@"msLevels"];
        NSMutableData *msData = [NSMutableData dataWithCapacity:msArr.count * 4];
        for (NSNumber *n in msArr) {
            int32_t v = n.intValue;
            [msData appendBytes:&v length:4];
        }
        NSArray *polArr = rd[@"polarities"];
        NSMutableData *polData = [NSMutableData dataWithCapacity:polArr.count * 4];
        for (NSNumber *n in polArr) {
            int32_t v = n.intValue;
            [polData appendBytes:&v length:4];
        }
        NSArray *pmzArr = rd[@"precursorMzs"];
        NSMutableData *pmzData = [NSMutableData dataWithCapacity:pmzArr.count * 8];
        for (NSNumber *n in pmzArr) {
            double v = n.doubleValue;
            [pmzData appendBytes:&v length:8];
        }
        NSArray *pcArr = rd[@"precursorCharges"];
        NSMutableData *pcData = [NSMutableData dataWithCapacity:pcArr.count * 4];
        for (NSNumber *n in pcArr) {
            int32_t v = n.intValue;
            [pcData appendBytes:&v length:4];
        }
        NSArray *bpiArr = rd[@"basePeakIntensities"];
        NSMutableData *bpiData = [NSMutableData dataWithCapacity:bpiArr.count * 8];
        for (NSNumber *n in bpiArr) {
            double v = n.doubleValue;
            [bpiData appendBytes:&v length:8];
        }

        MPGOWrittenRun *wr =
            [[MPGOWrittenRun alloc]
                initWithSpectrumClassName:(NSString *)meta[@"spectrumClass"]
                          acquisitionMode:((NSNumber *)meta[@"acquisitionMode"]).longLongValue
                              channelData:channelDataOut
                                  offsets:offsetsData
                                  lengths:lengthsData
                           retentionTimes:rtData
                                 msLevels:msData
                               polarities:polData
                             precursorMzs:pmzData
                         precursorCharges:pcData
                      basePeakIntensities:bpiData];
        runs[(NSString *)meta[@"name"]] = wr;
    }

    return [MPGOSpectralDataset writeMinimalToPath:outputPath
                                              title:title
                                 isaInvestigationId:isa
                                             msRuns:runs
                                    identifications:nil
                                    quantifications:nil
                                  provenanceRecords:nil
                                              error:error];
}

@end
