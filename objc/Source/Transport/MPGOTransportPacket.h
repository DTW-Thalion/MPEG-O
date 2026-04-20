/*
 * MPGOTransportPacket — v0.10 M67 packet header + CRC-32C helpers.
 *
 * Implements the 24-byte PacketHeader specified in
 * docs/transport-spec.md §3. All multi-byte fields are little-endian
 * on the wire.
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.transport.packets.PacketHeader + PacketType
 *   Java:   com.dtwthalion.mpgo.transport.PacketHeader + PacketType
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef MPGO_TRANSPORT_PACKET_H
#define MPGO_TRANSPORT_PACKET_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern const uint8_t MPGOTransportHeaderMagic[2];  // 'M', 'O'
extern const uint8_t MPGOTransportVersion;          // 0x01
extern const NSUInteger MPGOTransportHeaderSize;    // 24

typedef NS_ENUM(uint8_t, MPGOTransportPacketType) {
    MPGOTransportPacketStreamHeader        = 0x01,
    MPGOTransportPacketDatasetHeader       = 0x02,
    MPGOTransportPacketAccessUnit          = 0x03,
    MPGOTransportPacketProtectionMetadata  = 0x04,
    MPGOTransportPacketAnnotation          = 0x05,
    MPGOTransportPacketProvenance          = 0x06,
    MPGOTransportPacketChromatogram        = 0x07,
    MPGOTransportPacketEndOfDataset        = 0x08,
    MPGOTransportPacketEndOfStream         = 0xFF
};

typedef NS_OPTIONS(uint16_t, MPGOTransportPacketFlag) {
    MPGOTransportPacketFlagEncrypted       = 1 << 0,
    MPGOTransportPacketFlagCompressed      = 1 << 1,
    MPGOTransportPacketFlagHasChecksum     = 1 << 2,
    // v1.0: set in addition to ENCRYPTED when the AU's semantic
    // header fields are AES-GCM encrypted (transport-spec §4.3.3).
    // Readers MUST reject EncryptedHeader without Encrypted.
    MPGOTransportPacketFlagEncryptedHeader = 1 << 3
};

/** 24-byte packet header as a plain value object. */
@interface MPGOTransportPacketHeader : NSObject

@property (nonatomic, readonly) MPGOTransportPacketType packetType;
@property (nonatomic, readonly) uint16_t flags;
@property (nonatomic, readonly) uint16_t datasetId;
@property (nonatomic, readonly) uint32_t auSequence;
@property (nonatomic, readonly) uint32_t payloadLength;
@property (nonatomic, readonly) uint64_t timestampNs;

- (instancetype)initWithPacketType:(MPGOTransportPacketType)type
                             flags:(uint16_t)flags
                         datasetId:(uint16_t)datasetId
                        auSequence:(uint32_t)auSequence
                     payloadLength:(uint32_t)payloadLength
                       timestampNs:(uint64_t)timestampNs;

- (NSData *)encode;

+ (nullable instancetype)decodeFromBytes:(const uint8_t *)bytes
                                   length:(NSUInteger)length
                                    error:(NSError * _Nullable *)error;

@end

/**
 * CRC-32C (Castagnoli, reflected). Used when
 * MPGOTransportPacketFlagHasChecksum is set on a packet header.
 * Matches google-crc32c and java.util.zip.CRC32C output.
 */
uint32_t MPGOTransportCRC32C(const uint8_t *data, NSUInteger length);

extern NSString *const MPGOTransportErrorDomain;

typedef NS_ENUM(NSInteger, MPGOTransportErrorCode) {
    MPGOTransportErrorBadMagic        = 1001,
    MPGOTransportErrorBadVersion      = 1002,
    MPGOTransportErrorTruncated       = 1003,
    MPGOTransportErrorChecksumFailed  = 1004,
    MPGOTransportErrorNonMonotonicAU  = 1005,
    MPGOTransportErrorMissingStreamHeader = 1006,
    MPGOTransportErrorUnexpectedPayload   = 1007
};

NS_ASSUME_NONNULL_END

#endif
