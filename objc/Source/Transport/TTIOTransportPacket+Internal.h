/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * Internal extension to TTIOTransportPacketHeader. Exposes the
 * raw-type-byte initializer and the matching encode helper. Used by:
 *
 *   - TTIOTransportPacket.m's decodeFromBytes: to preserve the raw
 *     wire byte when it doesn't name a known TTIOTransportPacketType.
 *   - The forward-compat skip-unknown tests (TestTransportReader-
 *     SkipUnknown.m), which need to fabricate a packet carrying an
 *     arbitrary type byte to verify the reader tolerates it.
 *
 * Not part of the public TTIO API. Headers live under Source/Transport/
 * but are NOT re-exported via TTIO.h — callers outside the library
 * must not depend on this surface.
 */
#ifndef TTIO_TRANSPORT_PACKET_INTERNAL_H
#define TTIO_TRANSPORT_PACKET_INTERNAL_H

#import "TTIOTransportPacket.h"

NS_ASSUME_NONNULL_BEGIN

@interface TTIOTransportPacketHeader (Internal)

/** Internal initializer preserving the raw type byte alongside the
 *  decoded ``TTIOTransportPacketType``. When ``typeByte`` does not
 *  name a known packet type the ``packetType`` property is left at
 *  ``0`` (an unused wire value) and only ``packetTypeByte`` carries
 *  the byte. Java parity: package-private
 *  ``PacketHeader(PacketType, int packetTypeByte, ...)`` ctor. */
- (instancetype)initWithPacketTypeByte:(uint8_t)typeByte
                                  flags:(uint16_t)flags
                              datasetId:(uint16_t)datasetId
                             auSequence:(uint32_t)auSequence
                          payloadLength:(uint32_t)payloadLength
                            timestampNs:(uint64_t)timestampNs;

/** Test/internal helper: encode a 24-byte packet header carrying an
 *  arbitrary ``typeByte`` (validated only for magic + version on the
 *  decode side). Lets the skip-unknown forward-compat tests fabricate
 *  packets whose type byte is outside the ``TTIOTransportPacketType``
 *  enum. Java parity: the test helper in
 *  ``TransportReaderSkipUnknownTest.writeRawPacket``. */
+ (NSData *)encodeRawWithTypeByte:(uint8_t)typeByte
                             flags:(uint16_t)flags
                         datasetId:(uint16_t)datasetId
                        auSequence:(uint32_t)auSequence
                     payloadLength:(uint32_t)payloadLength
                       timestampNs:(uint64_t)timestampNs;

@end

NS_ASSUME_NONNULL_END

#endif
