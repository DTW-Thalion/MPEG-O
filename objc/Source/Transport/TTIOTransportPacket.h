/*
 * TTIOTransportPacket — v0.10 M67 packet header + CRC-32C helpers.
 *
 * Implements the 24-byte PacketHeader specified in
 * docs/transport-spec.md §3. All multi-byte fields are little-endian
 * on the wire.
 *
 * Cross-language equivalents:
 *   Python: ttio.transport.packets.PacketHeader + PacketType
 *   Java:   global.thalion.ttio.transport.PacketHeader + PacketType
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_TRANSPORT_PACKET_H
#define TTIO_TRANSPORT_PACKET_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern const uint8_t TTIOTransportHeaderMagic[2];  // 'T', 'I'
extern const uint8_t TTIOTransportVersion;          // 0x01
extern const NSUInteger TTIOTransportHeaderSize;    // 24

typedef NS_ENUM(uint8_t, TTIOTransportPacketType) {
    TTIOTransportPacketStreamHeader        = 0x01,
    TTIOTransportPacketDatasetHeader       = 0x02,
    TTIOTransportPacketAccessUnit          = 0x03,
    TTIOTransportPacketProtectionMetadata  = 0x04,
    TTIOTransportPacketAnnotation          = 0x05,
    TTIOTransportPacketProvenance          = 0x06,
    TTIOTransportPacketChromatogram        = 0x07,
    TTIOTransportPacketEndOfDataset        = 0x08,
    TTIOTransportPacketEndOfStream         = 0xFF
};

typedef NS_OPTIONS(uint16_t, TTIOTransportPacketFlag) {
    TTIOTransportPacketFlagEncrypted       = 1 << 0,
    TTIOTransportPacketFlagCompressed      = 1 << 1,
    TTIOTransportPacketFlagHasChecksum     = 1 << 2,
    // v1.0: set in addition to ENCRYPTED when the AU's semantic
    // header fields are AES-GCM encrypted (transport-spec §4.3.3).
    // Readers MUST reject EncryptedHeader without Encrypted.
    TTIOTransportPacketFlagEncryptedHeader = 1 << 3
};

/** 24-byte packet header as a plain value object. */
@interface TTIOTransportPacketHeader : NSObject

@property (nonatomic, readonly) TTIOTransportPacketType packetType;
@property (nonatomic, readonly) uint16_t flags;
@property (nonatomic, readonly) uint16_t datasetId;
@property (nonatomic, readonly) uint32_t auSequence;
@property (nonatomic, readonly) uint32_t payloadLength;
@property (nonatomic, readonly) uint64_t timestampNs;

- (instancetype)initWithPacketType:(TTIOTransportPacketType)type
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
 * TTIOTransportPacketFlagHasChecksum is set on a packet header.
 * Matches google-crc32c and java.util.zip.CRC32C output.
 */
uint32_t TTIOTransportCRC32C(const uint8_t *data, NSUInteger length);

extern NSString *const TTIOTransportErrorDomain;

typedef NS_ENUM(NSInteger, TTIOTransportErrorCode) {
    TTIOTransportErrorBadMagic        = 1001,
    TTIOTransportErrorBadVersion      = 1002,
    TTIOTransportErrorTruncated       = 1003,
    TTIOTransportErrorChecksumFailed  = 1004,
    TTIOTransportErrorNonMonotonicAU  = 1005,
    TTIOTransportErrorMissingStreamHeader = 1006,
    TTIOTransportErrorUnexpectedPayload   = 1007
};

NS_ASSUME_NONNULL_END

#endif
