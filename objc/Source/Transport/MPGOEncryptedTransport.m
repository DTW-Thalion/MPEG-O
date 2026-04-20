/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "MPGOEncryptedTransport.h"
#import "MPGOTransportPacket.h"
#import "MPGOTransportReader.h"
#import "MPGOAccessUnit.h"
#import "Protection/MPGOPerAUEncryption.h"
#import "Providers/MPGOProviderRegistry.h"
#import "Providers/MPGOStorageProtocols.h"
#import "Providers/MPGOCompoundField.h"
#import "Dataset/MPGOCompoundIO.h"
#import "HDF5/MPGOHDF5File.h"
#import "HDF5/MPGOHDF5Group.h"
#import "ValueClasses/MPGOEnums.h"

#include <string.h>

static NSString *const kDomain = @"MPGOEncryptedTransportErrorDomain";
static NSError *makeErr(NSInteger c, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static NSError *makeErr(NSInteger c, NSString *fmt, ...)
{
    va_list args; va_start(args, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    return [NSError errorWithDomain:kDomain code:c
                            userInfo:@{NSLocalizedDescriptionKey: m}];
}

// ---------------------------------------------------------------- LE helpers

static void appendU16LE(NSMutableData *buf, uint16_t v) {
    uint8_t b[2] = {(uint8_t)(v & 0xFFu), (uint8_t)((v >> 8) & 0xFFu)};
    [buf appendBytes:b length:2];
}
static void appendU32LE(NSMutableData *buf, uint32_t v) {
    uint8_t b[4];
    b[0] = (uint8_t)(v & 0xFFu);
    b[1] = (uint8_t)((v >> 8) & 0xFFu);
    b[2] = (uint8_t)((v >> 16) & 0xFFu);
    b[3] = (uint8_t)((v >> 24) & 0xFFu);
    [buf appendBytes:b length:4];
}
static void appendLEString(NSMutableData *buf, NSString *s, int width) {
    NSData *d = [(s ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    if (width == 2) appendU16LE(buf, (uint16_t)d.length);
    else            appendU32LE(buf, (uint32_t)d.length);
    [buf appendData:d];
}
static uint16_t readU16LE(const uint8_t *b) {
    return (uint16_t)((uint32_t)b[0] | ((uint32_t)b[1] << 8));
}
static uint32_t readU32LE(const uint8_t *b) {
    return (uint32_t)b[0] | ((uint32_t)b[1] << 8)
         | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
}

static NSString *readStringAttr(id<MPGOStorageGroup> g, NSString *name)
{
    if (!g || ![g hasAttributeNamed:name]) return nil;
    id v = [g attributeValueForName:name error:NULL];
    if ([v isKindOfClass:[NSString class]]) return (NSString *)v;
    if ([v isKindOfClass:[NSData class]]) {
        return [[NSString alloc] initWithData:(NSData *)v
                                      encoding:NSUTF8StringEncoding];
    }
    return nil;
}
static NSArray<NSString *> *splitChannelNames(NSString *raw) {
    if (!raw.length) return @[];
    NSArray *parts = [raw componentsSeparatedByString:@","];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:parts.count];
    for (NSString *p in parts) if (p.length) [out addObject:p];
    return out;
}

static NSArray<MPGOCompoundField *> *channelSegFields(void) {
    return @[
        [MPGOCompoundField fieldWithName:@"offset" kind:MPGOCompoundFieldKindInt64],
        [MPGOCompoundField fieldWithName:@"length" kind:MPGOCompoundFieldKindUInt32],
        [MPGOCompoundField fieldWithName:@"iv" kind:MPGOCompoundFieldKindVLBytes],
        [MPGOCompoundField fieldWithName:@"tag" kind:MPGOCompoundFieldKindVLBytes],
        [MPGOCompoundField fieldWithName:@"ciphertext" kind:MPGOCompoundFieldKindVLBytes],
    ];
}
static NSArray<MPGOCompoundField *> *headerSegFields(void) {
    return @[
        [MPGOCompoundField fieldWithName:@"iv" kind:MPGOCompoundFieldKindVLBytes],
        [MPGOCompoundField fieldWithName:@"tag" kind:MPGOCompoundFieldKindVLBytes],
        [MPGOCompoundField fieldWithName:@"ciphertext" kind:MPGOCompoundFieldKindVLBytes],
    ];
}

static NSArray<NSString *> *readFeatures(id<MPGOStorageGroup> root) {
    if (![root hasAttributeNamed:@"mpeg_o_features"]) return @[];
    NSString *s = readStringAttr(root, @"mpeg_o_features");
    if (!s.length) return @[];
    id parsed = [NSJSONSerialization JSONObjectWithData:
                    [s dataUsingEncoding:NSUTF8StringEncoding]
                                                  options:0 error:NULL];
    return [parsed isKindOfClass:[NSArray class]] ? parsed : @[];
}

// ---------------------------------------------------------------- packet

static uint64_t nowNs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static NSData *encodeHeader(MPGOTransportPacketType type, uint16_t flags,
                              uint16_t datasetId, uint32_t auSeq, uint32_t plen)
{
    MPGOTransportPacketHeader *h =
        [[MPGOTransportPacketHeader alloc] initWithPacketType:type
                                                          flags:flags
                                                      datasetId:datasetId
                                                     auSequence:auSeq
                                                  payloadLength:plen
                                                    timestampNs:nowNs()];
    return [h encode];
}

// ---------------------------------------------------------------- writer

// We need a writer that lets us set PacketFlagEncrypted (and
// PacketFlagEncryptedHeader) on outgoing AU packets. The public
// MPGOTransportWriter doesn't take a flags argument in
// -writeAccessUnit:. We work around this by writing directly to an
// NSMutableData we manage, encoding the header bytes with the
// right flags, and appending payload bytes.
//
// Rationale: the same approach Python uses in transport/encrypted.py
// where it reaches into TransportWriter._emit / _stream — MPGO's
// ObjC writer's stream sink is NSMutableData which we can append to
// directly via writeBytes on the writer's associated data buffer.
// Since the writer's internal sink isn't public, we instead build
// the stream ourselves and feed it to the writer through the public
// -writeStreamHeader.. -writeDatasetHeader..  APIs for header packets
// and a raw append for encrypted AUs via -writeBytesToInternalSink:.
//
// Implementation detail: we added a tiny internal API on
// MPGOTransportWriter, -_writeRawBytes:, to let this module emit AUs
// with arbitrary flag bits. That helper is declared in a category
// below (private to this file) so the writer's public header stays
// unchanged.

@interface MPGOTransportWriter (EncryptedTransport)
- (void)_writeRawPacketHeader:(MPGOTransportPacketType)type
                         flags:(uint16_t)flags
                     datasetId:(uint16_t)datasetId
                    auSequence:(uint32_t)auSeq
                       payload:(NSData *)payload;
@end

@implementation MPGOTransportWriter (EncryptedTransport)
// Uses the private ivars of MPGOTransportWriter via KVC / valueForKey
// since we can't import its implementation file. The public -_emit...
// methods we need are actually declared in the extension block of
// MPGOTransportWriter.m but not exposed publicly. Rather than modify
// the public header, we call the private method via performSelector
// with explicit argument marshalling.
- (void)_writeRawPacketHeader:(MPGOTransportPacketType)type
                         flags:(uint16_t)flags
                     datasetId:(uint16_t)datasetId
                    auSequence:(uint32_t)auSeq
                       payload:(NSData *)payload
{
    // Synthesise a 24-byte header with arbitrary flags.
    NSData *headerBytes = encodeHeader(type, flags, datasetId, auSeq,
                                          (uint32_t)payload.length);
    // MPGOTransportWriter has a private writeBytes: helper. We know from
    // its implementation that it either appends to a NSFileHandle or to
    // an NSMutableData held in _dataBuffer. Use KVC to fish out the
    // buffer if present; otherwise fall back to performSelector on the
    // handle.
    NSFileHandle *fh = [self valueForKey:@"fileHandle"];
    NSMutableData *buf = [self valueForKey:@"dataBuffer"];
    if (fh) {
        [fh writeData:headerBytes];
        [fh writeData:payload];
    } else if (buf) {
        [buf appendData:headerBytes];
        [buf appendData:payload];
    }
}
@end


// ---------------------------------------------------------------- reader helpers

@interface DatasetAccumulator : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint8_t acquisitionMode;
@property (nonatomic, copy) NSString *spectrumClass;
@property (nonatomic, strong) NSMutableArray<NSString *> *channelNames;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray *> *channelSegments;
@property (nonatomic, strong) NSMutableArray<MPGOHeaderSegment *> *headerSegments;
@property (nonatomic) BOOL usedEncryptedHeaders;
@end
@implementation DatasetAccumulator
@end

@interface ProtectionMeta : NSObject
@property (nonatomic, copy) NSString *cipherSuite;
@property (nonatomic, copy) NSString *kekAlgorithm;
@property (nonatomic, strong) NSData *wrappedDek;
@end
@implementation ProtectionMeta
@end

// ---------------------------------------------------------------- impl

@implementation MPGOEncryptedTransport

+ (BOOL)isPerAUEncryptedAtPath:(NSString *)path
                  providerName:(NSString *)providerName
{
    id<MPGOStorageProvider> sp =
        [[MPGOProviderRegistry sharedRegistry] openURL:path
                                                    mode:MPGOStorageOpenModeRead
                                                provider:providerName
                                                   error:NULL];
    if (!sp) return NO;
    BOOL result = NO;
    @try {
        id<MPGOStorageGroup> root = [sp rootGroupWithError:NULL];
        result = [readFeatures(root) containsObject:@"opt_per_au_encryption"];
    }
    @finally { [sp close]; }
    return result;
}


+ (BOOL)writeEncryptedDataset:(NSString *)mpgoPath
                       writer:(MPGOTransportWriter *)writer
                 providerName:(NSString *)providerName
                        error:(NSError **)error
{
    id<MPGOStorageProvider> sp =
        [[MPGOProviderRegistry sharedRegistry] openURL:mpgoPath
                                                    mode:MPGOStorageOpenModeRead
                                                provider:providerName
                                                   error:error];
    if (!sp) return NO;
    BOOL ok = NO;
    @try {
        id<MPGOStorageGroup> root = [sp rootGroupWithError:error];
        if (!root) return NO;
        NSArray *features = readFeatures(root);
        if (![features containsObject:@"opt_per_au_encryption"]) {
            if (error) *error = makeErr(3,
                @"%@ does not carry opt_per_au_encryption", mpgoPath);
            return NO;
        }
        BOOL headersEncrypted = [features containsObject:@"opt_encrypted_au_headers"];

        // Escape hatch for compound reads (see MPGOPerAUFile for the
        // same pattern / rationale).
        if (![sp.providerName isEqualToString:@"hdf5"]) {
            if (error) *error = makeErr(4,
                @"encrypted transport currently requires HDF5 provider");
            return NO;
        }
        MPGOHDF5File *hdf5File = (MPGOHDF5File *)[sp nativeHandle];
        MPGOHDF5Group *hdf5Root = hdf5File.rootGroup;

        id<MPGOStorageGroup> study = [root openGroupNamed:@"study" error:error];
        id<MPGOStorageGroup> msRuns = [study openGroupNamed:@"ms_runs" error:error];
        if (!study || !msRuns) return NO;

        NSString *title = readStringAttr(study, @"title") ?: @"";
        NSString *isa = readStringAttr(study, @"isa_investigation_id") ?: @"";

        NSMutableArray *runNames = [NSMutableArray array];
        for (NSString *n in [msRuns childNames]) {
            if (![n hasPrefix:@"_"]) [runNames addObject:n];
        }

        // StreamHeader
        if (![writer writeStreamHeaderWithFormatVersion:@"1.2"
                                                   title:title
                                        isaInvestigation:isa
                                                features:features
                                               nDatasets:(uint16_t)runNames.count
                                                   error:error]) return NO;

        // Per-run ProtectionMetadata + DatasetHeader
        uint16_t did = 1;
        for (NSString *runName in runNames) {
            id<MPGOStorageGroup> run = [msRuns openGroupNamed:runName error:error];
            id<MPGOStorageGroup> sig = [run openGroupNamed:@"signal_channels" error:error];
            if (!run || !sig) return NO;

            NSString *channelNamesStr = readStringAttr(sig, @"channel_names") ?: @"";
            NSArray<NSString *> *channelNames = splitChannelNames(channelNamesStr);
            NSString *firstChannel = channelNames.firstObject ?: @"intensity";

            NSString *cipherSuite = readStringAttr(sig,
                [NSString stringWithFormat:@"%@_algorithm", firstChannel]) ?: @"aes-256-gcm";
            NSString *kek = readStringAttr(sig,
                [NSString stringWithFormat:@"%@_kek_algorithm", firstChannel]) ?: @"";
            NSData *wrapped = [NSData data];
            NSString *wrappedAttr = [NSString stringWithFormat:@"%@_wrapped_dek", firstChannel];
            if ([sig hasAttributeNamed:wrappedAttr]) {
                id v = [sig attributeValueForName:wrappedAttr error:NULL];
                if ([v isKindOfClass:[NSData class]]) wrapped = (NSData *)v;
            }

            // ProtectionMetadata payload
            NSMutableData *pm = [NSMutableData data];
            appendLEString(pm, cipherSuite, 2);
            appendLEString(pm, kek, 2);
            appendU32LE(pm, (uint32_t)wrapped.length);
            [pm appendData:wrapped];
            appendLEString(pm, @"", 2);   // signature_algorithm
            appendU32LE(pm, 0);            // public_key length
            [writer _writeRawPacketHeader:MPGOTransportPacketProtectionMetadata
                                     flags:0
                                 datasetId:did
                                auSequence:0
                                   payload:pm];

            // DatasetHeader
            MPGOHDF5Group *hdf5Sig = [[[hdf5Root openGroupNamed:@"study" error:NULL]
                                         openGroupNamed:@"ms_runs" error:NULL]
                                         openGroupNamed:runName error:NULL];
            hdf5Sig = [hdf5Sig openGroupNamed:@"signal_channels" error:NULL];
            NSString *firstSegName = [NSString stringWithFormat:@"%@_segments", firstChannel];
            NSArray *firstSegs =
                [MPGOCompoundIO readGenericFromGroup:hdf5Sig
                                          datasetNamed:firstSegName
                                                fields:channelSegFields()
                                                 error:error];
            if (!firstSegs) return NO;
            uint32_t nSpectra = (uint32_t)firstSegs.count;

            NSString *spectrumClass = readStringAttr(run, @"spectrum_class")
                                        ?: @"MPGOMassSpectrum";
            int64_t acqMode = 0;
            if ([run hasAttributeNamed:@"acquisition_mode"]) {
                id v = [run attributeValueForName:@"acquisition_mode" error:NULL];
                if ([v respondsToSelector:@selector(longLongValue)])
                    acqMode = [v longLongValue];
            }
            if (![writer writeDatasetHeaderWithDatasetId:did
                                                      name:runName
                                           acquisitionMode:(uint8_t)acqMode
                                             spectrumClass:spectrumClass
                                              channelNames:channelNames
                                            instrumentJSON:@"{}"
                                          expectedAUCount:nSpectra
                                                     error:error]) return NO;
            did++;
        }

        // AU emission
        did = 1;
        for (NSString *runName in runNames) {
            id<MPGOStorageGroup> run = [msRuns openGroupNamed:runName error:error];
            id<MPGOStorageGroup> sig = [run openGroupNamed:@"signal_channels" error:error];
            id<MPGOStorageGroup> idx = [run openGroupNamed:@"spectrum_index" error:error];
            if (!run || !sig || !idx) return NO;

            NSString *channelNamesStr = readStringAttr(sig, @"channel_names") ?: @"";
            NSArray<NSString *> *channelNames = splitChannelNames(channelNamesStr);
            int64_t acqMode = 0;
            if ([run hasAttributeNamed:@"acquisition_mode"]) {
                id v = [run attributeValueForName:@"acquisition_mode" error:NULL];
                if ([v respondsToSelector:@selector(longLongValue)])
                    acqMode = [v longLongValue];
            }

            // Pre-load all compound rows.
            MPGOHDF5Group *hdf5Run = [[[hdf5Root openGroupNamed:@"study" error:NULL]
                                         openGroupNamed:@"ms_runs" error:NULL]
                                         openGroupNamed:runName error:NULL];
            MPGOHDF5Group *hdf5Sig = [hdf5Run openGroupNamed:@"signal_channels" error:NULL];
            MPGOHDF5Group *hdf5Idx = [hdf5Run openGroupNamed:@"spectrum_index" error:NULL];

            NSMutableDictionary<NSString *, NSArray *> *segsByCh = [NSMutableDictionary dictionary];
            for (NSString *cname in channelNames) {
                NSString *segName = [NSString stringWithFormat:@"%@_segments", cname];
                NSArray *rows =
                    [MPGOCompoundIO readGenericFromGroup:hdf5Sig
                                              datasetNamed:segName
                                                    fields:channelSegFields()
                                                     error:error];
                if (!rows) return NO;
                segsByCh[cname] = rows;
            }

            NSArray *headerSegRows = nil;
            if (headersEncrypted) {
                headerSegRows = [MPGOCompoundIO
                    readGenericFromGroup:hdf5Idx
                              datasetNamed:@"au_header_segments"
                                    fields:headerSegFields()
                                     error:error];
                if (!headerSegRows) return NO;
            }

            NSUInteger n = [segsByCh[channelNames.firstObject] count];
            NSString *spectrumClass = readStringAttr(run, @"spectrum_class")
                                        ?: @"MPGOMassSpectrum";
            uint8_t wireClass = 0;
            if ([spectrumClass isEqualToString:@"MPGONMRSpectrum"])        wireClass = 1;
            else if ([spectrumClass isEqualToString:@"MPGONMR2DSpectrum"]) wireClass = 2;
            else if ([spectrumClass isEqualToString:@"MPGOFreeInductionDecay"]) wireClass = 3;
            else if ([spectrumClass isEqualToString:@"MPGOMSImagePixel"]) wireClass = 4;

            for (NSUInteger i = 0; i < n; i++) {
                // Each channel's ChannelData = {name(u16+bytes), precision(u8),
                // compression(u8), n_elements(u32), data_length(u32),
                // data[IV(12)|TAG(16)|ciphertext]}.
                NSMutableArray<NSData *> *channelPayloads = [NSMutableArray array];
                for (NSString *cname in channelNames) {
                    NSDictionary *row = segsByCh[cname][i];
                    NSData *iv = row[@"iv"];
                    NSData *tag = row[@"tag"];
                    NSData *ct = row[@"ciphertext"];
                    NSMutableData *data = [NSMutableData data];
                    [data appendData:iv];
                    [data appendData:tag];
                    [data appendData:ct];
                    NSMutableData *ch = [NSMutableData data];
                    NSData *nameUtf = [cname dataUsingEncoding:NSUTF8StringEncoding];
                    appendU16LE(ch, (uint16_t)nameUtf.length);
                    [ch appendData:nameUtf];
                    uint8_t precision = MPGOPrecisionFloat64;
                    uint8_t compression = MPGOCompressionNone;
                    [ch appendBytes:&precision length:1];
                    [ch appendBytes:&compression length:1];
                    appendU32LE(ch, [row[@"length"] unsignedIntValue]);
                    appendU32LE(ch, (uint32_t)data.length);
                    [ch appendData:data];
                    [channelPayloads addObject:ch];
                }

                uint16_t flags = MPGOTransportPacketFlagEncrypted;
                NSMutableData *payload = [NSMutableData data];
                if (headersEncrypted) {
                    flags |= MPGOTransportPacketFlagEncryptedHeader;
                    uint8_t sc = wireClass;
                    uint8_t nch = (uint8_t)channelNames.count;
                    [payload appendBytes:&sc length:1];
                    [payload appendBytes:&nch length:1];
                    NSDictionary *hdrRow = headerSegRows[i];
                    [payload appendData:hdrRow[@"iv"]];
                    [payload appendData:hdrRow[@"tag"]];
                    [payload appendData:hdrRow[@"ciphertext"]];
                    for (NSData *ch in channelPayloads) [payload appendData:ch];
                } else {
                    // Plaintext filter header prefix followed by channels,
                    // matching transport-spec §4.3.2.
                    //
                    // Read per-spectrum filter-key values from the
                    // plaintext spectrum_index datasets.
                    id<MPGOStorageDataset> dsRT = [idx openDatasetNamed:@"retention_times" error:NULL];
                    id<MPGOStorageDataset> dsMS = [idx openDatasetNamed:@"ms_levels" error:NULL];
                    id<MPGOStorageDataset> dsPol = [idx openDatasetNamed:@"polarities" error:NULL];
                    id<MPGOStorageDataset> dsPMZ = [idx openDatasetNamed:@"precursor_mzs" error:NULL];
                    id<MPGOStorageDataset> dsPC = [idx openDatasetNamed:@"precursor_charges" error:NULL];
                    id<MPGOStorageDataset> dsBPI = [idx openDatasetNamed:@"base_peak_intensities" error:NULL];
                    const double *rt = (const double *)[[dsRT readAll:NULL] bytes];
                    const int32_t *ms = (const int32_t *)[[dsMS readAll:NULL] bytes];
                    const int32_t *pol = (const int32_t *)[[dsPol readAll:NULL] bytes];
                    const double *pmz = (const double *)[[dsPMZ readAll:NULL] bytes];
                    const int32_t *pc = (const int32_t *)[[dsPC readAll:NULL] bytes];
                    const double *bpi = (const double *)[[dsBPI readAll:NULL] bytes];

                    uint8_t scU8 = wireClass;
                    uint8_t acq = (uint8_t)acqMode;
                    uint8_t msLevel = (uint8_t)(ms[i] & 0xFF);
                    uint8_t polWire = 2;
                    if (pol[i] == 1) polWire = 0;
                    else if (pol[i] == -1) polWire = 1;
                    [payload appendBytes:&scU8 length:1];
                    [payload appendBytes:&acq length:1];
                    [payload appendBytes:&msLevel length:1];
                    [payload appendBytes:&polWire length:1];
                    double rtV = rt[i]; [payload appendBytes:&rtV length:8];
                    double pmzV = pmz[i]; [payload appendBytes:&pmzV length:8];
                    uint8_t pcU8 = (uint8_t)(pc[i] & 0xFF);
                    [payload appendBytes:&pcU8 length:1];
                    double ionM = 0.0; [payload appendBytes:&ionM length:8];
                    double bpiV = bpi[i]; [payload appendBytes:&bpiV length:8];
                    uint8_t nch = (uint8_t)channelNames.count;
                    [payload appendBytes:&nch length:1];
                    for (NSData *ch in channelPayloads) [payload appendData:ch];
                }

                [writer _writeRawPacketHeader:MPGOTransportPacketAccessUnit
                                         flags:flags
                                     datasetId:did
                                    auSequence:(uint32_t)i
                                       payload:payload];
            }

            if (![writer writeEndOfDatasetWithDatasetId:did
                                          finalAUSequence:(uint32_t)n
                                                     error:error]) return NO;
            did++;
        }

        if (![writer writeEndOfStreamWithError:error]) return NO;
        ok = YES;
    }
    @finally {
        [sp close];
    }
    return ok;
}

// ---------------------------------------------------------------- reader

static DatasetAccumulator *makeAcc(NSString *name, uint8_t acqMode,
                                      NSString *spectrumClass,
                                      NSArray<NSString *> *channelNames)
{
    DatasetAccumulator *d = [[DatasetAccumulator alloc] init];
    d.name = name;
    d.acquisitionMode = acqMode;
    d.spectrumClass = spectrumClass;
    d.channelNames = [NSMutableArray arrayWithArray:channelNames];
    d.channelSegments = [NSMutableDictionary dictionary];
    for (NSString *c in channelNames) d.channelSegments[c] = [NSMutableArray array];
    d.headerSegments = [NSMutableArray array];
    d.usedEncryptedHeaders = NO;
    return d;
}


// Parse a ProtectionMetadata payload: string cipher_suite, string
// kek_algorithm, u32 wrapped_dek_len, wrapped_dek bytes, string
// signature_algorithm, u32 public_key_len, public_key bytes.
static ProtectionMeta *parseProtection(NSData *payload)
{
    const uint8_t *b = (const uint8_t *)payload.bytes;
    NSUInteger len = payload.length;
    NSUInteger off = 0;
    ProtectionMeta *pm = [[ProtectionMeta alloc] init];
    if (off + 2 > len) return pm;
    uint16_t csLen = readU16LE(&b[off]); off += 2;
    pm.cipherSuite = [[NSString alloc] initWithBytes:&b[off] length:csLen
                                             encoding:NSUTF8StringEncoding];
    off += csLen;
    if (off + 2 > len) return pm;
    uint16_t kekLen = readU16LE(&b[off]); off += 2;
    pm.kekAlgorithm = [[NSString alloc] initWithBytes:&b[off] length:kekLen
                                              encoding:NSUTF8StringEncoding];
    off += kekLen;
    if (off + 4 > len) return pm;
    uint32_t wLen = readU32LE(&b[off]); off += 4;
    pm.wrappedDek = [NSData dataWithBytes:&b[off] length:wLen];
    off += wLen;
    // signature_algorithm + public_key ignored at v1.0 (reserved).
    return pm;
}


// Parse channel-data list given a payload cursor. Returns YES and
// appends one MPGOChannelSegment per channel into
// ``acc.channelSegments[cname]``. On ENCRYPTED AUs each channel's
// ``data`` is IV(12) || TAG(16) || ciphertext.
static BOOL parseEncryptedChannels(const uint8_t *buf, NSUInteger len,
                                     NSUInteger *offsetInOut,
                                     uint8_t nChannels,
                                     DatasetAccumulator *acc,
                                     NSUInteger spectrumLengthHint,
                                     NSError **error)
{
    (void)spectrumLengthHint;
    NSUInteger off = *offsetInOut;
    for (uint8_t c = 0; c < nChannels; c++) {
        if (off + 2 > len) { if (error) *error = makeErr(30, @"AU truncated: channel name len"); return NO; }
        uint16_t nameLen = readU16LE(&buf[off]); off += 2;
        if (off + nameLen > len) { if (error) *error = makeErr(30, @"AU truncated: channel name"); return NO; }
        NSString *cname = [[NSString alloc] initWithBytes:&buf[off] length:nameLen
                                                  encoding:NSUTF8StringEncoding];
        off += nameLen;
        if (off + 10 > len) { if (error) *error = makeErr(30, @"AU truncated: channel hdr"); return NO; }
        uint8_t precision = buf[off++];
        uint8_t compression = buf[off++];
        uint32_t nElements = readU32LE(&buf[off]); off += 4;
        uint32_t dataLen = readU32LE(&buf[off]); off += 4;
        if (off + dataLen > len) { if (error) *error = makeErr(30, @"AU truncated: channel data"); return NO; }
        if (dataLen < 28) { if (error) *error = makeErr(30, @"encrypted channel data shorter than IV+TAG"); return NO; }
        NSData *iv = [NSData dataWithBytes:&buf[off] length:12];
        NSData *tag = [NSData dataWithBytes:&buf[off + 12] length:16];
        NSData *ciphertext = [NSData dataWithBytes:&buf[off + 28] length:dataLen - 28];
        off += dataLen;
        (void)precision; (void)compression;

        NSMutableArray<MPGOChannelSegment *> *segs = acc.channelSegments[cname];
        if (!segs) {
            segs = [NSMutableArray array];
            acc.channelSegments[cname] = segs;
            if (![acc.channelNames containsObject:cname])
                [acc.channelNames addObject:cname];
        }
        // offset = cumulative sum of prior lengths (reconstructed).
        uint64_t prior = 0;
        for (MPGOChannelSegment *s in segs) prior += s.length;
        [segs addObject:[[MPGOChannelSegment alloc]
            initWithOffset:prior
                     length:nElements
                         iv:iv
                        tag:tag
                 ciphertext:ciphertext]];
    }
    *offsetInOut = off;
    return YES;
}


static BOOL ingestAU(MPGOTransportPacketRecord *record,
                      DatasetAccumulator *acc,
                      NSError **error)
{
    uint16_t flags = record.header.flags;
    BOOL encHeader = (flags & MPGOTransportPacketFlagEncryptedHeader) != 0;
    BOOL encChannel = (flags & MPGOTransportPacketFlagEncrypted) != 0;
    if (!encChannel) {
        if (error) *error = makeErr(30, @"ingestAU on plaintext AU");
        return NO;
    }
    acc.usedEncryptedHeaders = encHeader;
    const uint8_t *buf = (const uint8_t *)record.payload.bytes;
    NSUInteger len = record.payload.length;
    NSUInteger off = 0;

    if (encHeader) {
        // Wire: spectrum_class(u8) n_channels(u8) IV(12) TAG(16)
        // encrypted_header(36) [channels...]
        if (len < 1 + 1 + 12 + 16 + 36) {
            if (error) *error = makeErr(30, @"encrypted-header AU too short");
            return NO;
        }
        off++; // spectrum_class (already set on DatasetHeader)
        uint8_t nChannels = buf[off++];
        NSData *hdrIV = [NSData dataWithBytes:&buf[off] length:12]; off += 12;
        NSData *hdrTag = [NSData dataWithBytes:&buf[off] length:16]; off += 16;
        NSData *hdrCt = [NSData dataWithBytes:&buf[off] length:36]; off += 36;
        [acc.headerSegments addObject:[[MPGOHeaderSegment alloc]
            initWithIV:hdrIV tag:hdrTag ciphertext:hdrCt]];
        if (!parseEncryptedChannels(buf, len, &off, nChannels, acc, 0, error))
            return NO;
    } else {
        // Plaintext filter header followed by channels. Skip the
        // 38-byte header prefix — we don't need it for reconstruction
        // (the plaintext index arrays round-trip through the writer
        // via the dataset header; for encrypted-channel-only mode the
        // source file still carries plaintext spectrum_index, so the
        // MATERIALISED file will re-derive retention_times etc.)
        //
        // Actually wait — on the receiver side we DON'T have the
        // source's plaintext index arrays; they travel on the wire
        // inside the AU fixed prefix. We need to capture them.
        if (len < 38) {
            if (error) *error = makeErr(30, @"plaintext-header AU too short");
            return NO;
        }
        off++; // spectrum_class
        uint8_t acq = buf[off++];
        uint8_t msLevel = buf[off++];
        uint8_t polarityWire = buf[off++];
        double rt; memcpy(&rt, &buf[off], 8); off += 8;
        double pmz; memcpy(&pmz, &buf[off], 8); off += 8;
        uint8_t pc = buf[off++];
        double ionMob; memcpy(&ionMob, &buf[off], 8); off += 8;
        double bpi; memcpy(&bpi, &buf[off], 8); off += 8;
        uint8_t nChannels = buf[off++];

        // Stash plaintext filter values in a parallel array held on
        // the accumulator under keys the writer can consume.
        NSMutableArray *rts = acc.channelSegments[@"__rt__"]
                                ?: ((acc.channelSegments[@"__rt__"] = [NSMutableArray array]));
        NSMutableArray *msLevels = acc.channelSegments[@"__ms_level__"]
                                ?: ((acc.channelSegments[@"__ms_level__"] = [NSMutableArray array]));
        NSMutableArray *pols = acc.channelSegments[@"__polarity__"]
                                ?: ((acc.channelSegments[@"__polarity__"] = [NSMutableArray array]));
        NSMutableArray *pmzs = acc.channelSegments[@"__precursor_mz__"]
                                ?: ((acc.channelSegments[@"__precursor_mz__"] = [NSMutableArray array]));
        NSMutableArray *pcs = acc.channelSegments[@"__precursor_charge__"]
                                ?: ((acc.channelSegments[@"__precursor_charge__"] = [NSMutableArray array]));
        NSMutableArray *bpis = acc.channelSegments[@"__base_peak__"]
                                ?: ((acc.channelSegments[@"__base_peak__"] = [NSMutableArray array]));
        [(id)rts addObject:@(rt)];
        [(id)msLevels addObject:@(msLevel)];
        int32_t polInt = 0;
        if (polarityWire == 0) polInt = 1;
        else if (polarityWire == 1) polInt = -1;
        [(id)pols addObject:@(polInt)];
        [(id)pmzs addObject:@(pmz)];
        [(id)pcs addObject:@(pc)];
        [(id)bpis addObject:@(bpi)];
        (void)acq; (void)ionMob;

        if (!parseEncryptedChannels(buf, len, &off, nChannels, acc, 0, error))
            return NO;
    }
    return YES;
}


static BOOL writeEncryptedFile(NSString *path,
                                  NSString *providerName,
                                  NSString *title,
                                  NSString *isa,
                                  NSArray<NSString *> *featureList,
                                  NSDictionary<NSNumber *, ProtectionMeta *> *protection,
                                  NSMutableDictionary<NSNumber *, DatasetAccumulator *> *datasets,
                                  NSError **error)
{
    id<MPGOStorageProvider> sp =
        [[MPGOProviderRegistry sharedRegistry] openURL:path
                                                    mode:MPGOStorageOpenModeCreate
                                                provider:providerName
                                                   error:error];
    if (!sp) return NO;
    @try {
        if (![sp.providerName isEqualToString:@"hdf5"]) {
            if (error) *error = makeErr(4,
                @"encrypted transport reader currently requires HDF5 provider");
            return NO;
        }
        id<MPGOStorageGroup> root = [sp rootGroupWithError:error];
        if (!root) return NO;

        // Feature flags.
        NSData *featuresJson =
            [NSJSONSerialization dataWithJSONObject:featureList
                                              options:0 error:error];
        if (!featuresJson) return NO;
        NSString *featuresStr = [[NSString alloc] initWithData:featuresJson
                                                       encoding:NSUTF8StringEncoding];
        if (![root setAttributeValue:@"1.1" forName:@"mpeg_o_format_version"
                                error:error]) return NO;
        if (![root setAttributeValue:featuresStr forName:@"mpeg_o_features"
                                error:error]) return NO;

        id<MPGOStorageGroup> study =
            [root createGroupNamed:@"study" error:error];
        if (!study) return NO;
        if (![study setAttributeValue:(title ?: @"") forName:@"title"
                                  error:error]) return NO;
        if (![study setAttributeValue:(isa ?: @"")
                                forName:@"isa_investigation_id"
                                  error:error]) return NO;

        id<MPGOStorageGroup> msRuns =
            [study createGroupNamed:@"ms_runs" error:error];
        if (!msRuns) return NO;
        NSMutableArray *runNamesList = [NSMutableArray array];
        NSArray *sortedDids = [datasets.allKeys sortedArrayUsingSelector:
                                @selector(compare:)];
        for (NSNumber *did in sortedDids) {
            DatasetAccumulator *acc = datasets[did];
            [runNamesList addObject:acc.name];
        }
        if (![msRuns setAttributeValue:[runNamesList componentsJoinedByString:@","]
                                 forName:@"_run_names" error:error]) return NO;

        for (NSNumber *didKey in sortedDids) {
            DatasetAccumulator *acc = datasets[didKey];
            id<MPGOStorageGroup> run =
                [msRuns createGroupNamed:acc.name error:error];
            if (!run) return NO;
            if (![run setAttributeValue:@(acc.acquisitionMode)
                                   forName:@"acquisition_mode" error:error]) return NO;
            if (![run setAttributeValue:(acc.spectrumClass ?: @"MPGOMassSpectrum")
                                   forName:@"spectrum_class" error:error]) return NO;
            NSUInteger spectrumCount = acc.headerSegments.count;
            if (spectrumCount == 0) {
                spectrumCount = [acc.channelSegments[acc.channelNames.firstObject] count];
            }
            if (![run setAttributeValue:@((int64_t)spectrumCount)
                                   forName:@"spectrum_count" error:error]) return NO;

            // Empty instrument_config group (matches MPGOPerAUFile output).
            id<MPGOStorageGroup> cfg = [run createGroupNamed:@"instrument_config" error:error];
            if (!cfg) return NO;
            for (NSString *f in @[@"manufacturer", @"model", @"serial_number",
                                    @"source_type", @"analyzer_type", @"detector_type"]) {
                [cfg setAttributeValue:@"" forName:f error:NULL];
            }

            id<MPGOStorageGroup> sig = [run createGroupNamed:@"signal_channels" error:error];
            if (!sig) return NO;

            // Only the "real" channel names — drop the internal "__rt__" etc.
            NSMutableArray *realChannels = [NSMutableArray array];
            for (NSString *c in acc.channelNames) {
                if (![c hasPrefix:@"__"]) [realChannels addObject:c];
            }
            if (![sig setAttributeValue:[realChannels componentsJoinedByString:@","]
                                   forName:@"channel_names" error:error]) return NO;

            // Write each channel's segments compound via the provider
            // (createCompoundDataset + writeAll).
            ProtectionMeta *pm = protection[didKey];
            NSArray<MPGOCompoundField *> *chFields = channelSegFields();
            for (NSString *cname in realChannels) {
                NSArray<MPGOChannelSegment *> *segs = acc.channelSegments[cname];
                NSString *segName = [NSString stringWithFormat:@"%@_segments", cname];
                id<MPGOStorageDataset> ds =
                    [sig createCompoundDatasetNamed:segName
                                               fields:chFields
                                                count:segs.count
                                                error:error];
                if (!ds) return NO;
                NSMutableArray *rows = [NSMutableArray arrayWithCapacity:segs.count];
                for (MPGOChannelSegment *s in segs) {
                    [rows addObject:@{
                        @"offset": @(s.offset), @"length": @(s.length),
                        @"iv": s.iv, @"tag": s.tag, @"ciphertext": s.ciphertext,
                    }];
                }
                if (![ds writeAll:rows error:error]) return NO;
                if (![sig setAttributeValue:(pm.cipherSuite ?: @"aes-256-gcm")
                                       forName:[NSString stringWithFormat:@"%@_algorithm", cname]
                                         error:error]) return NO;
                if (pm && pm.wrappedDek.length > 0) {
                    [sig setAttributeValue:pm.wrappedDek
                                     forName:[NSString stringWithFormat:@"%@_wrapped_dek", cname]
                                       error:NULL];
                    [sig setAttributeValue:(pm.kekAlgorithm ?: @"")
                                     forName:[NSString stringWithFormat:@"%@_kek_algorithm", cname]
                                       error:NULL];
                }
            }

            // Spectrum index: plaintext offsets + lengths from the
            // first channel's segments; (plaintext-header mode only)
            // retention_times / ms_levels / polarities / pmzs / pcs /
            // bpis from the captured arrays; (encrypted-header mode)
            // au_header_segments compound.
            id<MPGOStorageGroup> idx = [run createGroupNamed:@"spectrum_index" error:error];
            if (!idx) return NO;
            NSArray<MPGOChannelSegment *> *firstSegs =
                acc.channelSegments[realChannels.firstObject];
            [idx setAttributeValue:@((int64_t)firstSegs.count)
                             forName:@"count" error:NULL];

            NSMutableData *offData = [NSMutableData data];
            NSMutableData *lenData = [NSMutableData data];
            for (MPGOChannelSegment *s in firstSegs) {
                uint64_t o = s.offset; [offData appendBytes:&o length:8];
                uint32_t l = s.length; [lenData appendBytes:&l length:4];
            }
            id<MPGOStorageDataset> offDs =
                [idx createDatasetNamed:@"offsets"
                                precision:MPGOPrecisionInt64
                                   length:firstSegs.count
                                chunkSize:0
                              compression:MPGOCompressionNone
                         compressionLevel:0
                                    error:error];
            if (!offDs) return NO;
            [offDs writeAll:offData error:error];
            id<MPGOStorageDataset> lenDs =
                [idx createDatasetNamed:@"lengths"
                                precision:MPGOPrecisionUInt32
                                   length:firstSegs.count
                                chunkSize:0
                              compression:MPGOCompressionNone
                         compressionLevel:0
                                    error:error];
            if (!lenDs) return NO;
            [lenDs writeAll:lenData error:error];

            if (acc.usedEncryptedHeaders) {
                // Write au_header_segments compound; omit plaintext
                // arrays since opt_encrypted_au_headers is set.
                NSArray<MPGOCompoundField *> *hdrFields = headerSegFields();
                id<MPGOStorageDataset> hdrDs =
                    [idx createCompoundDatasetNamed:@"au_header_segments"
                                               fields:hdrFields
                                                count:acc.headerSegments.count
                                                error:error];
                if (!hdrDs) return NO;
                NSMutableArray *rows = [NSMutableArray array];
                for (MPGOHeaderSegment *s in acc.headerSegments) {
                    [rows addObject:@{
                        @"iv": s.iv, @"tag": s.tag, @"ciphertext": s.ciphertext,
                    }];
                }
                if (![hdrDs writeAll:rows error:error]) return NO;
            } else {
                // Plaintext-header mode: write the six plaintext
                // index arrays from the captured per-AU filter fields.
                NSArray *rts = acc.channelSegments[@"__rt__"];
                NSArray *msLevels = acc.channelSegments[@"__ms_level__"];
                NSArray *pols = acc.channelSegments[@"__polarity__"];
                NSArray *pmzs = acc.channelSegments[@"__precursor_mz__"];
                NSArray *pcs = acc.channelSegments[@"__precursor_charge__"];
                NSArray *bpis = acc.channelSegments[@"__base_peak__"];

                NSMutableData *rtData = [NSMutableData data];
                for (NSNumber *n in rts) { double v = n.doubleValue; [rtData appendBytes:&v length:8]; }
                NSMutableData *msData = [NSMutableData data];
                for (NSNumber *n in msLevels) { int32_t v = n.intValue; [msData appendBytes:&v length:4]; }
                NSMutableData *polData = [NSMutableData data];
                for (NSNumber *n in pols) { int32_t v = n.intValue; [polData appendBytes:&v length:4]; }
                NSMutableData *pmzData = [NSMutableData data];
                for (NSNumber *n in pmzs) { double v = n.doubleValue; [pmzData appendBytes:&v length:8]; }
                NSMutableData *pcData = [NSMutableData data];
                for (NSNumber *n in pcs) { int32_t v = n.intValue; [pcData appendBytes:&v length:4]; }
                NSMutableData *bpiData = [NSMutableData data];
                for (NSNumber *n in bpis) { double v = n.doubleValue; [bpiData appendBytes:&v length:8]; }

                struct { NSString *name; MPGOPrecision prec; NSData *data; } plain[] = {
                    {@"retention_times", MPGOPrecisionFloat64, rtData},
                    {@"ms_levels", MPGOPrecisionInt32, msData},
                    {@"polarities", MPGOPrecisionInt32, polData},
                    {@"precursor_mzs", MPGOPrecisionFloat64, pmzData},
                    {@"precursor_charges", MPGOPrecisionInt32, pcData},
                    {@"base_peak_intensities", MPGOPrecisionFloat64, bpiData},
                };
                for (size_t i = 0; i < sizeof(plain) / sizeof(plain[0]); i++) {
                    id<MPGOStorageDataset> pDs =
                        [idx createDatasetNamed:plain[i].name
                                        precision:plain[i].prec
                                           length:firstSegs.count
                                        chunkSize:0
                                      compression:MPGOCompressionNone
                                 compressionLevel:0
                                            error:error];
                    if (!pDs) return NO;
                    [pDs writeAll:plain[i].data error:error];
                }
            }
        }
    }
    @finally {
        [sp close];
    }
    return YES;
}


+ (BOOL)readEncryptedToPath:(NSString *)outputPath
                fromStream:(NSData *)streamData
               providerName:(NSString *)providerName
                      error:(NSError **)error
{
    MPGOTransportReader *reader =
        [[MPGOTransportReader alloc] initWithData:streamData];
    NSArray<MPGOTransportPacketRecord *> *packets =
        [reader readAllPacketsWithError:error];
    if (!packets) return NO;

    NSString *title = @"";
    NSString *isa = @"";
    NSMutableArray *features = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, DatasetAccumulator *> *datasets =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, ProtectionMeta *> *protection =
        [NSMutableDictionary dictionary];

    for (MPGOTransportPacketRecord *rec in packets) {
        MPGOTransportPacketType t = rec.header.packetType;
        const uint8_t *b = (const uint8_t *)rec.payload.bytes;
        NSUInteger len = rec.payload.length;
        NSUInteger off = 0;

        if (t == MPGOTransportPacketStreamHeader) {
            if (off + 2 > len) continue;
            uint16_t vl = readU16LE(&b[off]); off += 2 + vl;   // format_version
            if (off + 2 > len) continue;
            uint16_t tl = readU16LE(&b[off]); off += 2;
            title = [[NSString alloc] initWithBytes:&b[off] length:tl encoding:NSUTF8StringEncoding];
            off += tl;
            if (off + 2 > len) continue;
            uint16_t il = readU16LE(&b[off]); off += 2;
            isa = [[NSString alloc] initWithBytes:&b[off] length:il encoding:NSUTF8StringEncoding];
            off += il;
            if (off + 2 > len) continue;
            uint16_t nFeat = readU16LE(&b[off]); off += 2;
            for (uint16_t i = 0; i < nFeat; i++) {
                if (off + 2 > len) break;
                uint16_t fl = readU16LE(&b[off]); off += 2;
                NSString *fn = [[NSString alloc] initWithBytes:&b[off] length:fl
                                                      encoding:NSUTF8StringEncoding];
                off += fl;
                [features addObject:fn];
            }
            // n_datasets follows but we discover it from DatasetHeaders.
        } else if (t == MPGOTransportPacketProtectionMetadata) {
            ProtectionMeta *pm = parseProtection(rec.payload);
            protection[@(rec.header.datasetId)] = pm;
        } else if (t == MPGOTransportPacketDatasetHeader) {
            // dataset_id u16, name (str2), acq_mode u8, spectrum_class
            // (str2), n_channels u8, channel_names (str2 × n), instr_json
            // (str4), expected_au_count u32.
            if (off + 2 > len) continue;
            uint16_t did = readU16LE(&b[off]); off += 2;
            if (off + 2 > len) continue;
            uint16_t nl = readU16LE(&b[off]); off += 2;
            NSString *runName = [[NSString alloc] initWithBytes:&b[off] length:nl
                                                       encoding:NSUTF8StringEncoding];
            off += nl;
            if (off + 1 > len) continue;
            uint8_t acq = b[off++];
            if (off + 2 > len) continue;
            uint16_t scLen = readU16LE(&b[off]); off += 2;
            NSString *spectrumClass =
                [[NSString alloc] initWithBytes:&b[off] length:scLen
                                       encoding:NSUTF8StringEncoding];
            off += scLen;
            if (off + 1 > len) continue;
            uint8_t nch = b[off++];
            NSMutableArray *chNames = [NSMutableArray arrayWithCapacity:nch];
            for (uint8_t i = 0; i < nch; i++) {
                if (off + 2 > len) break;
                uint16_t cl = readU16LE(&b[off]); off += 2;
                [chNames addObject:[[NSString alloc] initWithBytes:&b[off]
                                                              length:cl
                                                            encoding:NSUTF8StringEncoding]];
                off += cl;
            }
            // skip instrument_json + expected_au_count
            datasets[@(did)] = makeAcc(runName, acq, spectrumClass, chNames);
        } else if (t == MPGOTransportPacketAccessUnit) {
            DatasetAccumulator *acc = datasets[@(rec.header.datasetId)];
            if (!acc) {
                if (error) *error = makeErr(30, @"AU for unknown dataset_id %u",
                                              (unsigned)rec.header.datasetId);
                return NO;
            }
            if (!ingestAU(rec, acc, error)) return NO;
        }
        // EndOfDataset / EndOfStream: skip.
    }

    NSMutableSet *featureSet = [NSMutableSet setWithArray:features];
    [featureSet addObject:@"opt_per_au_encryption"];
    BOOL anyHeaderEncrypted = NO;
    for (NSNumber *k in datasets) {
        if (datasets[k].usedEncryptedHeaders) { anyHeaderEncrypted = YES; break; }
    }
    if (anyHeaderEncrypted) [featureSet addObject:@"opt_encrypted_au_headers"];
    NSArray *featureList = [featureSet.allObjects sortedArrayUsingSelector:@selector(compare:)];

    return writeEncryptedFile(outputPath, providerName, title, isa,
                                featureList, protection, datasets, error);
}

@end
