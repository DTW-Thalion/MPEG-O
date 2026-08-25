/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * Transport packet header value class plus CRC-32C helper. Implements
 * the 24-byte PacketHeader specified in docs/transport-spec.md §3.
 * All multi-byte fields are little-endian on the wire.
 *
 * Cross-language equivalents:
 *   Python: ttio.transport.packets.PacketHeader + PacketType
 *   Java:   global.thalion.ttio.transport.PacketHeader + PacketType
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
    // Phase 2c-T bulk-mode v2 blob carriage (transport-spec §4.10-§4.12).
    TTIOTransportPacketBlobV2MateInfo      = 0x09,
    TTIOTransportPacketBlobV2RefDiff       = 0x0A,
    TTIOTransportPacketBlobV2NameTok       = 0x0B,
    // ---- v0.11 (transport-spec-complete-coverage 2026-05-25) ----
    // Emitted only when the StreamHeader features list contains
    // "transport_v0_11". See transport-spec §4.13-§4.23.
    // Java / Python parity:
    //   global.thalion.ttio.transport.PacketType
    //   ttio.transport.packets.PacketType
    TTIOTransportPacketReferenceGroupHeader = 0x10,
    TTIOTransportPacketReferenceChromosome  = 0x11,
    TTIOTransportPacketEndOfReferenceGroup  = 0x12,
    TTIOTransportPacketImageHeader          = 0x13,
    TTIOTransportPacketImagePixel           = 0x14,
    TTIOTransportPacketEndOfImage           = 0x15,
    TTIOTransportPacketIdentificationsTable = 0x16,
    TTIOTransportPacketQuantificationsTable = 0x17,
    TTIOTransportPacketDatasetProvenance    = 0x18,
    TTIOTransportPacketSubjectMetadata      = 0x19,
    TTIOTransportPacketSampleMetadata       = 0x1A,
    TTIOTransportPacketEncryptionAlgorithm  = 0x1B,
    // ---- M99.1 blocks_v1 per-AU carriage (transport-spec §4.24) ----
    // Emitted only for genomic runs with layout blocks_v1 in an
    // encrypted stream, announced by the StreamHeader feature token
    // "transport_blocks_v1". One GenomicRunSidecar per run after its
    // DatasetHeader, then one BlockSidecar per block before the AUs.
    TTIOTransportPacketGenomicRunSidecar    = 0x1C,
    TTIOTransportPacketBlockSidecar         = 0x1D,
    TTIOTransportPacketEndOfStream         = 0xFF
};

/// Phase 2c-T feature flag in StreamHeader features list.
extern NSString *const TTIOTransportBulkModeV2BlobsFeature;

/// v0.11 feature flag in StreamHeader features list. Required (no
/// opt_ prefix) when any of the 0x10-0x1B packet types ride on the
/// wire. Cross-language parity: Java
/// PacketType.TRANSPORT_V0_11_FEATURE, Python
/// ttio.transport.packets.TRANSPORT_V0_11_FEATURE.
extern NSString *const TTIOTransportV011Feature;

/// Phase 2c-T codec ids (mirror TTIOCompression enum).
extern const uint8_t TTIOTransportCodecIdMateInlineV2;       // 13
extern const uint8_t TTIOTransportCodecIdRefDiffV2;          // 14
extern const uint8_t TTIOTransportCodecIdNameTokenizedV2;    // 15

typedef NS_OPTIONS(uint16_t, TTIOTransportPacketFlag) {
    TTIOTransportPacketFlagEncrypted       = 1 << 0,
    TTIOTransportPacketFlagCompressed      = 1 << 1,
    TTIOTransportPacketFlagHasChecksum     = 1 << 2,
    // Set in addition to ENCRYPTED when the AU's semantic header
    // fields are AES-GCM encrypted (transport-spec §4.3.3).
    // Readers MUST reject EncryptedHeader without Encrypted.
    TTIOTransportPacketFlagEncryptedHeader = 1 << 3
};

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Transport/TTIOTransportPacket.h</p>
 *
 * <p>24-byte packet header as a plain value object.</p>
 */
@interface TTIOTransportPacketHeader : NSObject

@property (nonatomic, readonly) TTIOTransportPacketType packetType;
/** Raw wire byte for the packet type. Equal to ``packetType`` when
 *  the byte names a known ``TTIOTransportPacketType``; otherwise this
 *  is the unknown byte that the reader's forward-compat path
 *  tolerated. Always populated regardless of whether the byte names a
 *  known type. See transport-spec §6 (v0.11 skip-unknown contract).
 *  Cross-language parity: Java
 *  ``PacketHeader.packetTypeByte()``, Python
 *  ``PacketHeader.packet_type_byte``. */
@property (nonatomic, readonly) uint8_t packetTypeByte;
@property (nonatomic, readonly) uint16_t flags;
@property (nonatomic, readonly) uint16_t datasetId;
@property (nonatomic, readonly) uint32_t auSequence;
@property (nonatomic, readonly) uint32_t payloadLength;
@property (nonatomic, readonly) uint64_t timestampNs;

/**
 * Designated initialiser. Builds an immutable header value.
 *
 * @param type            Known packet-type tag. The constructor stores
 *                        ``type`` as both ``packetType`` and
 *                        ``packetTypeByte``.
 * @param flags           Combination of ``TTIOTransportPacketFlag``
 *                        bits; zero is valid.
 * @param datasetId       Dataset identifier the packet belongs to;
 *                        zero is valid for stream-scoped packets.
 * @param auSequence      Per-dataset monotonic access-unit counter;
 *                        zero on packets that don't carry an AU.
 * @param payloadLength   Length of the payload that follows this
 *                        header on the wire.
 * @param timestampNs     Wall-clock timestamp in nanoseconds; the
 *                        emitter sets the epoch.
 * @return An initialised header.
 */
- (instancetype)initWithPacketType:(TTIOTransportPacketType)type
                             flags:(uint16_t)flags
                         datasetId:(uint16_t)datasetId
                        auSequence:(uint32_t)auSequence
                     payloadLength:(uint32_t)payloadLength
                       timestampNs:(uint64_t)timestampNs;

/**
 * Serialise the header to its 24-byte little-endian wire form.
 *
 * @return An ``NSData`` of exactly ``TTIOTransportHeaderSize`` bytes.
 */
- (NSData *)encode;

/**
 * Decode a 24-byte header from a raw byte buffer.
 *
 * @param bytes   Pointer to the start of a packet (header + payload).
 * @param length  Number of bytes available at ``bytes``. Must be at
 *                least ``TTIOTransportHeaderSize``.
 * @param error   On failure, populated with an ``NSError`` in the
 *                ``TTIOTransportErrorDomain`` (``BadMagic``,
 *                ``BadVersion``, ``Truncated``). May be ``NULL``.
 * @return A decoded ``TTIOTransportPacketHeader`` on success;
 *         ``nil`` on malformed input.
 */
+ (nullable instancetype)decodeFromBytes:(const uint8_t *)bytes
                                   length:(NSUInteger)length
                                    error:(NSError * _Nullable *)error;

@end

/**
 * Returns ``YES`` iff ``typeByte`` names a defined
 * ``TTIOTransportPacketType``. Used by the reader's forward-compat
 * skip-unknown path (transport-spec §6) — decoded headers whose
 * ``packetTypeByte`` fails this check are length-prefix skipped
 * rather than rejected. Cross-language parity: Java
 * ``PacketType.fromWireOrNull``, Python ``is_known_packet_type``.
 *
 * @param typeByte  Wire byte read out of the header's packet-type
 *                  field.
 * @return ``YES`` when the byte names a known type; ``NO`` otherwise.
 */
BOOL TTIOTransportIsKnownPacketType(uint8_t typeByte);

/**
 * CRC-32C (Castagnoli, reflected). Used when
 * TTIOTransportPacketFlagHasChecksum is set on a packet header.
 * Matches google-crc32c and java.util.zip.CRC32C output.
 *
 * @param data    Pointer to the bytes to hash.
 * @param length  Number of bytes available at ``data``.
 * @return The 32-bit CRC-32C value as a little-endian integer.
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
