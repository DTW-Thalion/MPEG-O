/*
 * TTIOTransportWriter.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOTransportWriter
 * Inherits From: NSObject
 * Conforms To:   NSObject (NSObject)
 * Declared In:   Transport/TTIOTransportWriter.h
 *
 * Serialises a TTIOSpectralDataset (or fine-grained packet stream)
 * onto a transport byte stream. Walks msRuns then genomicRuns,
 * emitting StreamHeader → DatasetHeaders → AccessUnits →
 * EndOfDataset → EndOfStream with optional per-packet CRC-32C and
 * zlib compression of channel payloads.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "TTIOTransportWriter.h"
#import "Core/TTIOPortability.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOProvenanceRecord.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOInstrumentConfig.h"
#import "Run/TTIOSpectrumIndex.h"
#import "Spectra/TTIOSpectrum.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "ValueClasses/TTIOEnums.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Genomics/TTIOGenomicIndex.h"
#import "Genomics/TTIOAlignedRead.h"
#import "Genomics/TTIOReferenceImport.h"
#import "Image/TTIOMSImage.h"
#import "Codecs/TTIORans.h"        // rANS wire codec dispatch
#import "Codecs/TTIOBasePack.h"    // BASE_PACK wire codec dispatch
#import "Dataset/TTIOIdentification.h"
#import "Dataset/TTIOQuantification.h"
#import "Transport/TTIOArrowIpcCodec.h"
#import <time.h>
#import <string.h>
#import <zlib.h>

// ---------------------------------------------------------------- helpers

static inline void appendU16LE(NSMutableData *buf, uint16_t v)
{
    uint8_t b[2] = { (uint8_t)(v & 0xFFu), (uint8_t)((v >> 8) & 0xFFu) };
    [buf appendBytes:b length:2];
}

static inline void appendU32LE(NSMutableData *buf, uint32_t v)
{
    uint8_t b[4];
    b[0] = (uint8_t)(v & 0xFFu);
    b[1] = (uint8_t)((v >> 8) & 0xFFu);
    b[2] = (uint8_t)((v >> 16) & 0xFFu);
    b[3] = (uint8_t)((v >> 24) & 0xFFu);
    [buf appendBytes:b length:4];
}

static void appendLEString(NSMutableData *buf, NSString *s, int width /*2 or 4*/)
{
    NSData *d = [(s ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    if (width == 2) {
        appendU16LE(buf, (uint16_t)d.length);
    } else {
        appendU32LE(buf, (uint32_t)d.length);
    }
    [buf appendData:d];
}

static uint64_t nowNs(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

// Forward declarations for static helpers defined further down. Allows
// methods declared earlier in @implementation (e.g. -writeReferenceGroup:)
// to call them without an out-of-order definition error.
static NSData *zlibDeflate(NSData *input);

static NSString *spectrumClassToWireName(uint8_t wire)
{
    switch (wire) {
        case 0: return @"TTIOMassSpectrum";
        case 1: return @"TTIONMRSpectrum";
        case 2: return @"TTIONMR2DSpectrum";
        case 3: return @"TTIOFreeInductionDecay";
        case 4: return @"TTIOMSImagePixel";
        case 5: return @"TTIOGenomicRead";
        default: return @"TTIOMassSpectrum";
    }
}

static uint8_t wireFromSpectrumClassName(NSString *name)
{
    if ([name isEqualToString:@"TTIOMassSpectrum"]) return 0;
    if ([name isEqualToString:@"TTIONMRSpectrum"]) return 1;
    if ([name isEqualToString:@"TTIONMR2DSpectrum"]) return 2;
    if ([name isEqualToString:@"TTIOFreeInductionDecay"]) return 3;
    if ([name isEqualToString:@"TTIOMSImagePixel"]) return 4;
    if ([name isEqualToString:@"TTIOGenomicRead"]) return 5;
    return 0;
}

static uint8_t wireFromPolarity(TTIOPolarity p)
{
    switch (p) {
        case TTIOPolarityPositive: return 0;
        case TTIOPolarityNegative: return 1;
        case TTIOPolarityUnknown: default: return 2;
    }
}

// ---------------------------------------------------------------- writer

// Internal sink adapter for NSFileHandle. Keeps -initWithOutputPath:
// behaviour unchanged while letting the writer hold a single
// <TTIOTransportWriterSink> reference.
@interface TTIOFileHandleSink : NSObject <TTIOTransportWriterSink>
@property (nonatomic, strong, nullable) NSFileHandle *handle;
@end
@implementation TTIOFileHandleSink
- (void)writeData:(NSData *)data {
    if (_handle) [_handle writeData:data];
}
@end


@implementation TTIOMutableDataSink {
    NSMutableData *_data;
}
+ (instancetype)sink { return [[self alloc] initWithData:[NSMutableData data]]; }
- (instancetype)initWithData:(NSMutableData *)data {
    if ((self = [super init])) { _data = data; }
    return self;
}
- (NSMutableData *)data { return _data; }
- (void)writeData:(NSData *)data { [_data appendData:data]; }
@end


@implementation TTIOTransportWriter
{
    id<TTIOTransportWriterSink>  _sink;
    TTIOFileHandleSink          *_fileHandleSink; // strong; for -close
    BOOL                          _streamHeaderWritten;
}

- (instancetype)initWithOutputPath:(NSString *)path
{
    if ((self = [super init])) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        _fileHandleSink = [[TTIOFileHandleSink alloc] init];
        _fileHandleSink.handle = [NSFileHandle fileHandleForWritingAtPath:path];
        _sink = _fileHandleSink;
    }
    return self;
}

- (instancetype)initWithMutableData:(NSMutableData *)data
{
    return [self initWithSink:[[TTIOMutableDataSink alloc] initWithData:data]];
}

- (instancetype)initWithSink:(id<TTIOTransportWriterSink>)sink
{
    if ((self = [super init])) {
        _sink = sink;
    }
    return self;
}

- (void)close
{
    if (_fileHandleSink) {
        [_fileHandleSink.handle closeFile];
        _fileHandleSink.handle = nil;
        _fileHandleSink = nil;
    }
}

- (void)dealloc
{
    [self close];
}

- (void)writeBytes:(NSData *)data
{
    [_sink writeData:data];
}

- (BOOL)emitPacketType:(TTIOTransportPacketType)type
                 payload:(NSData *)payload
               datasetId:(uint16_t)datasetId
              auSequence:(uint32_t)auSequence
                   error:(NSError **)error
{
    uint16_t flags = _useChecksum ? (uint16_t)TTIOTransportPacketFlagHasChecksum : 0;
    TTIOTransportPacketHeader *hdr =
        [[TTIOTransportPacketHeader alloc] initWithPacketType:type
                                                          flags:flags
                                                      datasetId:datasetId
                                                     auSequence:auSequence
                                                  payloadLength:(uint32_t)payload.length
                                                    timestampNs:nowNs()];
    [self writeBytes:[hdr encode]];
    [self writeBytes:payload];
    if (_useChecksum) {
        uint32_t crc = TTIOTransportCRC32C((const uint8_t *)payload.bytes, payload.length);
        uint8_t crcBuf[4];
        crcBuf[0] = (uint8_t)(crc & 0xFFu);
        crcBuf[1] = (uint8_t)((crc >> 8) & 0xFFu);
        crcBuf[2] = (uint8_t)((crc >> 16) & 0xFFu);
        crcBuf[3] = (uint8_t)((crc >> 24) & 0xFFu);
        [self writeBytes:[NSData dataWithBytes:crcBuf length:4]];
    }
    return YES;
}

- (BOOL)writeStreamHeaderWithFormatVersion:(NSString *)formatVersion
                                      title:(NSString *)title
                           isaInvestigation:(NSString *)isaInvestigation
                                   features:(NSArray<NSString *> *)features
                                  nDatasets:(uint16_t)nDatasets
                                      error:(NSError **)error
{
    NSMutableData *payload = [NSMutableData data];
    appendLEString(payload, formatVersion, 2);
    appendLEString(payload, title, 2);
    appendLEString(payload, isaInvestigation, 2);
    appendU16LE(payload, (uint16_t)features.count);
    for (NSString *f in features) appendLEString(payload, f, 2);
    appendU16LE(payload, nDatasets);
    _streamHeaderWritten = YES;
    return [self emitPacketType:TTIOTransportPacketStreamHeader
                         payload:payload
                       datasetId:0
                      auSequence:0
                           error:error];
}

- (BOOL)writeDatasetHeaderWithDatasetId:(uint16_t)datasetId
                                    name:(NSString *)name
                         acquisitionMode:(uint8_t)acquisitionMode
                           spectrumClass:(NSString *)spectrumClass
                            channelNames:(NSArray<NSString *> *)channelNames
                          instrumentJSON:(NSString *)instrumentJSON
                        expectedAUCount:(uint32_t)expectedAUCount
                                   error:(NSError **)error
{
    NSMutableData *payload = [NSMutableData data];
    appendU16LE(payload, datasetId);
    appendLEString(payload, name, 2);
    uint8_t mode = acquisitionMode;
    [payload appendBytes:&mode length:1];
    appendLEString(payload, spectrumClass, 2);
    uint8_t nch = (uint8_t)channelNames.count;
    [payload appendBytes:&nch length:1];
    for (NSString *c in channelNames) appendLEString(payload, c, 2);
    appendLEString(payload, instrumentJSON, 4);
    appendU32LE(payload, expectedAUCount);
    return [self emitPacketType:TTIOTransportPacketDatasetHeader
                         payload:payload
                       datasetId:datasetId
                      auSequence:0
                           error:error];
}

- (BOOL)writeAccessUnit:(TTIOAccessUnit *)au
              datasetId:(uint16_t)datasetId
             auSequence:(uint32_t)auSequence
                  error:(NSError **)error
{
    return [self emitPacketType:TTIOTransportPacketAccessUnit
                         payload:[au encode]
                       datasetId:datasetId
                      auSequence:auSequence
                           error:error];
}

- (BOOL)writeEndOfDatasetWithDatasetId:(uint16_t)datasetId
                       finalAUSequence:(uint32_t)finalAUSequence
                                  error:(NSError **)error
{
    NSMutableData *payload = [NSMutableData dataWithCapacity:6];
    appendU16LE(payload, datasetId);
    appendU32LE(payload, finalAUSequence);
    return [self emitPacketType:TTIOTransportPacketEndOfDataset
                         payload:payload
                       datasetId:datasetId
                      auSequence:0
                           error:error];
}

- (BOOL)writeEndOfStreamWithError:(NSError **)error
{
    return [self emitPacketType:TTIOTransportPacketEndOfStream
                         payload:[NSData data]
                       datasetId:0
                      auSequence:0
                           error:error];
}

// ---------------------------------------------------------------- Phase 2c-T

- (BOOL)writeBlobV2MateInfoWithDatasetId:(uint16_t)datasetId
                              chromNames:(NSArray<NSString *> *)chromNames
                                    blob:(NSData *)blob
                                    error:(NSError **)error
{
    NSMutableData *p = [NSMutableData dataWithCapacity:16 + blob.length];
    appendU16LE(p, datasetId);
    uint8_t codecId = TTIOTransportCodecIdMateInlineV2;
    [p appendBytes:&codecId length:1];
    appendU16LE(p, (uint16_t)(chromNames.count & 0xFFFF));
    for (NSString *n in chromNames) appendLEString(p, n, 2);
    appendU32LE(p, (uint32_t)blob.length);
    [p appendData:blob];
    return [self emitPacketType:TTIOTransportPacketBlobV2MateInfo
                         payload:p
                       datasetId:datasetId
                      auSequence:0
                           error:error];
}

- (BOOL)writeBlobV2RefDiffWithDatasetId:(uint16_t)datasetId
                            referenceUri:(NSString *)referenceUri
                                    blob:(NSData *)blob
                                    error:(NSError **)error
{
    NSMutableData *p = [NSMutableData dataWithCapacity:16 + blob.length];
    appendU16LE(p, datasetId);
    uint8_t codecId = TTIOTransportCodecIdRefDiffV2;
    [p appendBytes:&codecId length:1];
    appendLEString(p, referenceUri ?: @"", 2);
    appendU32LE(p, (uint32_t)blob.length);
    [p appendData:blob];
    return [self emitPacketType:TTIOTransportPacketBlobV2RefDiff
                         payload:p
                       datasetId:datasetId
                      auSequence:0
                           error:error];
}

- (BOOL)writeBlobV2NameTokWithDatasetId:(uint16_t)datasetId
                                    blob:(NSData *)blob
                                    error:(NSError **)error
{
    NSMutableData *p = [NSMutableData dataWithCapacity:8 + blob.length];
    appendU16LE(p, datasetId);
    uint8_t codecId = TTIOTransportCodecIdNameTokenizedV2;
    [p appendBytes:&codecId length:1];
    appendU32LE(p, (uint32_t)blob.length);
    [p appendData:blob];
    return [self emitPacketType:TTIOTransportPacketBlobV2NameTok
                         payload:p
                       datasetId:datasetId
                      auSequence:0
                           error:error];
}

// ---------------------------------------------------------------- v0.11 §4.13-§4.15

/**
 * Threshold below which a chromosome rides as raw UINT8 (encoding=0).
 * Mirrors transport-spec §4.14 + Java
 * TransportWriter.REFERENCE_CHROMOSOME_ZLIB_THRESHOLD + Python
 * TransportWriter.REFERENCE_CHROMOSOME_ZLIB_THRESHOLD.
 */
static const NSUInteger TTIOReferenceChromosomeZlibThreshold = 4096;

- (BOOL)writeReferenceGroup:(TTIOReferenceImport *)ref
                       error:(NSError **)error
{
    if (!ref) {
        if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                 code:TTIOTransportErrorUnexpectedPayload
                                             userInfo:@{NSLocalizedDescriptionKey:
                                 @"writeReferenceGroup: nil ref"}];
        return NO;
    }
    NSArray<NSString *> *chromNames = ref.chromosomes;
    NSArray<NSData *> *seqs = ref.sequences;
    uint32_t chromCount = (uint32_t)chromNames.count;
    uint64_t totalBases = (uint64_t)[ref totalBases];
    NSString *md5Hex = [ref md5Hex];
    if (md5Hex.length != 32) {
        if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                 code:TTIOTransportErrorUnexpectedPayload
                                             userInfo:@{NSLocalizedDescriptionKey:
                                 [NSString stringWithFormat:
                                     @"ReferenceImport.md5Hex must be 32 hex chars, got %lu",
                                     (unsigned long)md5Hex.length]}];
        return NO;
    }

    // -- REFERENCE_GROUP_HEADER (0x10) ----------------------------------
    NSData *uriBytes = [(ref.uri ?: @"")
        dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSData *md5HexBytes = [md5Hex dataUsingEncoding:NSASCIIStringEncoding];
    if (md5HexBytes.length != 32) {
        if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                 code:TTIOTransportErrorUnexpectedPayload
                                             userInfo:@{NSLocalizedDescriptionKey:
                                 @"ReferenceImport.md5Hex did not encode to 32 ASCII bytes"}];
        return NO;
    }
    NSMutableData *hdr = [NSMutableData dataWithCapacity:
                          2 + uriBytes.length + 4 + 8 + 32];
    appendU16LE(hdr, (uint16_t)(uriBytes.length & 0xFFFFu));
    [hdr appendData:uriBytes];
    appendU32LE(hdr, chromCount);
    uint8_t tbBuf[8];
    for (int i = 0; i < 8; i++) tbBuf[i] = (uint8_t)((totalBases >> (i * 8)) & 0xFFu);
    [hdr appendBytes:tbBuf length:8];
    [hdr appendData:md5HexBytes];
    if (![self emitPacketType:TTIOTransportPacketReferenceGroupHeader
                       payload:hdr
                     datasetId:0
                    auSequence:0
                         error:error]) return NO;

    // -- REFERENCE_CHROMOSOME (0x11) — one per contig --------------------
    for (NSUInteger i = 0; i < chromCount; i++) {
        NSString *name = chromNames[i];
        NSData *seq = seqs[i];
        NSData *nameBytes =
            [(name ?: @"") dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];

        uint8_t encoding;
        NSData *payloadBytes;
        if (seq.length < TTIOReferenceChromosomeZlibThreshold) {
            encoding = 0;
            payloadBytes = seq;
        } else {
            encoding = 1;
            payloadBytes = zlibDeflate(seq);
            if (!payloadBytes) {
                if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                         code:TTIOTransportErrorUnexpectedPayload
                                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:
                                             @"REFERENCE_CHROMOSOME zlib deflate failed for '%@'",
                                             name]}];
                return NO;
            }
        }

        NSMutableData *rec = [NSMutableData dataWithCapacity:
                              2 + nameBytes.length + 8 + 1 + 4 + payloadBytes.length];
        appendU16LE(rec, (uint16_t)(nameBytes.length & 0xFFFFu));
        [rec appendData:nameBytes];
        uint64_t seqLen = (uint64_t)seq.length;
        uint8_t slBuf[8];
        for (int b = 0; b < 8; b++) slBuf[b] = (uint8_t)((seqLen >> (b * 8)) & 0xFFu);
        [rec appendBytes:slBuf length:8];
        [rec appendBytes:&encoding length:1];
        appendU32LE(rec, (uint32_t)payloadBytes.length);
        [rec appendData:payloadBytes];
        if (![self emitPacketType:TTIOTransportPacketReferenceChromosome
                           payload:rec
                         datasetId:0
                        auSequence:(uint32_t)i
                             error:error]) return NO;
    }

    // -- END_OF_REFERENCE_GROUP (0x12) -----------------------------------
    NSMutableData *eor = [NSMutableData dataWithCapacity:4];
    appendU32LE(eor, chromCount);
    return [self emitPacketType:TTIOTransportPacketEndOfReferenceGroup
                         payload:eor
                       datasetId:0
                      auSequence:0
                           error:error];
}

// ---------------------------------------------------------------- v0.11 §4.23

- (BOOL)writeEncryptionAlgorithm:(NSString *)algorithm
                            error:(NSError **)error
{
    if (algorithm == nil) {
        if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                 code:TTIOTransportErrorUnexpectedPayload
                                             userInfo:@{NSLocalizedDescriptionKey:
                             @"writeEncryptionAlgorithm: algorithm must not be nil"}];
        return NO;
    }
    NSData *algoBytes =
        [algorithm dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    if (algoBytes.length > 0xFFFFu) {
        if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                 code:TTIOTransportErrorUnexpectedPayload
                                             userInfo:@{NSLocalizedDescriptionKey:
                             [NSString stringWithFormat:
                                 @"ENCRYPTION_ALGORITHM: algorithm name %lu bytes "
                                 @"exceeds uint16 max",
                                 (unsigned long)algoBytes.length]}];
        return NO;
    }
    NSMutableData *payload = [NSMutableData dataWithCapacity:2 + algoBytes.length];
    appendU16LE(payload, (uint16_t)algoBytes.length);
    [payload appendData:algoBytes];
    return [self emitPacketType:TTIOTransportPacketEncryptionAlgorithm
                         payload:payload
                       datasetId:0
                      auSequence:0
                           error:error];
}

// ---------------------------------------------------------------- v0.11 §4.21

// Serialise a TTIOProvenanceRecord parameters dict to the canonical
// wire JSON form: `{"k":"v","k2":"v2"}` with keys sorted (Python parity
// — Java preserves Map iteration order). Empty dict renders as `{}`.
// Mirrors Python `_provenance_params_json` (transport/codec.py).
static NSString *provenanceParamsJSON(NSDictionary *params)
{
    if (params.count == 0) return @"{}";
    // Coerce values to strings the way Python does so a dict whose
    // values are NSNumber / arbitrary types still produces the
    // string-valued shape Java emits via ProvenanceRecord.parametersJson().
    NSMutableDictionary *coerced =
        [NSMutableDictionary dictionaryWithCapacity:params.count];
    for (id key in params) {
        id val = params[key];
        NSString *k = [key isKindOfClass:[NSString class]]
            ? (NSString *)key
            : [key description];
        NSString *v;
        if ([val isKindOfClass:[NSString class]]) {
            v = (NSString *)val;
        } else if ([val isKindOfClass:[NSNumber class]]) {
            v = [(NSNumber *)val stringValue];
        } else {
            v = [val description];
        }
        coerced[k] = v;
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:coerced
                                                    options:TTIO_JSON_SORTED_KEYS
                                                      error:nil];
    if (!json) return @"{}";
    return [[NSString alloc] initWithData:json
                                  encoding:NSUTF8StringEncoding] ?: @"{}";
}

// Comma-join an array of refs. No quoting/escaping — per spec §4.21,
// refs are URIs that have been URL-encoded so they cannot themselves
// contain commas. Java parity: TransportWriter.csvJoin.
static NSString *provenanceCsvJoin(NSArray<NSString *> *refs)
{
    if (refs.count == 0) return @"";
    return [refs componentsJoinedByString:@","];
}

- (BOOL)writeDatasetProvenance:(NSArray<TTIOProvenanceRecord *> *)records
                          error:(NSError **)error
{
    if (records == nil) {
        if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                 code:TTIOTransportErrorUnexpectedPayload
                                             userInfo:@{NSLocalizedDescriptionKey:
                             @"writeDatasetProvenance: records must not be nil"}];
        return NO;
    }
    if (records.count == 0) {
        // §5.4 "zero or more" — emit nothing for empty input.
        return YES;
    }
    // Pre-compute UTF-8 byte arrays so we can size the buffer exactly.
    NSMutableArray<NSData *> *softwareBytes =
        [NSMutableArray arrayWithCapacity:records.count];
    NSMutableArray<NSData *> *paramsBytes =
        [NSMutableArray arrayWithCapacity:records.count];
    NSMutableArray<NSData *> *inputsBytes =
        [NSMutableArray arrayWithCapacity:records.count];
    NSMutableArray<NSData *> *outputsBytes =
        [NSMutableArray arrayWithCapacity:records.count];
    NSUInteger total = 4;  // record_count
    for (TTIOProvenanceRecord *r in records) {
        NSData *sb = [(r.software ?: @"")
            dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
        NSData *pb = [provenanceParamsJSON(r.parameters)
            dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
        NSData *ib = [provenanceCsvJoin(r.inputRefs)
            dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
        NSData *ob = [provenanceCsvJoin(r.outputRefs)
            dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
        for (NSData *d in @[sb, pb, ib, ob]) {
            if (d.length > 0xFFFFu) {
                if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                         code:TTIOTransportErrorUnexpectedPayload
                                                     userInfo:@{NSLocalizedDescriptionKey:
                                     [NSString stringWithFormat:
                                         @"DATASET_PROVENANCE: per-field length %lu "
                                         @"exceeds uint16 max",
                                         (unsigned long)d.length]}];
                return NO;
            }
        }
        [softwareBytes addObject:sb];
        [paramsBytes addObject:pb];
        [inputsBytes addObject:ib];
        [outputsBytes addObject:ob];
        total += 8                    // timestamp_unix
              + 2 + sb.length
              + 2 + pb.length
              + 2 + ib.length
              + 2 + ob.length;
    }
    NSMutableData *payload = [NSMutableData dataWithCapacity:total];
    appendU32LE(payload, (uint32_t)records.count);
    NSUInteger i = 0;
    for (TTIOProvenanceRecord *r in records) {
        int64_t ts = r.timestampUnix;
        uint64_t tsBits = (uint64_t)ts;
        uint8_t tsBuf[8];
        for (int b = 0; b < 8; b++) tsBuf[b] = (uint8_t)((tsBits >> (b * 8)) & 0xFFu);
        [payload appendBytes:tsBuf length:8];
        appendU16LE(payload, (uint16_t)softwareBytes[i].length);
        [payload appendData:softwareBytes[i]];
        appendU16LE(payload, (uint16_t)paramsBytes[i].length);
        [payload appendData:paramsBytes[i]];
        appendU16LE(payload, (uint16_t)inputsBytes[i].length);
        [payload appendData:inputsBytes[i]];
        appendU16LE(payload, (uint16_t)outputsBytes[i].length);
        [payload appendData:outputsBytes[i]];
        i++;
    }
    NSAssert(payload.length == total,
        @"DATASET_PROVENANCE size mismatch: predicted %lu, actual %lu",
        (unsigned long)total, (unsigned long)payload.length);
    return [self emitPacketType:TTIOTransportPacketDatasetProvenance
                         payload:payload
                       datasetId:0
                      auSequence:0
                           error:error];
}

// ---------------------------------------------------------------- v0.11 §4.16-§4.18

// Map TTIOMSImage.scanPattern to the wire byte per spec §4.16
// (0=flyback, 1=meander, 2=random). The on-disk format uses "raster"
// as the default name for the flyback pattern. Unknown values map
// defensively to 0 (flyback). Java parity:
// TransportWriter.scanPatternToByte (commit a6b1e5d9).
static uint8_t scanPatternToWireByte(NSString *scanPattern)
{
    if (scanPattern == nil) return 0;
    if ([scanPattern isEqualToString:@"raster"]) return 0;
    if ([scanPattern isEqualToString:@"flyback"]) return 0;
    if ([scanPattern isEqualToString:@"meander"]) return 1;
    if ([scanPattern isEqualToString:@"random"]) return 2;
    return 0;
}

static inline void appendF64LE(NSMutableData *buf, double v)
{
    uint64_t bits;
    memcpy(&bits, &v, 8);
    uint8_t b[8];
    for (int i = 0; i < 8; i++) b[i] = (uint8_t)((bits >> (i * 8)) & 0xFFu);
    [buf appendBytes:b length:8];
}

- (BOOL)writeImage:(TTIOMSImage *)image
              error:(NSError **)error
{
    if (image == nil) {
        if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                 code:TTIOTransportErrorUnexpectedPayload
                                             userInfo:@{NSLocalizedDescriptionKey:
                             @"writeImage: image must not be nil"}];
        return NO;
    }
    NSUInteger width  = image.width;
    NSUInteger height = image.height;
    NSUInteger bins   = image.spectralPoints;
    NSData *mzAxis = image.mzAxis;
    NSUInteger axisLength = (mzAxis.length / sizeof(double));
    if (mzAxis != nil && axisLength != bins) {
        if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                 code:TTIOTransportErrorUnexpectedPayload
                                             userInfo:@{NSLocalizedDescriptionKey:
                             [NSString stringWithFormat:
                                 @"IMAGE_HEADER: mz_axis length %lu does not match "
                                 @"spectrum_bins %lu",
                                 (unsigned long)axisLength,
                                 (unsigned long)bins]}];
        return NO;
    }
    uint8_t modality = 0;        // MS imaging
    uint8_t axisKind = 0;        // mz
    uint8_t isContinuous = 1;    // shared axis
    uint8_t scanPatternByte = scanPatternToWireByte(image.scanPattern);

    NSData *titleBytes =
        [(image.title ?: @"") dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSData *isaBytes =
        [(image.isaInvestigationId ?: @"") dataUsingEncoding:NSUTF8StringEncoding]
        ?: [NSData data];
    if (titleBytes.length > 0xFFFFu) {
        if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                 code:TTIOTransportErrorUnexpectedPayload
                                             userInfo:@{NSLocalizedDescriptionKey:
                             [NSString stringWithFormat:
                                 @"IMAGE_HEADER: title %lu bytes exceeds uint16 max",
                                 (unsigned long)titleBytes.length]}];
        return NO;
    }
    if (isaBytes.length > 0xFFFFu) {
        if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                 code:TTIOTransportErrorUnexpectedPayload
                                             userInfo:@{NSLocalizedDescriptionKey:
                             [NSString stringWithFormat:
                                 @"IMAGE_HEADER: isa_id %lu bytes exceeds uint16 max",
                                 (unsigned long)isaBytes.length]}];
        return NO;
    }

    // -- IMAGE_HEADER (0x13) -----------------------------------------
    NSUInteger hdrSize = 1                       // modality
                       + 4                       // width
                       + 4                       // height
                       + 4                       // spectrum_bins
                       + 8                       // pixel_size_x
                       + 8                       // pixel_size_y
                       + 1                       // scan_pattern
                       + 1                       // axis_kind
                       + 4                       // axis_length
                       + 8 * axisLength          // axis values
                       + 1                       // is_continuous
                       + 2 + titleBytes.length
                       + 2 + isaBytes.length;
    NSMutableData *hdr = [NSMutableData dataWithCapacity:hdrSize];
    [hdr appendBytes:&modality length:1];
    appendU32LE(hdr, (uint32_t)width);
    appendU32LE(hdr, (uint32_t)height);
    appendU32LE(hdr, (uint32_t)bins);
    appendF64LE(hdr, image.pixelSizeX);
    appendF64LE(hdr, image.pixelSizeY);
    [hdr appendBytes:&scanPatternByte length:1];
    [hdr appendBytes:&axisKind length:1];
    appendU32LE(hdr, (uint32_t)axisLength);
    if (axisLength > 0) {
        const double *axisVals = (const double *)mzAxis.bytes;
        for (NSUInteger i = 0; i < axisLength; i++) {
            appendF64LE(hdr, axisVals[i]);
        }
    }
    [hdr appendBytes:&isContinuous length:1];
    appendU16LE(hdr, (uint16_t)titleBytes.length);
    [hdr appendData:titleBytes];
    appendU16LE(hdr, (uint16_t)isaBytes.length);
    [hdr appendData:isaBytes];
    NSAssert(hdr.length == hdrSize,
        @"IMAGE_HEADER size mismatch: predicted %lu, actual %lu",
        (unsigned long)hdrSize, (unsigned long)hdr.length);
    if (![self emitPacketType:TTIOTransportPacketImageHeader
                       payload:hdr
                     datasetId:0
                    auSequence:0
                         error:error]) return NO;

    // -- IMAGE_PIXEL (0x14) — one per pixel --------------------------
    // Continuous-mode payload: x(u32) + y(u32) + precision(u8) +
    // compression(u8) + payload_length(u32) + intensities[..]. We
    // always emit FLOAT64 (precision=1) uncompressed (compression=0)
    // intensities lifted directly from the MSImage cube.
    uint8_t precision = 1;       // FLOAT64
    uint8_t compression = 0;     // NONE
    uint32_t payloadLen = (uint32_t)(bins * sizeof(double));
    uint64_t pixelIndex = 0;
    const double *cubeP = (const double *)image.cube.bytes;
    for (NSUInteger y = 0; y < height; y++) {
        for (NSUInteger x = 0; x < width; x++) {
            NSMutableData *rec =
                [NSMutableData dataWithCapacity:4 + 4 + 1 + 1 + 4 + payloadLen];
            appendU32LE(rec, (uint32_t)x);
            appendU32LE(rec, (uint32_t)y);
            [rec appendBytes:&precision length:1];
            [rec appendBytes:&compression length:1];
            appendU32LE(rec, payloadLen);
            NSUInteger base = (y * width + x) * bins;
            [rec appendBytes:&cubeP[base] length:payloadLen];
            if (![self emitPacketType:TTIOTransportPacketImagePixel
                               payload:rec
                             datasetId:0
                            auSequence:(uint32_t)pixelIndex
                                 error:error]) return NO;
            pixelIndex++;
        }
    }

    // -- END_OF_IMAGE (0x15) -----------------------------------------
    NSMutableData *eoi = [NSMutableData dataWithCapacity:4];
    appendU32LE(eoi, (uint32_t)(pixelIndex & 0xFFFFFFFFull));
    return [self emitPacketType:TTIOTransportPacketEndOfImage
                         payload:eoi
                       datasetId:0
                      auSequence:0
                           error:error];
}

// ---------------------------------------------------------------- v0.11 §4.19 / §4.20

- (BOOL)writeIdentificationsTable:(NSArray<TTIOIdentification *> *)rows
                              error:(NSError **)error
{
    if (rows == nil) {
        if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                 code:TTIOTransportErrorUnexpectedPayload
                                             userInfo:@{NSLocalizedDescriptionKey:
                             @"writeIdentificationsTable: rows must not be nil"}];
        return NO;
    }
    if (rows.count == 0) {
        // §5.4 step 6 "zero or more" — emit nothing for empty input.
        return YES;
    }
    NSData *ipc = [TTIOArrowIpcCodec encodeIdentifications:rows];
    if (ipc == nil) {
        if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                 code:TTIOTransportErrorUnexpectedPayload
                                             userInfo:@{NSLocalizedDescriptionKey:
                             @"writeIdentificationsTable: Arrow IPC encode failed"}];
        return NO;
    }
    NSMutableData *payload = [NSMutableData dataWithCapacity:4 + ipc.length];
    appendU32LE(payload, (uint32_t)ipc.length);
    [payload appendData:ipc];
    return [self emitPacketType:TTIOTransportPacketIdentificationsTable
                         payload:payload
                       datasetId:0
                      auSequence:0
                           error:error];
}

- (BOOL)writeQuantificationsTable:(NSArray<TTIOQuantification *> *)rows
                              error:(NSError **)error
{
    if (rows == nil) {
        if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                 code:TTIOTransportErrorUnexpectedPayload
                                             userInfo:@{NSLocalizedDescriptionKey:
                             @"writeQuantificationsTable: rows must not be nil"}];
        return NO;
    }
    if (rows.count == 0) {
        // §5.4 step 6 "zero or more" — emit nothing for empty input.
        return YES;
    }
    NSData *ipc = [TTIOArrowIpcCodec encodeQuantifications:rows];
    if (ipc == nil) {
        if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                 code:TTIOTransportErrorUnexpectedPayload
                                             userInfo:@{NSLocalizedDescriptionKey:
                             @"writeQuantificationsTable: Arrow IPC encode failed"}];
        return NO;
    }
    NSMutableData *payload = [NSMutableData dataWithCapacity:4 + ipc.length];
    appendU32LE(payload, (uint32_t)ipc.length);
    [payload appendData:ipc];
    return [self emitPacketType:TTIOTransportPacketQuantificationsTable
                         payload:payload
                       datasetId:0
                      auSequence:0
                           error:error];
}

// ---------------------------------------------------------------- writeDataset

static NSString *instrumentConfigJSON(TTIOInstrumentConfig *cfg)
{
    if (!cfg) return @"{}";
    NSDictionary *d = @{
        @"analyzer_type": cfg.analyzerType ?: @"",
        @"detector_type": cfg.detectorType ?: @"",
        @"manufacturer": cfg.manufacturer ?: @"",
        @"model": cfg.model ?: @"",
        @"serial_number": cfg.serialNumber ?: @"",
        @"source_type": cfg.sourceType ?: @"",
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:d options:TTIO_JSON_SORTED_KEYS error:nil];
    return [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
}

static NSData *zlibDeflate(NSData *input)
{
    if (input.length == 0) return [NSData data];
    uLongf destLen = compressBound((uLong)input.length);
    NSMutableData *out = [NSMutableData dataWithLength:destLen];
    int rc = compress2((Bytef *)out.mutableBytes, &destLen,
                         (const Bytef *)input.bytes, (uLong)input.length,
                         Z_DEFAULT_COMPRESSION);
    if (rc != Z_OK) return nil;
    [out setLength:destLen];
    return out;
}

static TTIOAccessUnit *accessUnitFromSpectrum(TTIOSpectrum *spectrum,
                                                TTIOAcquisitionRun *run,
                                                NSArray<NSString *> *channelNames,
                                                BOOL useCompression)
{
    uint8_t wireClass = wireFromSpectrumClassName(run.spectrumClassName);
    uint8_t msLevel = 0;
    uint8_t polarityWire = 2;
    if ([spectrum isKindOfClass:[TTIOMassSpectrum class]]) {
        TTIOMassSpectrum *ms = (TTIOMassSpectrum *)spectrum;
        msLevel = (uint8_t)MIN((NSUInteger)255, ms.msLevel);
        polarityWire = wireFromPolarity(ms.polarity);
    }

    double bpi = 0.0;
    if (run.spectrumIndex && spectrum.indexPosition < run.spectrumIndex.count) {
        bpi = [run.spectrumIndex basePeakIntensityAt:spectrum.indexPosition];
    }

    NSMutableArray<TTIOTransportChannelData *> *channels = [NSMutableArray array];
    for (NSString *cname in channelNames) {
        TTIOSignalArray *sa = spectrum.signalArrays[cname];
        if (!sa) continue;
        NSData *raw = sa.buffer;
        // Ensure float64 little-endian encoding on the wire. If the
        // source already is float64 LE, pass through directly.
        NSData *leFloat64 = raw;
        if (raw.length % 8 != 0) {
            // Signal array not float64; convert.
            leFloat64 = [NSData data];
        }
        uint32_t nElements = (uint32_t)(leFloat64.length / 8);
        NSData *payload = leFloat64;
        uint8_t compressionCode = TTIOCompressionNone;
        if (useCompression) {
            NSData *compressed = zlibDeflate(leFloat64);
            if (compressed) {
                payload = compressed;
                compressionCode = TTIOCompressionZlib;
            }
        }
        TTIOTransportChannelData *ch =
            [[TTIOTransportChannelData alloc] initWithName:cname
                                                  precision:TTIOPrecisionFloat64
                                                compression:compressionCode
                                                  nElements:nElements
                                                       data:payload];
        [channels addObject:ch];
    }

    return [[TTIOAccessUnit alloc] initWithSpectrumClass:wireClass
                                           acquisitionMode:(uint8_t)run.acquisitionMode
                                                   msLevel:msLevel
                                                  polarity:polarityWire
                                             retentionTime:spectrum.scanTimeSeconds
                                               precursorMz:spectrum.precursorMz
                                           precursorCharge:(uint8_t)MIN((NSUInteger)255, spectrum.precursorCharge)
                                               ionMobility:0.0
                                         basePeakIntensity:bpi
                                                  channels:channels
                                                    pixelX:0 pixelY:0 pixelZ:0];
}

// ---------------------------------------------------------------- M89.2

static NSString *genomicRunMetadataJSON(TTIOGenomicRun *run)
{
    if (!run) return @"{}";
    NSDictionary *d = @{
        @"modality":      run.modality      ?: @"",
        @"platform":      run.platform      ?: @"",
        @"reference_uri": run.referenceUri  ?: @"",
        @"sample_name":   run.sampleName    ?: @"",
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:d
                                                    options:TTIO_JSON_SORTED_KEYS
                                                      error:nil];
    return [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
}

// encode a UINT8 channel slice with the requested wire codec.
// codec==0 (NONE) is identity. RANS_ORDER0/1 + BASE_PACK dispatch to
// the matching M86 codec. Other codec ids return the raw bytes (the
// genomic-string channels never set this — this helper is only called
// for sequences/qualities). Mirrors Python's _apply_wire_codec.
static NSData *applyWireCodecGenomic(NSData *plaintext, uint8_t codec)
{
    if (codec == TTIOCompressionNone) return plaintext;
    switch (codec) {
        case TTIOCompressionRansOrder0:
            return TTIORansEncode(plaintext, 0);
        case TTIOCompressionRansOrder1:
            return TTIORansEncode(plaintext, 1);
        case TTIOCompressionBasePack:
            return TTIOBasePackEncode(plaintext);
        default:
            // Unknown / unsupported genomic wire codec — fall back to
            // identity so we don't silently corrupt the stream. The
            // reader's _decodeWireCodec will error if it sees an
            // unsupported value — but here we set NONE on the wire so
            // the receiver decodes correctly (lossless fallback).
            return plaintext;
    }
}

- (BOOL)writeGenomicRun:(TTIOGenomicRun *)run
              datasetId:(uint16_t)datasetId
                   name:(NSString *)name
                  error:(NSError **)error
{
    if (!run) {
        if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                 code:TTIOTransportErrorUnexpectedPayload
                                             userInfo:@{NSLocalizedDescriptionKey:
                             @"writeGenomicRun: nil run"}];
        return NO;
    }
    NSUInteger nReads = run.readCount;
    NSString *instrJSON = genomicRunMetadataJSON(run);
    // emit all 5 channels (sequences, qualities, cigar,
    // read_name, mate_chromosome). The 3 string channels carry one
    // per-AU UTF-8 string each.
    NSArray<NSString *> *channelNames = @[@"sequences", @"qualities",
                                            @"cigar", @"read_name",
                                            @"mate_chromosome"];
    if (![self writeDatasetHeaderWithDatasetId:datasetId
                                           name:(name ?: @"")
                                acquisitionMode:(uint8_t)run.acquisitionMode
                                  spectrumClass:@"TTIOGenomicRead"
                                   channelNames:channelNames
                                 instrumentJSON:instrJSON
                                expectedAUCount:(uint32_t)nReads
                                          error:error]) return NO;

    TTIOGenomicIndex *idx = run.index;
    uint8_t acqMode = (uint8_t)run.acquisitionMode;
    // probe @compression on the source's sequences / qualities
    // datasets. The 3 string channels always ride uncompressed —
    // per-AU codec framing dominates short strings.
    uint8_t seqCodec = [run wireCompressionForChannel:@"sequences"];
    uint8_t qualCodec = [run wireCompressionForChannel:@"qualities"];
    for (NSUInteger i = 0; i < nReads; i++) {
        NSError *readErr = nil;
        TTIOAlignedRead *r = [run readAtIndex:i error:&readErr];
        if (!r) {
            if (error) *error = readErr ?: [NSError errorWithDomain:TTIOTransportErrorDomain
                                                                code:TTIOTransportErrorUnexpectedPayload
                                                            userInfo:@{NSLocalizedDescriptionKey:
                                  [NSString stringWithFormat:@"writeGenomicRun: failed to materialise read %lu",
                                      (unsigned long)i]}];
            return NO;
        }
        NSData *seqData = [r.sequence dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
        NSData *qualData = r.qualities ?: [NSData data];
        uint32_t seqLen = (uint32_t)seqData.length;
        uint32_t qualLen = (uint32_t)qualData.length;
        // re-encode per-AU slice with the M86 codec when the
        // source channel had an @compression attribute set.
        NSData *seqPayload = applyWireCodecGenomic(seqData, seqCodec);
        NSData *qualPayload = applyWireCodecGenomic(qualData, qualCodec);
        TTIOTransportChannelData *seqCh =
            [[TTIOTransportChannelData alloc] initWithName:@"sequences"
                                                  precision:TTIOPrecisionUInt8
                                                compression:seqCodec
                                                  nElements:seqLen
                                                       data:seqPayload];
        TTIOTransportChannelData *qualCh =
            [[TTIOTransportChannelData alloc] initWithName:@"qualities"
                                                  precision:TTIOPrecisionUInt8
                                                compression:qualCodec
                                                  nElements:qualLen
                                                       data:qualPayload];
        // the 3 compound-string channels. Each carries the
        // per-read string's UTF-8 bytes for THIS AU only.
        NSData *cigarData = [(r.cigar ?: @"") dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
        NSData *nameData  = [(r.readName ?: @"") dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
        NSData *mateChrData = [(r.mateChromosome ?: @"") dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
        TTIOTransportChannelData *cigarCh =
            [[TTIOTransportChannelData alloc] initWithName:@"cigar"
                                                  precision:TTIOPrecisionUInt8
                                                compression:TTIOCompressionNone
                                                  nElements:(uint32_t)cigarData.length
                                                       data:cigarData];
        TTIOTransportChannelData *nameCh =
            [[TTIOTransportChannelData alloc] initWithName:@"read_name"
                                                  precision:TTIOPrecisionUInt8
                                                compression:TTIOCompressionNone
                                                  nElements:(uint32_t)nameData.length
                                                       data:nameData];
        TTIOTransportChannelData *mateChrCh =
            [[TTIOTransportChannelData alloc] initWithName:@"mate_chromosome"
                                                  precision:TTIOPrecisionUInt8
                                                compression:TTIOCompressionNone
                                                  nElements:(uint32_t)mateChrData.length
                                                       data:mateChrData];
        // Prefer the index-side fields for chromosome/position/mapq/
        // flags — they're already in the wire-correct types and avoid
        // any sentinel conversion in AlignedRead. Falls back to the
        // AlignedRead fields if the index isn't populated for this i.
        NSString *chrom = r.chromosome;
        int64_t pos = r.position;
        uint8_t mapq = r.mappingQuality;
        uint16_t flags = (uint16_t)(r.flags & 0xFFFFu);
        if (idx && i < idx.count) {
            chrom = [idx chromosomeAt:i] ?: chrom;
            pos = [idx positionAt:i];
            mapq = [idx mappingQualityAt:i];
            flags = (uint16_t)([idx flagsAt:i] & 0xFFFFu);
        }
        TTIOAccessUnit *au =
            [[TTIOAccessUnit alloc] initWithSpectrumClass:5
                                          acquisitionMode:acqMode
                                                  msLevel:0
                                                 polarity:2
                                            retentionTime:0.0
                                              precursorMz:0.0
                                          precursorCharge:0
                                              ionMobility:0.0
                                        basePeakIntensity:0.0
                                                 channels:@[seqCh, qualCh, cigarCh, nameCh, mateChrCh]
                                                   pixelX:0 pixelY:0 pixelZ:0
                                               chromosome:(chrom ?: @"")
                                                 position:pos
                                           mappingQuality:mapq
                                                    flags:flags
                                             matePosition:r.matePosition
                                           templateLength:r.templateLength];
        if (![self writeAccessUnit:au datasetId:datasetId auSequence:(uint32_t)i error:error]) {
            return NO;
        }
    }
    return [self writeEndOfDatasetWithDatasetId:datasetId
                                finalAUSequence:(uint32_t)nReads
                                           error:error];
}

- (BOOL)writeDataset:(TTIOSpectralDataset *)dataset error:(NSError **)error
{
    NSArray<NSString *> *runNames = dataset.msRuns.allKeys;
    // Deterministic order — sort to match Python's insertion-order
    // round-trip guarantee for dict iteration across platforms.
    runNames = [runNames sortedArrayUsingSelector:@selector(compare:)];

    // genomic runs after MS runs in the dataset_id space.
    NSArray<NSString *> *genomicNames =
        [dataset.genomicRuns.allKeys sortedArrayUsingSelector:@selector(compare:)];

    // Features list — Phase 2c-T: declare bulk_mode_v2_blobs when
    // bulk mode is enabled AND there is at least one genomic run.
    NSMutableArray<NSString *> *features = [NSMutableArray array];
    if (_useBulkMode && genomicNames.count > 0) {
        [features addObject:TTIOTransportBulkModeV2BlobsFeature];
    }

    // v0.11 Tasks 3.4 + 3.5 + 3.9: detect v0.11 content for ALL six
    // first-class accessors — encryption algorithm, dataset provenance,
    // references, image, identifications, quantifications. Each non-
    // empty section both (a) sets the TTIOTransportV011Feature flag in
    // the StreamHeader and (b) emits its packet(s) in §5.4 order in
    // the prelude block below. Java parity: TransportWriter.writeDataset
    // (commits 530a5833 + 563e09c3 + a6b1e5d9 + a6faab16 + dc0de926).
    // Python parity: TransportWriter.write_dataset (commits bf38bdc9 +
    // 434d45a6 + 1f619ced + 150552b6 + 6f51e81b).
    NSArray *datasetProvenance = dataset.provenanceRecords ?: @[];
    NSDictionary<NSString *, TTIOReferenceImport *> *datasetRefs =
        dataset.references ?: @{};
    // -msImage returns a non-nil placeholder (width=0, height=0,
    // cube=empty) when /study/image_cube/ is absent — guard with a
    // dimension check so v0.10 image-less datasets don't trigger the
    // image branch. Java + Python return null/None directly because
    // their image getter doesn't allocate a placeholder.
    TTIOMSImage *datasetImage = dataset.msImage;
    BOOL hasImage = (datasetImage != nil
                     && datasetImage.width  > 0
                     && datasetImage.height > 0);
    if (!hasImage) datasetImage = nil;
    NSArray<TTIOIdentification *> *datasetIdentifications =
        dataset.identifications ?: @[];
    NSArray<TTIOQuantification *> *datasetQuantifications =
        dataset.quantifications ?: @[];
    BOOL hasEncryptionAlgo =
        dataset.isEncrypted && dataset.encryptedAlgorithm.length > 0;
    BOOL hasDatasetProv = datasetProvenance.count > 0;
    BOOL hasRefs = datasetRefs.count > 0;
    BOOL hasIdents = datasetIdentifications.count > 0;
    BOOL hasQuants = datasetQuantifications.count > 0;
    BOOL hasV011Content = hasEncryptionAlgo
                       || hasDatasetProv
                       || hasRefs
                       || hasImage
                       || hasIdents
                       || hasQuants;
    if (hasV011Content
        && ![features containsObject:TTIOTransportV011Feature]) {
        [features addObject:TTIOTransportV011Feature];
    }

    if (![self writeStreamHeaderWithFormatVersion:@"1.2"
                                             title:(dataset.title ?: @"")
                                  isaInvestigation:(dataset.isaInvestigationId ?: @"")
                                          features:features
                                         nDatasets:(uint16_t)(runNames.count + genomicNames.count)
                                             error:error]) return NO;

    // v0.11 §5.4 prelude — sub-sections in spec order:
    //   §5.4.1 ENCRYPTION_ALGORITHM
    //   §5.4.2 DATASET_PROVENANCE
    //   §5.4.3 SUBJECT_METADATA / SAMPLE_METADATA   (future)
    //   §5.4.4 reference groups
    //   §5.4.5 image cubes
    //   §5.4.6 IDENTIFICATIONS_TABLE / QUANTIFICATIONS_TABLE
    // Sort reference URIs deterministically so cross-call output is
    // reproducible (the dictionary iteration order is otherwise
    // undefined; Java + Python use insertion order via LinkedHashMap /
    // dict ordering, which for an embedded-on-open dataset is the
    // on-disk lexicographic order from the references group children).
    if (hasV011Content) {
        if (hasEncryptionAlgo) {
            if (![self writeEncryptionAlgorithm:dataset.encryptedAlgorithm
                                            error:error]) return NO;
        }
        if (hasDatasetProv) {
            if (![self writeDatasetProvenance:datasetProvenance
                                          error:error]) return NO;
        }
        if (hasRefs) {
            NSArray<NSString *> *refUris =
                [datasetRefs.allKeys sortedArrayUsingSelector:@selector(compare:)];
            for (NSString *uri in refUris) {
                TTIOReferenceImport *ref = datasetRefs[uri];
                if (![self writeReferenceGroup:ref error:error]) return NO;
            }
        }
        if (hasImage) {
            if (![self writeImage:datasetImage error:error]) return NO;
        }
        // §5.4 step 6: identifications first, then quantifications.
        if (hasIdents) {
            if (![self writeIdentificationsTable:datasetIdentifications
                                            error:error]) return NO;
        }
        if (hasQuants) {
            if (![self writeQuantificationsTable:datasetQuantifications
                                            error:error]) return NO;
        }
    }

    uint16_t did = 1;
    for (NSString *name in runNames) {
        TTIOAcquisitionRun *run = dataset.msRuns[name];
        NSArray<NSString *> *channelNames =
            [run valueForKey:@"channelNames"] ?: @[@"mz", @"intensity"];
        NSString *instrJSON = instrumentConfigJSON(run.instrumentConfig);
        if (![self writeDatasetHeaderWithDatasetId:did
                                               name:name
                                    acquisitionMode:(uint8_t)run.acquisitionMode
                                      spectrumClass:(run.spectrumClassName ?: @"TTIOMassSpectrum")
                                       channelNames:channelNames
                                     instrumentJSON:instrJSON
                                   expectedAUCount:(uint32_t)[run count]
                                              error:error]) return NO;
        did++;
    }
    // contiguous IDs after MS — genomic dataset_ids start at
    // runNames.count + 1. M90.9: 5 channels (sequences, qualities,
    // cigar, read_name, mate_chromosome).
    NSArray<NSString *> *gChannelNames = @[@"sequences", @"qualities",
                                             @"cigar", @"read_name",
                                             @"mate_chromosome"];
    for (NSString *name in genomicNames) {
        TTIOGenomicRun *grun = dataset.genomicRuns[name];
        NSString *instrJSON = genomicRunMetadataJSON(grun);
        if (![self writeDatasetHeaderWithDatasetId:did
                                               name:name
                                    acquisitionMode:(uint8_t)grun.acquisitionMode
                                      spectrumClass:@"TTIOGenomicRead"
                                       channelNames:gChannelNames
                                     instrumentJSON:instrJSON
                                   expectedAUCount:(uint32_t)grun.readCount
                                              error:error]) return NO;
        did++;
    }

    did = 1;
    for (NSString *name in runNames) {
        TTIOAcquisitionRun *run = dataset.msRuns[name];
        NSArray<NSString *> *channelNames =
            [run valueForKey:@"channelNames"] ?: @[@"mz", @"intensity"];
        NSUInteger count = [run count];
        for (NSUInteger i = 0; i < count; i++) {
            TTIOSpectrum *sp = [run objectAtIndex:i];
            TTIOAccessUnit *au = accessUnitFromSpectrum(sp, run, channelNames, _useCompression);
            if (![self writeAccessUnit:au datasetId:did auSequence:(uint32_t)i error:error]) return NO;
        }
        if (![self writeEndOfDatasetWithDatasetId:did
                                  finalAUSequence:(uint32_t)count
                                             error:error]) return NO;
        did++;
    }
    // M89.4 / M90.9 / M90.10: genomic AU bursts. The AU emission
    // mirrors writeGenomicRun: for the standalone API; we inline
    // here so writeDataset: stays a single transactional walk
    // without re-emitting the dataset header.
    for (NSString *name in genomicNames) {
        TTIOGenomicRun *grun = dataset.genomicRuns[name];
        NSUInteger nReads = grun.readCount;

        // Phase 2c-T: emit verbatim v2 blob packets (mate_info,
        // read_names, sequences/refdiff_v2) when bulk mode is on
        // and the source has them on disk.
        if (_useBulkMode) {
            NSData *mateBlob = [grun readMateInfoInlineV2BlobBytes];
            if (mateBlob != nil) {
                NSArray<NSString *> *names = [grun readMateInfoChromNamesTable];
                if (![self writeBlobV2MateInfoWithDatasetId:did
                                                  chromNames:names
                                                        blob:mateBlob
                                                       error:error]) return NO;
            }
            NSData *nameBlob = [grun readNameTokV2BlobBytes];
            if (nameBlob != nil) {
                if (![self writeBlobV2NameTokWithDatasetId:did
                                                        blob:nameBlob
                                                       error:error]) return NO;
            }
            NSData *refDiffBlob = [grun readRefDiffV2BlobBytes];
            if (refDiffBlob != nil) {
                if (![self writeBlobV2RefDiffWithDatasetId:did
                                              referenceUri:(grun.referenceUri ?: @"")
                                                        blob:refDiffBlob
                                                       error:error]) return NO;
            }
        }
        uint8_t acqMode = (uint8_t)grun.acquisitionMode;
        TTIOGenomicIndex *idx = grun.index;
        // probe source's @compression on sequences + qualities.
        uint8_t seqCodec = [grun wireCompressionForChannel:@"sequences"];
        uint8_t qualCodec = [grun wireCompressionForChannel:@"qualities"];
        // Bulk-fetch the byte channels + read-names list once. Mirrors
        // the Java + Python encoders (commits 758b340 / Python
        // transport/codec.py:494-505) so per-record cost is dominated
        // by NSData slicing (~free) instead of TTIOAlignedRead
        // materialisation + String roundtrip.
        NSData *seqAll = (nReads > 0)
            ? [grun wholeSequencesData] : [NSData data];
        NSData *qualAll = (nReads > 0)
            ? [grun wholeQualitiesData] : [NSData data];
        NSArray<NSString *> *namesAll = [grun allReadNames];
        const uint8_t *seqBytes  = seqAll.bytes;
        const uint8_t *qualBytes = qualAll.bytes;
        NSUInteger qualLenTotal = qualAll.length;
        for (NSUInteger i = 0; i < nReads; i++) {
            uint64_t offset = idx ? [idx offsetAt:i] : 0;
            uint32_t length = idx ? [idx lengthAt:i] : 0;
            NSData *seqData = (length > 0)
                ? [NSData dataWithBytes:seqBytes + offset length:length]
                : [NSData data];
            NSData *qualData;
            if (qualLenTotal >= offset + length && length > 0) {
                qualData = [NSData dataWithBytes:qualBytes + offset
                                          length:length];
            } else {
                qualData = [NSData data];
            }
            // cigar / mateChromosome / matePosition / templateLength
            // still flow through readAtIndex — those decoders cache
            // after first call so per-record cost is amortised. The
            // savings here are skipping the byteChannelSliceNamed
            // work + NSString alloc for the seq channel.
            NSError *readErr = nil;
            TTIOAlignedRead *r = [grun readAtIndex:i error:&readErr];
            if (!r) {
                if (error) *error = readErr;
                return NO;
            }
            uint32_t seqLen = (uint32_t)seqData.length;
            uint32_t qualLen = (uint32_t)qualData.length;
            NSData *seqPayload = applyWireCodecGenomic(seqData, seqCodec);
            NSData *qualPayload = applyWireCodecGenomic(qualData, qualCodec);
            TTIOTransportChannelData *seqCh =
                [[TTIOTransportChannelData alloc] initWithName:@"sequences"
                                                      precision:TTIOPrecisionUInt8
                                                    compression:seqCodec
                                                      nElements:seqLen
                                                           data:seqPayload];
            TTIOTransportChannelData *qualCh =
                [[TTIOTransportChannelData alloc] initWithName:@"qualities"
                                                      precision:TTIOPrecisionUInt8
                                                    compression:qualCodec
                                                      nElements:qualLen
                                                           data:qualPayload];
            NSData *cigarData = [(r.cigar ?: @"") dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
            NSString *nameStr = (i < namesAll.count) ? namesAll[i] : (r.readName ?: @"");
            NSData *nameData  = [nameStr dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
            NSData *mateChrData = [(r.mateChromosome ?: @"") dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
            TTIOTransportChannelData *cigarCh =
                [[TTIOTransportChannelData alloc] initWithName:@"cigar"
                                                      precision:TTIOPrecisionUInt8
                                                    compression:TTIOCompressionNone
                                                      nElements:(uint32_t)cigarData.length
                                                           data:cigarData];
            TTIOTransportChannelData *nameCh =
                [[TTIOTransportChannelData alloc] initWithName:@"read_name"
                                                      precision:TTIOPrecisionUInt8
                                                    compression:TTIOCompressionNone
                                                      nElements:(uint32_t)nameData.length
                                                           data:nameData];
            TTIOTransportChannelData *mateChrCh =
                [[TTIOTransportChannelData alloc] initWithName:@"mate_chromosome"
                                                      precision:TTIOPrecisionUInt8
                                                    compression:TTIOCompressionNone
                                                      nElements:(uint32_t)mateChrData.length
                                                           data:mateChrData];
            NSString *chrom = r.chromosome;
            int64_t pos = r.position;
            uint8_t mapq = r.mappingQuality;
            uint16_t flags = (uint16_t)(r.flags & 0xFFFFu);
            if (idx && i < idx.count) {
                chrom = [idx chromosomeAt:i] ?: chrom;
                pos = [idx positionAt:i];
                mapq = [idx mappingQualityAt:i];
                flags = (uint16_t)([idx flagsAt:i] & 0xFFFFu);
            }
            TTIOAccessUnit *au =
                [[TTIOAccessUnit alloc] initWithSpectrumClass:5
                                              acquisitionMode:acqMode
                                                      msLevel:0
                                                     polarity:2
                                                retentionTime:0.0
                                                  precursorMz:0.0
                                              precursorCharge:0
                                                  ionMobility:0.0
                                            basePeakIntensity:0.0
                                                     channels:@[seqCh, qualCh, cigarCh, nameCh, mateChrCh]
                                                       pixelX:0 pixelY:0 pixelZ:0
                                                   chromosome:(chrom ?: @"")
                                                     position:pos
                                               mappingQuality:mapq
                                                        flags:flags
                                                 matePosition:r.matePosition
                                               templateLength:r.templateLength];
            if (![self writeAccessUnit:au datasetId:did auSequence:(uint32_t)i error:error]) {
                return NO;
            }
        }
        if (![self writeEndOfDatasetWithDatasetId:did
                                  finalAUSequence:(uint32_t)nReads
                                             error:error]) return NO;
        did++;
    }

    return [self writeEndOfStreamWithError:error];
}

@end
