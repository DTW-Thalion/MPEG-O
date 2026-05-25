/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class PacketTypeTest {

    @Test
    void v0_11_packet_types_have_expected_wire_bytes() {
        assertEquals(0x10, PacketType.REFERENCE_GROUP_HEADER.wire());
        assertEquals(0x11, PacketType.REFERENCE_CHROMOSOME.wire());
        assertEquals(0x12, PacketType.END_OF_REFERENCE_GROUP.wire());
        assertEquals(0x13, PacketType.IMAGE_HEADER.wire());
        assertEquals(0x14, PacketType.IMAGE_PIXEL.wire());
        assertEquals(0x15, PacketType.END_OF_IMAGE.wire());
        assertEquals(0x16, PacketType.IDENTIFICATIONS_TABLE.wire());
        assertEquals(0x17, PacketType.QUANTIFICATIONS_TABLE.wire());
        assertEquals(0x18, PacketType.DATASET_PROVENANCE.wire());
        assertEquals(0x19, PacketType.SUBJECT_METADATA.wire());
        assertEquals(0x1A, PacketType.SAMPLE_METADATA.wire());
        assertEquals(0x1B, PacketType.ENCRYPTION_ALGORITHM.wire());
    }

    @Test
    void v0_11_feature_flag_constant() {
        assertEquals("transport_v0_11", PacketType.TRANSPORT_V0_11_FEATURE);
    }

    @Test
    void fromWire_recognises_new_types() {
        assertEquals(PacketType.IMAGE_HEADER, PacketType.fromWire(0x13));
        assertEquals(PacketType.ENCRYPTION_ALGORITHM, PacketType.fromWire(0x1B));
    }
}
