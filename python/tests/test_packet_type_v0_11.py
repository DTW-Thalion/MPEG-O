"""v0.11 packet type constants — TTI-O Java parity (transport-spec §4)."""
from ttio.transport.packets import PacketType, TRANSPORT_V0_11_FEATURE


def test_v0_11_packet_types_have_expected_wire_bytes():
    assert PacketType.REFERENCE_GROUP_HEADER.value == 0x10
    assert PacketType.REFERENCE_CHROMOSOME.value == 0x11
    assert PacketType.END_OF_REFERENCE_GROUP.value == 0x12
    assert PacketType.IMAGE_HEADER.value == 0x13
    assert PacketType.IMAGE_PIXEL.value == 0x14
    assert PacketType.END_OF_IMAGE.value == 0x15
    assert PacketType.IDENTIFICATIONS_TABLE.value == 0x16
    assert PacketType.QUANTIFICATIONS_TABLE.value == 0x17
    assert PacketType.DATASET_PROVENANCE.value == 0x18
    assert PacketType.SUBJECT_METADATA.value == 0x19
    assert PacketType.SAMPLE_METADATA.value == 0x1A
    assert PacketType.ENCRYPTION_ALGORITHM.value == 0x1B


def test_v0_11_feature_flag_constant():
    assert TRANSPORT_V0_11_FEATURE == "transport_v0_11"


def test_from_wire_recognises_new_types():
    assert PacketType(0x13) == PacketType.IMAGE_HEADER
    assert PacketType(0x1B) == PacketType.ENCRYPTION_ALGORITHM
