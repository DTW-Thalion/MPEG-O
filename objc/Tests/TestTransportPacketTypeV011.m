/*
 * TestTransportPacketTypeV011 — transport-spec v0.11 packet-type
 * constants (0x10-0x1B) + the TRANSPORT_V0_11_FEATURE flag string.
 *
 * Covers the ObjC side of transport-spec-complete-coverage Task 0.6.
 * Cross-language parity:
 *   - Java: global.thalion.ttio.transport.PacketType (0x10-0x1B + flag)
 *   - Python: ttio.transport.packets.PacketType (0x10-0x1B + flag)
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"

#import "Transport/TTIOTransportPacket.h"

void testTransportPacketTypeV011(void)
{
    /* Wire-byte parity with Java + Python v0.11 packet types. */
    PASS(TTIOTransportPacketReferenceGroupHeader == 0x10,
         "REFERENCE_GROUP_HEADER == 0x10");
    PASS(TTIOTransportPacketReferenceChromosome  == 0x11,
         "REFERENCE_CHROMOSOME == 0x11");
    PASS(TTIOTransportPacketEndOfReferenceGroup  == 0x12,
         "END_OF_REFERENCE_GROUP == 0x12");
    PASS(TTIOTransportPacketImageHeader          == 0x13,
         "IMAGE_HEADER == 0x13");
    PASS(TTIOTransportPacketImagePixel           == 0x14,
         "IMAGE_PIXEL == 0x14");
    PASS(TTIOTransportPacketEndOfImage           == 0x15,
         "END_OF_IMAGE == 0x15");
    PASS(TTIOTransportPacketIdentificationsTable == 0x16,
         "IDENTIFICATIONS_TABLE == 0x16");
    PASS(TTIOTransportPacketQuantificationsTable == 0x17,
         "QUANTIFICATIONS_TABLE == 0x17");
    PASS(TTIOTransportPacketDatasetProvenance    == 0x18,
         "DATASET_PROVENANCE == 0x18");
    PASS(TTIOTransportPacketSubjectMetadata      == 0x19,
         "SUBJECT_METADATA == 0x19");
    PASS(TTIOTransportPacketSampleMetadata       == 0x1A,
         "SAMPLE_METADATA == 0x1A");
    PASS(TTIOTransportPacketEncryptionAlgorithm  == 0x1B,
         "ENCRYPTION_ALGORITHM == 0x1B");

    /* Existing 0xFF terminator must remain unchanged. */
    PASS(TTIOTransportPacketEndOfStream == 0xFF,
         "END_OF_STREAM still == 0xFF (no regression)");

    /* Feature-flag string parity. */
    PASS([@"transport_v0_11" isEqualToString:TTIOTransportV011Feature],
         "TTIOTransportV011Feature == @\"transport_v0_11\"");
}
