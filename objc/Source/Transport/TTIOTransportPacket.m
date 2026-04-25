/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "TTIOTransportPacket.h"

const uint8_t TTIOTransportHeaderMagic[2] = {'T', 'I'};
const uint8_t TTIOTransportVersion = 0x01;
const NSUInteger TTIOTransportHeaderSize = 24;

NSString *const TTIOTransportErrorDomain = @"TTIOTransportErrorDomain";

// ---------------------------------------------------------------- CRC-32C

static uint32_t TTIOTransportCRC32CTable[256];
static void TTIOTransportCRC32CBuildTable(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const uint32_t poly = 0x82F63B78u;  // Castagnoli, reflected
        for (int b = 0; b < 256; b++) {
            uint32_t crc = (uint32_t)b;
            for (int i = 0; i < 8; i++) {
                crc = (crc >> 1) ^ ((crc & 1u) ? poly : 0u);
            }
            TTIOTransportCRC32CTable[b] = crc;
        }
    });
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

// ---------------------------------------------------------------- header

@implementation TTIOTransportPacketHeader

- (instancetype)initWithPacketType:(TTIOTransportPacketType)type
                             flags:(uint16_t)flags
                         datasetId:(uint16_t)datasetId
                        auSequence:(uint32_t)auSequence
                     payloadLength:(uint32_t)payloadLength
                       timestampNs:(uint64_t)timestampNs
{
    if ((self = [super init])) {
        _packetType = type;
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
    uint8_t buf[24];
    buf[0] = TTIOTransportHeaderMagic[0];
    buf[1] = TTIOTransportHeaderMagic[1];
    buf[2] = TTIOTransportVersion;
    buf[3] = (uint8_t)(_packetType & 0xFFu);
    writeUInt16LE(&buf[4], _flags);
    writeUInt16LE(&buf[6], _datasetId);
    writeUInt32LE(&buf[8], _auSequence);
    writeUInt32LE(&buf[12], _payloadLength);
    writeUInt64LE(&buf[16], _timestampNs);
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
    return [[self alloc] initWithPacketType:(TTIOTransportPacketType)bytes[3]
                                      flags:readUInt16LE(&bytes[4])
                                  datasetId:readUInt16LE(&bytes[6])
                                 auSequence:readUInt32LE(&bytes[8])
                              payloadLength:readUInt32LE(&bytes[12])
                                timestampNs:readUInt64LE(&bytes[16])];
}

@end
