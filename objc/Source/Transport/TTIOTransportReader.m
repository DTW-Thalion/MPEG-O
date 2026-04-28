/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "TTIOTransportReader.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOWrittenRun.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Codecs/TTIORans.h"        // M90.10: rANS wire codec dispatch
#import "Codecs/TTIOBasePack.h"    // M90.10: BASE_PACK wire codec dispatch
#import "ValueClasses/TTIOEnums.h"
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

@implementation TTIOTransportPacketRecord

- (instancetype)initWithHeader:(TTIOTransportPacketHeader *)h payload:(NSData *)p
{
    if ((self = [super init])) {
        _header = h;
        _payload = [p copy];
    }
    return self;
}

@end

// ---------------------------------------------------------------- reader

@implementation TTIOTransportReader
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

- (NSArray<TTIOTransportPacketRecord *> *)readAllPacketsWithError:(NSError **)error
{
    if (!_buffer) {
        if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                 code:TTIOTransportErrorTruncated
                                             userInfo:@{NSLocalizedDescriptionKey:
                             @"empty input"}];
        return nil;
    }
    const uint8_t *bytes = (const uint8_t *)_buffer.bytes;
    NSUInteger length = _buffer.length;
    NSUInteger offset = 0;
    NSMutableArray<TTIOTransportPacketRecord *> *out = [NSMutableArray array];

    while (offset < length) {
        if (length - offset < TTIOTransportHeaderSize) {
            if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                     code:TTIOTransportErrorTruncated
                                                 userInfo:@{NSLocalizedDescriptionKey:
                                 @"truncated packet header"}];
            return nil;
        }
        TTIOTransportPacketHeader *hdr =
            [TTIOTransportPacketHeader decodeFromBytes:&bytes[offset]
                                                 length:length - offset
                                                  error:error];
        if (!hdr) return nil;
        offset += TTIOTransportHeaderSize;

        if (length - offset < hdr.payloadLength) {
            if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                     code:TTIOTransportErrorTruncated
                                                 userInfo:@{NSLocalizedDescriptionKey:
                                 @"truncated payload"}];
            return nil;
        }
        NSData *payload = [NSData dataWithBytes:&bytes[offset]
                                          length:hdr.payloadLength];
        offset += hdr.payloadLength;

        if (hdr.flags & TTIOTransportPacketFlagHasChecksum) {
            if (length - offset < 4) {
                if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                         code:TTIOTransportErrorTruncated
                                                     userInfo:@{NSLocalizedDescriptionKey:
                                     @"truncated CRC-32C"}];
                return nil;
            }
            uint32_t expected = readU32(&bytes[offset]);
            offset += 4;
            uint32_t actual = TTIOTransportCRC32C((const uint8_t *)payload.bytes,
                                                     payload.length);
            if (expected != actual) {
                if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                         code:TTIOTransportErrorChecksumFailed
                                                     userInfo:@{NSLocalizedDescriptionKey:
                                     [NSString stringWithFormat:@"CRC-32C mismatch: expected 0x%08x, got 0x%08x",
                                         expected, actual]}];
                return nil;
            }
        }

        TTIOTransportPacketRecord *rec =
            [[TTIOTransportPacketRecord alloc] initWithHeader:hdr payload:payload];
        [out addObject:rec];

        if (hdr.packetType == TTIOTransportPacketEndOfStream) break;
    }

    return out;
}

// ---------------------------------------------------------------- materialize

static TTIOPolarity polarityFromWire(uint8_t w)
{
    switch (w) {
        case 0: return TTIOPolarityPositive;
        case 1: return TTIOPolarityNegative;
        default: return TTIOPolarityUnknown;
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

- (BOOL)writeTtioToPath:(NSString *)outputPath error:(NSError **)error
{
    NSArray<TTIOTransportPacketRecord *> *packets =
        [self readAllPacketsWithError:error];
    if (!packets) return NO;

    NSString *title = @"";
    NSString *isa = @"";

    NSMutableDictionary<NSNumber *, NSDictionary *> *datasetMetas =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSMutableDictionary *> *runData =
        [NSMutableDictionary dictionary];
    // M89.2 / M89.4: genomic accumulators, keyed by dataset_id. Each
    // value holds the parallel arrays that ultimately feed
    // TTIOWrittenGenomicRun.
    NSMutableDictionary<NSNumber *, NSMutableDictionary *> *genomicData =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSNumber *> *lastSeq =
        [NSMutableDictionary dictionary];
    BOOL sawStreamHeader = NO;

    for (TTIOTransportPacketRecord *rec in packets) {
        TTIOTransportPacketHeader *h = rec.header;
        const uint8_t *bytes = (const uint8_t *)rec.payload.bytes;
        NSUInteger len = rec.payload.length;
        NSUInteger off = 0;

        if (h.packetType == TTIOTransportPacketStreamHeader) {
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
            if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                     code:TTIOTransportErrorMissingStreamHeader
                                                 userInfo:@{NSLocalizedDescriptionKey:
                                 @"first packet must be StreamHeader"}];
            return NO;
        }

        if (h.packetType == TTIOTransportPacketDatasetHeader) {
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

            // Re-read instrument_json (M89.2: genomic dataset header
            // carries reference_uri / platform / sample_name / modality
            // in this slot; we already advanced past it above with a
            // discarded value, so re-extract by walking the payload
            // again before the n_channels byte). Cheaper to keep a
            // local copy from the first pass.
            //
            // (We deliberately skip rewinding — readLEString returned
            // the JSON string we discarded with `(void)`. To minimise
            // churn we recompute by re-reading from a fresh offset.)
            NSUInteger jsonOff = 0;
            jsonOff += 2;  // dataset_id
            // skip name
            (void)readLEString(bytes, len, &jsonOff, 2);
            jsonOff += 1;  // acq_mode
            (void)readLEString(bytes, len, &jsonOff, 2);  // spectrum_class
            jsonOff += 1;  // n_channels
            for (uint8_t i = 0; i < nch; i++) {
                (void)readLEString(bytes, len, &jsonOff, 2);
            }
            NSString *instrumentJSON = readLEString(bytes, len, &jsonOff, 4) ?: @"";

            datasetMetas[@(did)] = @{
                @"name": name ?: @"",
                @"acquisitionMode": @(acqMode),
                @"spectrumClass": spectrumClass ?: @"TTIOMassSpectrum",
                @"channelNames": [chNames copy],
                @"expectedAUCount": @(expected),
                @"instrumentJSON": instrumentJSON,
            };

            // M89.2: route genomic datasets to a parallel accumulator.
            if ([spectrumClass isEqualToString:@"TTIOGenomicRead"]) {
                NSMutableDictionary *gd = [NSMutableDictionary dictionary];
                gd[@"runningOffset"] = @(0);
                gd[@"chromosomes"] = [NSMutableArray array];
                gd[@"positions"] = [NSMutableArray array];
                gd[@"mappingQualities"] = [NSMutableArray array];
                gd[@"flags"] = [NSMutableArray array];
                gd[@"sequences"] = [NSMutableData data];
                gd[@"qualities"] = [NSMutableData data];
                gd[@"offsets"] = [NSMutableArray array];
                gd[@"lengths"] = [NSMutableArray array];
                // M90.9 compound-field accumulators.
                gd[@"cigars"] = [NSMutableArray array];
                gd[@"readNames"] = [NSMutableArray array];
                gd[@"mateChromosomes"] = [NSMutableArray array];
                gd[@"matePositions"] = [NSMutableArray array];
                gd[@"templateLengths"] = [NSMutableArray array];
                genomicData[@(did)] = gd;
                continue;
            }

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

        if (h.packetType == TTIOTransportPacketAccessUnit) {
            NSNumber *didKey = @(h.datasetId);
            NSDictionary *meta = datasetMetas[didKey];
            if (!meta) {
                if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                         code:TTIOTransportErrorUnexpectedPayload
                                                     userInfo:@{NSLocalizedDescriptionKey:
                                     [NSString stringWithFormat:@"AccessUnit before DatasetHeader for id %u",
                                         (unsigned)h.datasetId]}];
                return NO;
            }
            NSNumber *prev = lastSeq[didKey];
            if (prev && h.auSequence <= prev.unsignedIntValue) {
                if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                         code:TTIOTransportErrorNonMonotonicAU
                                                     userInfo:@{NSLocalizedDescriptionKey:
                                     [NSString stringWithFormat:@"non-monotonic au_sequence in dataset %u",
                                         (unsigned)h.datasetId]}];
                return NO;
            }
            lastSeq[didKey] = @(h.auSequence);

            NSError *auErr = nil;
            TTIOAccessUnit *au =
                [TTIOAccessUnit decodeFromBytes:bytes length:len error:&auErr];
            if (!au) {
                if (error) *error = auErr;
                return NO;
            }

            // M89.2: route to genomic accumulator if this dataset is
            // a TTIOGenomicRead stream.
            NSMutableDictionary *gd = genomicData[didKey];
            if (gd) {
                if (au.spectrumClass != 5) {
                    if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                             code:TTIOTransportErrorUnexpectedPayload
                                                         userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"genomic accumulator received spectrum_class %u",
                                             (unsigned)au.spectrumClass]}];
                    return NO;
                }
                [(NSMutableArray *)gd[@"chromosomes"] addObject:(au.chromosome ?: @"")];
                [(NSMutableArray *)gd[@"positions"] addObject:@(au.position)];
                [(NSMutableArray *)gd[@"mappingQualities"] addObject:@(au.mappingQuality)];
                [(NSMutableArray *)gd[@"flags"] addObject:@((uint32_t)au.flags)];
                // M90.9: AU mate extension — pulled directly off the
                // decoded AU, defaults to -1 / 0 for M89.1 fixtures.
                [(NSMutableArray *)gd[@"matePositions"] addObject:@(au.matePosition)];
                [(NSMutableArray *)gd[@"templateLengths"] addObject:@(au.templateLength)];
                NSMutableData *seqSink = gd[@"sequences"];
                NSMutableData *qualSink = gd[@"qualities"];
                NSUInteger length = 0;
                // M90.9 compound-field defaults — empty when the AU
                // omits the channel (M89.2-era stream).
                NSString *cigarStr = @"";
                NSString *readNameStr = @"";
                NSString *mateChrStr = @"";
                for (TTIOTransportChannelData *ch in au.channels) {
                    if (ch.precision != TTIOPrecisionUInt8) {
                        if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                                 code:TTIOTransportErrorUnexpectedPayload
                                                             userInfo:@{NSLocalizedDescriptionKey:
                                             [NSString stringWithFormat:@"genomic channel precision %u not supported (UINT8 only)",
                                                 (unsigned)ch.precision]}];
                        return NO;
                    }
                    // M90.10: dispatch on the wire compression byte.
                    // NONE → identity; RANS_ORDER0/1 → TTIORansDecode;
                    // BASE_PACK → TTIOBasePackDecode. Other codecs
                    // unsupported on the genomic transport path.
                    NSData *decoded = ch.data;
                    if (ch.compression != TTIOCompressionNone) {
                        NSError *decErr = nil;
                        NSData *out = nil;
                        if (ch.compression == TTIOCompressionRansOrder0
                            || ch.compression == TTIOCompressionRansOrder1) {
                            out = TTIORansDecode(ch.data, &decErr);
                        } else if (ch.compression == TTIOCompressionBasePack) {
                            out = TTIOBasePackDecode(ch.data, &decErr);
                        } else {
                            if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                                     code:TTIOTransportErrorUnexpectedPayload
                                                                 userInfo:@{NSLocalizedDescriptionKey:
                                                 [NSString stringWithFormat:@"genomic channel compression %u unsupported on transport (M90.10)",
                                                     (unsigned)ch.compression]}];
                            return NO;
                        }
                        if (!out) {
                            if (error) *error = decErr ?: [NSError errorWithDomain:TTIOTransportErrorDomain
                                                                                code:TTIOTransportErrorUnexpectedPayload
                                                                            userInfo:@{NSLocalizedDescriptionKey:
                                                  [NSString stringWithFormat:@"genomic channel '%@' codec decode failed", ch.name]}];
                            return NO;
                        }
                        decoded = out;
                    }
                    if ([ch.name isEqualToString:@"sequences"]) {
                        [seqSink appendData:decoded];
                        length = decoded.length;
                    } else if ([ch.name isEqualToString:@"qualities"]) {
                        [qualSink appendData:decoded];
                        if (length == 0) length = decoded.length;
                    } else if ([ch.name isEqualToString:@"cigar"]) {
                        cigarStr = [[NSString alloc] initWithData:decoded
                                                          encoding:NSUTF8StringEncoding] ?: @"";
                    } else if ([ch.name isEqualToString:@"read_name"]) {
                        readNameStr = [[NSString alloc] initWithData:decoded
                                                              encoding:NSUTF8StringEncoding] ?: @"";
                    } else if ([ch.name isEqualToString:@"mate_chromosome"]) {
                        mateChrStr = [[NSString alloc] initWithData:decoded
                                                              encoding:NSUTF8StringEncoding] ?: @"";
                    }
                }
                [(NSMutableArray *)gd[@"cigars"] addObject:cigarStr];
                [(NSMutableArray *)gd[@"readNames"] addObject:readNameStr];
                [(NSMutableArray *)gd[@"mateChromosomes"] addObject:mateChrStr];
                uint64_t curOffset = ((NSNumber *)gd[@"runningOffset"]).unsignedLongLongValue;
                [(NSMutableArray *)gd[@"offsets"] addObject:@(curOffset)];
                [(NSMutableArray *)gd[@"lengths"] addObject:@((uint32_t)length)];
                gd[@"runningOffset"] = @(curOffset + length);
                continue;
            }

            NSMutableDictionary *rd = runData[didKey];
            NSMutableDictionary<NSString *, NSMutableData *> *chans = rd[@"channels"];
            NSUInteger spectrumLength = 0;
            for (TTIOTransportChannelData *ch in au.channels) {
                if (ch.precision != TTIOPrecisionFloat64) {
                    if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                             code:TTIOTransportErrorUnexpectedPayload
                                                         userInfo:@{NSLocalizedDescriptionKey:
                                         @"reader supports FLOAT64 precision only"}];
                    return NO;
                }
                NSData *decoded = ch.data;
                if (ch.compression == TTIOCompressionZlib) {
                    // Allocate a generous output buffer. For
                    // float64 payloads the decompressed size is
                    // ch.nElements * 8 exactly.
                    NSMutableData *out = [NSMutableData dataWithLength:(NSUInteger)ch.nElements * 8];
                    uLongf destLen = out.length;
                    int rc = uncompress((Bytef *)out.mutableBytes, &destLen,
                                         (const Bytef *)ch.data.bytes, (uLong)ch.data.length);
                    if (rc != Z_OK) {
                        if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                                 code:TTIOTransportErrorUnexpectedPayload
                                                             userInfo:@{NSLocalizedDescriptionKey:
                                             [NSString stringWithFormat:@"zlib inflate failed: rc=%d",
                                                 rc]}];
                        return NO;
                    }
                    [out setLength:destLen];
                    decoded = out;
                } else if (ch.compression != TTIOCompressionNone) {
                    if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                             code:TTIOTransportErrorUnexpectedPayload
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
                    if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                             code:TTIOTransportErrorUnexpectedPayload
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

        if (h.packetType == TTIOTransportPacketEndOfDataset) continue;
        if (h.packetType == TTIOTransportPacketEndOfStream) break;
        // Annotation/Provenance/Chromatogram/Protection — skipped in M67.
    }

    // Build TTIOWrittenRun objects.
    NSMutableDictionary<NSString *, TTIOWrittenRun *> *runs =
        [NSMutableDictionary dictionary];
    for (NSNumber *didKey in datasetMetas) {
        NSDictionary *meta = datasetMetas[didKey];
        // Skip genomic datasets — built separately below.
        if (genomicData[didKey]) continue;
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

        TTIOWrittenRun *wr =
            [[TTIOWrittenRun alloc]
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

    // M89.2: build TTIOWrittenGenomicRun objects for each genomic
    // dataset_id. These travel through the extended writeMinimalToPath
    // overload alongside any MS runs.
    NSMutableDictionary<NSString *, TTIOWrittenGenomicRun *> *genomicRuns =
        [NSMutableDictionary dictionary];
    for (NSNumber *didKey in genomicData) {
        NSDictionary *meta = datasetMetas[didKey];
        NSMutableDictionary *gd = genomicData[didKey];
        NSString *instrumentJSON = meta[@"instrumentJSON"] ?: @"";
        NSString *referenceUri = @"";
        NSString *platform = @"";
        NSString *sampleName = @"";
        if (instrumentJSON.length > 0) {
            NSData *jdata = [instrumentJSON dataUsingEncoding:NSUTF8StringEncoding];
            id parsed = [NSJSONSerialization JSONObjectWithData:jdata options:0 error:NULL];
            if ([parsed isKindOfClass:[NSDictionary class]]) {
                NSDictionary *jd = parsed;
                referenceUri = [jd[@"reference_uri"] isKindOfClass:[NSString class]]
                    ? jd[@"reference_uri"] : @"";
                platform     = [jd[@"platform"] isKindOfClass:[NSString class]]
                    ? jd[@"platform"]     : @"";
                sampleName   = [jd[@"sample_name"] isKindOfClass:[NSString class]]
                    ? jd[@"sample_name"]   : @"";
            }
        }

        NSArray *posArr = gd[@"positions"];
        NSMutableData *positionsData = [NSMutableData dataWithCapacity:posArr.count * 8];
        for (NSNumber *n in posArr) {
            int64_t v = n.longLongValue;
            [positionsData appendBytes:&v length:8];
        }
        NSArray *mqArr = gd[@"mappingQualities"];
        NSMutableData *mqData = [NSMutableData dataWithCapacity:mqArr.count];
        for (NSNumber *n in mqArr) {
            uint8_t v = (uint8_t)n.unsignedCharValue;
            [mqData appendBytes:&v length:1];
        }
        NSArray *flagsArr = gd[@"flags"];
        NSMutableData *flagsData = [NSMutableData dataWithCapacity:flagsArr.count * 4];
        for (NSNumber *n in flagsArr) {
            uint32_t v = (uint32_t)n.unsignedIntValue;
            [flagsData appendBytes:&v length:4];
        }
        NSArray *offArr = gd[@"offsets"];
        NSMutableData *offsetsData = [NSMutableData dataWithCapacity:offArr.count * 8];
        for (NSNumber *n in offArr) {
            uint64_t v = n.unsignedLongLongValue;
            [offsetsData appendBytes:&v length:8];
        }
        NSArray *lenArr = gd[@"lengths"];
        NSMutableData *lengthsData = [NSMutableData dataWithCapacity:lenArr.count * 4];
        for (NSNumber *n in lenArr) {
            uint32_t v = n.unsignedIntValue;
            [lengthsData appendBytes:&v length:4];
        }

        // M90.9: compound fields ride on the wire as 3 string channels
        // + a 12-byte mate extension on the AU genomic suffix. The
        // accumulator captured them per-AU; materialise into the
        // run-level shapes the WrittenGenomicRun expects. M89.1-only
        // streams default to "" / -1 / 0 because the AU decoder
        // returns those defaults when the extension is absent.
        NSUInteger n = posArr.count;
        NSArray *cigarsCollected = gd[@"cigars"] ?: @[];
        NSArray *readNamesCollected = gd[@"readNames"] ?: @[];
        NSArray *mateChromsCollected = gd[@"mateChromosomes"] ?: @[];
        NSArray *matePositionsCollected = gd[@"matePositions"] ?: @[];
        NSArray *templateLengthsCollected = gd[@"templateLengths"] ?: @[];
        NSMutableArray *cigars = [NSMutableArray arrayWithCapacity:n];
        NSMutableArray *readNames = [NSMutableArray arrayWithCapacity:n];
        NSMutableArray *mateChroms = [NSMutableArray arrayWithCapacity:n];
        for (NSUInteger i = 0; i < n; i++) {
            [cigars addObject:(i < cigarsCollected.count
                                ? cigarsCollected[i] : @"")];
            [readNames addObject:(i < readNamesCollected.count
                                   ? readNamesCollected[i] : @"")];
            [mateChroms addObject:(i < mateChromsCollected.count
                                    ? mateChromsCollected[i] : @"")];
        }
        NSMutableData *matePosData = [NSMutableData dataWithLength:n * sizeof(int64_t)];
        int64_t *matePosBuf = (int64_t *)matePosData.mutableBytes;
        for (NSUInteger i = 0; i < n; i++) {
            matePosBuf[i] = i < matePositionsCollected.count
                ? [(NSNumber *)matePositionsCollected[i] longLongValue]
                : -1;
        }
        NSMutableData *tlenData = [NSMutableData dataWithLength:n * sizeof(int32_t)];
        int32_t *tlenBuf = (int32_t *)tlenData.mutableBytes;
        for (NSUInteger i = 0; i < n; i++) {
            tlenBuf[i] = i < templateLengthsCollected.count
                ? (int32_t)[(NSNumber *)templateLengthsCollected[i] intValue]
                : 0;
        }

        TTIOWrittenGenomicRun *wgr = [[TTIOWrittenGenomicRun alloc]
            initWithAcquisitionMode:(TTIOAcquisitionMode)((NSNumber *)meta[@"acquisitionMode"]).unsignedIntegerValue
                       referenceUri:referenceUri
                           platform:platform
                         sampleName:sampleName
                          positions:positionsData
                   mappingQualities:mqData
                              flags:flagsData
                          sequences:[gd[@"sequences"] copy]
                          qualities:[gd[@"qualities"] copy]
                            offsets:offsetsData
                            lengths:lengthsData
                             cigars:cigars
                          readNames:readNames
                    mateChromosomes:mateChroms
                      matePositions:matePosData
                    templateLengths:tlenData
                        chromosomes:[gd[@"chromosomes"] copy]
                  signalCompression:TTIOCompressionNone];
        genomicRuns[(NSString *)meta[@"name"]] = wgr;
    }

    return [TTIOSpectralDataset writeMinimalToPath:outputPath
                                              title:title
                                 isaInvestigationId:isa
                                             msRuns:runs
                                        genomicRuns:(genomicRuns.count ? genomicRuns : nil)
                                    identifications:nil
                                    quantifications:nil
                                  provenanceRecords:nil
                                              error:error];
}

@end
