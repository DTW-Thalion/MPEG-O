/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "TTIOTransportWriter.h"
#import "Dataset/TTIOSpectralDataset.h"
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

static NSString *spectrumClassToWireName(uint8_t wire)
{
    switch (wire) {
        case 0: return @"TTIOMassSpectrum";
        case 1: return @"TTIONMRSpectrum";
        case 2: return @"TTIONMR2DSpectrum";
        case 3: return @"TTIOFreeInductionDecay";
        case 4: return @"TTIOMSImagePixel";
        case 5: return @"TTIOGenomicRead";  // M89.2
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
    if ([name isEqualToString:@"TTIOGenomicRead"]) return 5;  // M89.2
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

@implementation TTIOTransportWriter
{
    NSFileHandle *_fileHandle;    // path-based sink
    NSMutableData *_dataBuffer;   // in-memory sink
    BOOL _streamHeaderWritten;
}

- (instancetype)initWithOutputPath:(NSString *)path
{
    if ((self = [super init])) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        _fileHandle = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    return self;
}

- (instancetype)initWithMutableData:(NSMutableData *)data
{
    if ((self = [super init])) {
        _dataBuffer = data;
    }
    return self;
}

- (void)close
{
    if (_fileHandle) {
        [_fileHandle closeFile];
        _fileHandle = nil;
    }
}

- (void)dealloc
{
    [self close];
}

- (void)writeBytes:(NSData *)data
{
    if (_fileHandle) {
        [_fileHandle writeData:data];
    } else {
        [_dataBuffer appendData:data];
    }
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
    NSData *json = [NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingSortedKeys error:nil];
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
                                                    options:NSJSONWritingSortedKeys
                                                      error:nil];
    return [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
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
    if (![self writeDatasetHeaderWithDatasetId:datasetId
                                           name:(name ?: @"")
                                acquisitionMode:(uint8_t)run.acquisitionMode
                                  spectrumClass:@"TTIOGenomicRead"
                                   channelNames:@[@"sequences", @"qualities"]
                                 instrumentJSON:instrJSON
                                expectedAUCount:(uint32_t)nReads
                                          error:error]) return NO;

    TTIOGenomicIndex *idx = run.index;
    uint8_t acqMode = (uint8_t)run.acquisitionMode;
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
        TTIOTransportChannelData *seqCh =
            [[TTIOTransportChannelData alloc] initWithName:@"sequences"
                                                  precision:TTIOPrecisionUInt8
                                                compression:TTIOCompressionNone
                                                  nElements:seqLen
                                                       data:seqData];
        TTIOTransportChannelData *qualCh =
            [[TTIOTransportChannelData alloc] initWithName:@"qualities"
                                                  precision:TTIOPrecisionUInt8
                                                compression:TTIOCompressionNone
                                                  nElements:qualLen
                                                       data:qualData];
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
                                                 channels:@[seqCh, qualCh]
                                                   pixelX:0 pixelY:0 pixelZ:0
                                               chromosome:(chrom ?: @"")
                                                 position:pos
                                           mappingQuality:mapq
                                                    flags:flags];
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

    // M89.4: genomic runs after MS runs in the dataset_id space.
    NSArray<NSString *> *genomicNames =
        [dataset.genomicRuns.allKeys sortedArrayUsingSelector:@selector(compare:)];

    // Features currently unknown via the ObjC API; emit empty list.
    if (![self writeStreamHeaderWithFormatVersion:@"1.2"
                                             title:(dataset.title ?: @"")
                                  isaInvestigation:(dataset.isaInvestigationId ?: @"")
                                          features:@[]
                                         nDatasets:(uint16_t)(runNames.count + genomicNames.count)
                                             error:error]) return NO;

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
    // M89.4: contiguous IDs after MS — genomic dataset_ids start at
    // runNames.count + 1.
    for (NSString *name in genomicNames) {
        TTIOGenomicRun *grun = dataset.genomicRuns[name];
        NSString *instrJSON = genomicRunMetadataJSON(grun);
        if (![self writeDatasetHeaderWithDatasetId:did
                                               name:name
                                    acquisitionMode:(uint8_t)grun.acquisitionMode
                                      spectrumClass:@"TTIOGenomicRead"
                                       channelNames:@[@"sequences", @"qualities"]
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
    // M89.4: genomic AU bursts. Reuses the per-run helper so the
    // multiplexed flow shares a single emission path with manual
    // writeGenomicRun: callers.
    for (NSString *name in genomicNames) {
        TTIOGenomicRun *grun = dataset.genomicRuns[name];
        NSUInteger nReads = grun.readCount;
        uint8_t acqMode = (uint8_t)grun.acquisitionMode;
        TTIOGenomicIndex *idx = grun.index;
        for (NSUInteger i = 0; i < nReads; i++) {
            NSError *readErr = nil;
            TTIOAlignedRead *r = [grun readAtIndex:i error:&readErr];
            if (!r) {
                if (error) *error = readErr;
                return NO;
            }
            NSData *seqData = [r.sequence dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
            NSData *qualData = r.qualities ?: [NSData data];
            TTIOTransportChannelData *seqCh =
                [[TTIOTransportChannelData alloc] initWithName:@"sequences"
                                                      precision:TTIOPrecisionUInt8
                                                    compression:TTIOCompressionNone
                                                      nElements:(uint32_t)seqData.length
                                                           data:seqData];
            TTIOTransportChannelData *qualCh =
                [[TTIOTransportChannelData alloc] initWithName:@"qualities"
                                                      precision:TTIOPrecisionUInt8
                                                    compression:TTIOCompressionNone
                                                      nElements:(uint32_t)qualData.length
                                                           data:qualData];
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
                                                     channels:@[seqCh, qualCh]
                                                       pixelX:0 pixelY:0 pixelZ:0
                                                   chromosome:(chrom ?: @"")
                                                     position:pos
                                               mappingQuality:mapq
                                                        flags:flags];
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
