/*
 * TTIOTransportPacket.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOTransportPacketHeader
 * Inherits From: NSObject
 * Conforms To:   NSObject (NSObject)
 * Declared In:   Transport/TTIOTransportPacket.h
 *
 * 24-byte transport packet header value class plus CRC-32C
 * (Castagnoli, reflected) helper. Validates magic 'TI', version
 * 0x01, and bounds-checks payloadLength on decode.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#include <pthread.h>
#import "TTIOTransportPacket.h"
#import "TTIOTransportPacket+Internal.h"

const uint8_t TTIOTransportHeaderMagic[2] = {'T', 'I'};
const uint8_t TTIOTransportVersion = 0x01;
const NSUInteger TTIOTransportHeaderSize = 24;

NSString *const TTIOTransportErrorDomain = @"TTIOTransportErrorDomain";

NSString *const TTIOTransportBulkModeV2BlobsFeature = @"bulk_mode_v2_blobs";
NSString *const TTIOTransportV011Feature = @"transport_v0_11";
const uint8_t TTIOTransportCodecIdMateInlineV2    = 13;
const uint8_t TTIOTransportCodecIdRefDiffV2       = 14;
const uint8_t TTIOTransportCodecIdNameTokenizedV2 = 15;

// ---------------------------------------------------------------- CRC-32C

static uint32_t TTIOTransportCRC32CTable[256];
static void TTIOTransportCRC32CBuildTableImpl(void)
{
    const uint32_t poly = 0x82F63B78u;  // Castagnoli, reflected
    for (int b = 0; b < 256; b++) {
        uint32_t crc = (uint32_t)b;
        for (int i = 0; i < 8; i++) {
            crc = (crc >> 1) ^ ((crc & 1u) ? poly : 0u);
        }
        TTIOTransportCRC32CTable[b] = crc;
    }
}
static void TTIOTransportCRC32CBuildTable(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, TTIOTransportCRC32CBuildTableImpl);
}

uint32_t TTIOTransportCRC32C(const uint8_t *data, NSUInteger length)
{
    TTIOTransportCRC32CBuildTable();
    uint32_t crc = 0xFFFFFFFFu;
    for (NSUInteger i = 0; i < length; i++) {
        crc = (crc >> 8) ^ TTIOTransportCRC32CTable[(crc ^ data[i]) & 0xFFu];
    }
    return crc ^ 0xFFFFFFFFu;
}

// ---------------------------------------------------------------- helpers

static inline void writeUInt16LE(uint8_t *buf, uint16_t v)
{
    buf[0] = (uint8_t)(v & 0xFFu);
    buf[1] = (uint8_t)((v >> 8) & 0xFFu);
}

static inline void writeUInt32LE(uint8_t *buf, uint32_t v)
{
    buf[0] = (uint8_t)(v & 0xFFu);
    buf[1] = (uint8_t)((v >> 8) & 0xFFu);
    buf[2] = (uint8_t)((v >> 16) & 0xFFu);
    buf[3] = (uint8_t)((v >> 24) & 0xFFu);
}

static inline void writeUInt64LE(uint8_t *buf, uint64_t v)
{
    for (int i = 0; i < 8; i++) buf[i] = (uint8_t)((v >> (8 * i)) & 0xFFu);
}

static inline uint16_t readUInt16LE(const uint8_t *buf)
{
    return (uint16_t)((uint32_t)buf[0] | ((uint32_t)buf[1] << 8));
}

static inline uint32_t readUInt32LE(const uint8_t *buf)
{
    return (uint32_t)buf[0]
         | ((uint32_t)buf[1] << 8)
         | ((uint32_t)buf[2] << 16)
         | ((uint32_t)buf[3] << 24);
}

static inline uint64_t readUInt64LE(const uint8_t *buf)
{
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v |= ((uint64_t)buf[i]) << (8 * i);
    return v;
}

// ---------------------------------------------------------- known types

// Forward-compat skip-unknown (transport-spec §6, v0.11 task 0.7):
// authoritative table of recognised wire bytes. Anything outside
// this set is tolerated by the reader but flagged via
// packetTypeByte != packetType. Keep in lock-step with the
// TTIOTransportPacketType enum in TTIOTransportPacket.h. Cross-
// language parity: Java PacketType.fromWireOrNull, Python
// is_known_packet_type.
static const uint8_t TTIOTransportKnownPacketTypes[] = {
    TTIOTransportPacketStreamHeader,         // 0x01
    TTIOTransportPacketDatasetHeader,        // 0x02
    TTIOTransportPacketAccessUnit,           // 0x03
    TTIOTransportPacketProtectionMetadata,   // 0x04
    TTIOTransportPacketAnnotation,           // 0x05
    TTIOTransportPacketProvenance,           // 0x06
    TTIOTransportPacketChromatogram,         // 0x07
    TTIOTransportPacketEndOfDataset,         // 0x08
    TTIOTransportPacketBlobV2MateInfo,       // 0x09
    TTIOTransportPacketBlobV2RefDiff,        // 0x0A
    TTIOTransportPacketBlobV2NameTok,        // 0x0B
    TTIOTransportPacketReferenceGroupHeader, // 0x10
    TTIOTransportPacketReferenceChromosome,  // 0x11
    TTIOTransportPacketEndOfReferenceGroup,  // 0x12
    TTIOTransportPacketImageHeader,          // 0x13
    TTIOTransportPacketImagePixel,           // 0x14
    TTIOTransportPacketEndOfImage,           // 0x15
    TTIOTransportPacketIdentificationsTable, // 0x16
    TTIOTransportPacketQuantificationsTable, // 0x17
    TTIOTransportPacketDatasetProvenance,    // 0x18
    TTIOTransportPacketSubjectMetadata,      // 0x19
    TTIOTransportPacketSampleMetadata,       // 0x1A
    TTIOTransportPacketEncryptionAlgorithm,  // 0x1B
    TTIOTransportPacketGenomicRunSidecar,    // 0x1C
    TTIOTransportPacketBlockSidecar,         // 0x1D
    TTIOTransportPacketEndOfStream,          // 0xFF
};

BOOL TTIOTransportIsKnownPacketType(uint8_t typeByte)
{
    for (NSUInteger i = 0;
         i < sizeof(TTIOTransportKnownPacketTypes) / sizeof(uint8_t);
         i++) {
        if (TTIOTransportKnownPacketTypes[i] == typeByte) return YES;
    }
    return NO;
}

// ---------------------------------------------------------------- header

@implementation TTIOTransportPacketHeader

- (instancetype)initWithPacketType:(TTIOTransportPacketType)type
                             flags:(uint16_t)flags
                         datasetId:(uint16_t)datasetId
                        auSequence:(uint32_t)auSequence
                     payloadLength:(uint32_t)payloadLength
                       timestampNs:(uint64_t)timestampNs
{
    // Public ctor: assume the caller passes a known type byte (any
    // recognised TTIOTransportPacketType). packetTypeByte mirrors it.
    return [self initWithPacketTypeByte:(uint8_t)(type & 0xFFu)
                                   flags:flags
                               datasetId:datasetId
                              auSequence:auSequence
                           payloadLength:payloadLength
                             timestampNs:timestampNs];
}

- (instancetype)initWithPacketTypeByte:(uint8_t)typeByte
                                  flags:(uint16_t)flags
                              datasetId:(uint16_t)datasetId
                             auSequence:(uint32_t)auSequence
                          payloadLength:(uint32_t)payloadLength
                            timestampNs:(uint64_t)timestampNs
{
    if ((self = [super init])) {
        // Forward-compat: when the byte is not a known PacketType the
        // typed `packetType` is left at 0 (unused wire value) and only
        // `packetTypeByte` carries the byte. Callers that need to
        // dispatch on the type should consult packetTypeByte +
        // TTIOTransportIsKnownPacketType().
        _packetTypeByte = typeByte;
        _packetType = TTIOTransportIsKnownPacketType(typeByte)
            ? (TTIOTransportPacketType)typeByte
            : (TTIOTransportPacketType)0;
        _flags = flags;
        _datasetId = datasetId;
        _auSequence = auSequence;
        _payloadLength = payloadLength;
        _timestampNs = timestampNs;
    }
    return self;
}

- (NSData *)encode
{
    return [[self class] encodeRawWithTypeByte:_packetTypeByte
                                          flags:_flags
                                      datasetId:_datasetId
                                     auSequence:_auSequence
                                  payloadLength:_payloadLength
                                    timestampNs:_timestampNs];
}

+ (NSData *)encodeRawWithTypeByte:(uint8_t)typeByte
                             flags:(uint16_t)flags
                         datasetId:(uint16_t)datasetId
                        auSequence:(uint32_t)auSequence
                     payloadLength:(uint32_t)payloadLength
                       timestampNs:(uint64_t)timestampNs
{
    uint8_t buf[24];
    buf[0] = TTIOTransportHeaderMagic[0];
    buf[1] = TTIOTransportHeaderMagic[1];
    buf[2] = TTIOTransportVersion;
    buf[3] = typeByte;
    writeUInt16LE(&buf[4], flags);
    writeUInt16LE(&buf[6], datasetId);
    writeUInt32LE(&buf[8], auSequence);
    writeUInt32LE(&buf[12], payloadLength);
    writeUInt64LE(&buf[16], timestampNs);
    return [NSData dataWithBytes:buf length:24];
}

+ (instancetype)decodeFromBytes:(const uint8_t *)bytes
                          length:(NSUInteger)length
                           error:(NSError **)error
{
    if (length < TTIOTransportHeaderSize) {
        if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                 code:TTIOTransportErrorTruncated
                                             userInfo:@{NSLocalizedDescriptionKey:
                             [NSString stringWithFormat:@"header needs %lu bytes, got %lu",
                                 (unsigned long)TTIOTransportHeaderSize, (unsigned long)length]}];
        return nil;
    }
    if (bytes[0] != 'T' || bytes[1] != 'I') {
        if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                 code:TTIOTransportErrorBadMagic
                                             userInfo:@{NSLocalizedDescriptionKey:
                             @"invalid packet magic"}];
        return nil;
    }
    if (bytes[2] != TTIOTransportVersion) {
        if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                 code:TTIOTransportErrorBadVersion
                                             userInfo:@{NSLocalizedDescriptionKey:
                             [NSString stringWithFormat:@"unsupported transport version: %u",
                                 (unsigned)bytes[2]]}];
        return nil;
    }
    // Forward-compat: tolerate unknown packet type bytes by preserving
    // the raw byte in packetTypeByte. The reader's outer loop logs +
    // length-prefix-skips the payload. See transport-spec §6 +
    // TTIOTransportReader.readAllPackets.
    return [[self alloc] initWithPacketTypeByte:bytes[3]
                                           flags:readUInt16LE(&bytes[4])
                                       datasetId:readUInt16LE(&bytes[6])
                                      auSequence:readUInt32LE(&bytes[8])
                                   payloadLength:readUInt32LE(&bytes[12])
                                     timestampNs:readUInt64LE(&bytes[16])];
}

@end
