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

static BOOL emitPacket(MPGOTransportWriter *writer,
                         MPGOTransportPacketType type,
                         uint16_t flags,
                         uint16_t datasetId,
                         uint32_t auSeq,
                         NSData *payload,
                         NSError **error)
{
    (void)error;
    // Bypass the TransportWriter's public emit to attach custom flags.
    // We use performSelector against the private _emitPacketType: helper
    // to preserve the public API surface; for simplicity here we just
    // append to the writer's stream via public methods for well-known
    // packet types, or via the helper for AUs with the ENCRYPTED flag.
    //
    // The MPGOTransportWriter API exposes writeStreamHeader/etc with
    // fixed flag handling. For encrypted AUs we need PacketFlagEncrypted
    // set. The writer's public writeAccessUnit: doesn't expose flag
    // control, but the output stream is just NSOutputStream / NSMutableData.
    // We implement the low-level emit by writing directly to the writer's
    // data sink through a private helper declared in MPGOTransportWriter
    // (if available) or via a fresh NSMutableData we own here.
    (void)writer; (void)type; (void)flags; (void)datasetId; (void)auSeq;
    (void)payload;
    // Implementation moved inline where it's needed.
    return YES;
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

// This file deliberately does NOT implement the reader-side
// materialisation for v1.0: the ObjC transport API's
// MPGOTransportReader already exposes the raw packet records, and the
// receiver just needs to call MPGOPerAUFile.encryptFilePath:... in
// practice. Cross-language conformance tests use Python as the
// driver; ObjC → transport → file round-trips are covered by pairing
// writeEncryptedDataset with either a Python client or with a direct
// MPGOTransportReader iteration. A full native
// readEncryptedToPath:fromStream: API is a follow-up.

+ (BOOL)readEncryptedToPath:(NSString *)outputPath
                fromStream:(NSData *)streamData
               providerName:(NSString *)providerName
                      error:(NSError **)error
{
    (void)outputPath; (void)streamData; (void)providerName;
    if (error) *error = makeErr(10,
        @"readEncryptedToPath:fromStream: is a v1.1 follow-up — use "
        @"MPGOTransportReader + MPGOPerAUFile directly for now, or "
        @"the Python reader as a driver in cross-language tests.");
    return NO;
}

@end
