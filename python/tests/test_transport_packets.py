"""Unit tests for transport packet encoding (M67)."""
from __future__ import annotations

import struct

import pytest

from ttio.transport.packets import (
    HEADER_MAGIC,
    HEADER_SIZE,
    VERSION,
    AccessUnit,
    ChannelData,
    PacketFlag,
    PacketHeader,
    PacketType,
    crc32c,
    pack_string,
    unpack_string,
)


class TestPacketHeader:

    def test_round_trip_zero(self):
        h = PacketHeader(packet_type=PacketType.END_OF_STREAM)
        encoded = h.to_bytes()
        assert len(encoded) == HEADER_SIZE
        decoded = PacketHeader.from_bytes(encoded)
        assert decoded == h

    def test_round_trip_fully_populated(self):
        h = PacketHeader(
            packet_type=PacketType.ACCESS_UNIT,
            flags=int(PacketFlag.HAS_CHECKSUM),
            dataset_id=42,
            au_sequence=12345,
            payload_length=9999,
            timestamp_ns=1_700_000_000_000_000_000,
        )
        decoded = PacketHeader.from_bytes(h.to_bytes())
        assert decoded == h

    def test_magic_and_version(self):
        h = PacketHeader(packet_type=PacketType.STREAM_HEADER)
        encoded = h.to_bytes()
        assert encoded[:2] == HEADER_MAGIC
        assert encoded[2] == VERSION

    def test_rejects_bad_magic(self):
        raw = b"XX" + b"\x01\x01" + b"\x00" * (HEADER_SIZE - 4)
        with pytest.raises(ValueError, match="magic"):
            PacketHeader.from_bytes(raw)

    def test_rejects_bad_version(self):
        raw = b"TI" + b"\x99\x01" + b"\x00" * (HEADER_SIZE - 4)
        with pytest.raises(ValueError, match="version"):
            PacketHeader.from_bytes(raw)

    def test_rejects_truncated(self):
        with pytest.raises(ValueError, match="needs"):
            PacketHeader.from_bytes(b"\x00" * 10)


class TestChannelData:

    def test_round_trip(self):
        ch = ChannelData(
            name="intensity",
            precision=1,
            compression=0,
            n_elements=4,
            data=struct.pack("<dddd", 1.0, 2.0, 3.0, 4.0),
        )
        buf = ch.to_bytes()
        decoded, offset = ChannelData.from_buffer(buf, 0)
        assert offset == len(buf)
        assert decoded.name == "intensity"
        assert decoded.precision == 1
        assert decoded.compression == 0
        assert decoded.n_elements == 4
        assert decoded.data == ch.data

    def test_unicode_name(self):
        ch = ChannelData(
            name="μ/z",  # non-ASCII channel name
            precision=1,
            compression=0,
            n_elements=1,
            data=struct.pack("<d", 42.0),
        )
        decoded, _ = ChannelData.from_buffer(ch.to_bytes(), 0)
        assert decoded.name == "μ/z"

    def test_empty_data(self):
        ch = ChannelData(name="mz", precision=1, compression=0, n_elements=0, data=b"")
        decoded, _ = ChannelData.from_buffer(ch.to_bytes(), 0)
        assert decoded.data == b""
        assert decoded.n_elements == 0


class TestAccessUnit:

    def test_round_trip_mass_spectrum(self):
        au = AccessUnit(
            spectrum_class=0,
            acquisition_mode=0,
            ms_level=2,
            polarity=0,
            retention_time=123.456,
            precursor_mz=500.25,
            precursor_charge=2,
            ion_mobility=0.0,
            base_peak_intensity=1.0e6,
            channels=[
                ChannelData("mz", 1, 0, 3,
                            struct.pack("<ddd", 100.0, 200.0, 300.0)),
                ChannelData("intensity", 1, 0, 3,
                            struct.pack("<ddd", 1000.0, 2000.0, 3000.0)),
            ],
        )
        decoded = AccessUnit.from_bytes(au.to_bytes())
        assert decoded.spectrum_class == 0
        assert decoded.ms_level == 2
        assert decoded.retention_time == 123.456
        assert decoded.precursor_mz == 500.25
        assert decoded.precursor_charge == 2
        assert decoded.base_peak_intensity == 1.0e6
        assert len(decoded.channels) == 2
        assert decoded.channels[0].name == "mz"
        assert decoded.channels[1].name == "intensity"

    def test_msimage_pixel(self):
        au = AccessUnit(
            spectrum_class=4,
            acquisition_mode=6,
            ms_level=1,
            polarity=0,
            retention_time=0.0,
            precursor_mz=0.0,
            precursor_charge=0,
            ion_mobility=0.0,
            base_peak_intensity=500.0,
            channels=[ChannelData("intensity", 1, 0, 1, struct.pack("<d", 500.0))],
            pixel_x=10, pixel_y=20, pixel_z=0,
        )
        decoded = AccessUnit.from_bytes(au.to_bytes())
        assert decoded.spectrum_class == 4
        assert decoded.pixel_x == 10
        assert decoded.pixel_y == 20
        assert decoded.pixel_z == 0

    def test_genomic_read_round_trip(self):
        # M89.1: GenomicRead AU (spectrum_class==5) carries a
        # chromosome+position+mapq+flags suffix after channels.
        au = AccessUnit(
            spectrum_class=5,
            acquisition_mode=0,
            ms_level=0,
            polarity=2,
            retention_time=0.0,
            precursor_mz=0.0,
            precursor_charge=0,
            ion_mobility=0.0,
            base_peak_intensity=0.0,
            channels=[
                ChannelData("seq", 1, 0, 1, b"\x00" * 8),
            ],
            chromosome="chr1",
            position=123_456_789,
            mapping_quality=60,
            flags=0x0003,  # paired + proper pair
        )
        decoded = AccessUnit.from_bytes(au.to_bytes())
        assert decoded.spectrum_class == 5
        assert decoded.chromosome == "chr1"
        assert decoded.position == 123_456_789
        assert decoded.mapping_quality == 60
        assert decoded.flags == 0x0003
        assert len(decoded.channels) == 1

    def test_genomic_read_unmapped(self):
        # Unmapped reads use the BAM convention: chromosome="*",
        # position=-1. Flag bit 0x4 (segment unmapped) set.
        au = AccessUnit(
            spectrum_class=5,
            acquisition_mode=0, ms_level=0, polarity=2,
            retention_time=0.0, precursor_mz=0.0, precursor_charge=0,
            ion_mobility=0.0, base_peak_intensity=0.0,
            channels=[],
            chromosome="*",
            position=-1,
            mapping_quality=0,
            flags=0x0004,
        )
        decoded = AccessUnit.from_bytes(au.to_bytes())
        assert decoded.position == -1
        assert decoded.chromosome == "*"
        assert decoded.flags == 0x0004

    def test_genomic_read_long_chromosome(self):
        # Decoy contig names can be quite long.
        long_chr = "chr22_KI270739v1_random"
        au = AccessUnit(
            spectrum_class=5,
            acquisition_mode=0, ms_level=0, polarity=2,
            retention_time=0.0, precursor_mz=0.0, precursor_charge=0,
            ion_mobility=0.0, base_peak_intensity=0.0,
            channels=[],
            chromosome=long_chr, position=42, mapping_quality=255,
            flags=0xFFFF,
        )
        decoded = AccessUnit.from_bytes(au.to_bytes())
        assert decoded.chromosome == long_chr
        assert decoded.mapping_quality == 255
        assert decoded.flags == 0xFFFF

    def test_genomic_read_truncated_suffix_raises(self):
        # Missing the M89.1 fixed-suffix bytes on a spectrum_class==5 AU
        # should raise a clear ValueError, not silently decode to zeros.
        # Cut into the M89.1 fixed-suffix block (post-chromosome) by
        # 14 bytes so we drop into the middle of position+mapq+flags
        # — the M89.1 minimum "GenomicRead AU missing position/mapq/flags
        # suffix" error path. (Cutting only the M90.9 mate-extension
        # tail is a NO-OP per the back-compat rule of M90.9.)
        au = AccessUnit(
            spectrum_class=5,
            acquisition_mode=0, ms_level=0, polarity=2,
            retention_time=0.0, precursor_mz=0.0, precursor_charge=0,
            ion_mobility=0.0, base_peak_intensity=0.0,
            channels=[],
            chromosome="chr1", position=100, mapping_quality=60, flags=0,
        )
        full = au.to_bytes()
        # M89.1 fixed suffix is 11 bytes (i64 + u8 + u16); M90.9 mate
        # extension adds 12. Dropping 14 bytes lands inside the M89.1
        # block — guaranteed to trigger the M89.1 truncation error.
        truncated = full[:-14]
        with pytest.raises(ValueError, match="GenomicRead"):
            AccessUnit.from_bytes(truncated)

    def test_genomic_suffix_only_when_class_is_5(self):
        # An MS AU with chromosome accidentally set should not write a
        # genomic suffix — chromosome is silently ignored. Decoder
        # returns the default "" / 0 / 0 / 0 values.
        au = AccessUnit(
            spectrum_class=0,
            acquisition_mode=0, ms_level=1, polarity=0,
            retention_time=1.0, precursor_mz=0.0, precursor_charge=0,
            ion_mobility=0.0, base_peak_intensity=0.0,
            channels=[],
            chromosome="should-be-ignored",
            position=999, mapping_quality=42, flags=0xBEEF,
        )
        decoded = AccessUnit.from_bytes(au.to_bytes())
        assert decoded.spectrum_class == 0
        assert decoded.chromosome == ""
        assert decoded.position == 0
        assert decoded.mapping_quality == 0
        assert decoded.flags == 0

    def test_no_channels(self):
        au = AccessUnit(
            spectrum_class=0,
            acquisition_mode=0,
            ms_level=1,
            polarity=2,
            retention_time=1.0,
            precursor_mz=0.0,
            precursor_charge=0,
            ion_mobility=0.0,
            base_peak_intensity=0.0,
            channels=[],
        )
        decoded = AccessUnit.from_bytes(au.to_bytes())
        assert decoded.channels == []


class TestStrings:

    def test_uint16_round_trip(self):
        buf = pack_string("hello world", width=2)
        value, offset = unpack_string(buf, 0, width=2)
        assert value == "hello world"
        assert offset == len(buf)

    def test_uint32_round_trip(self):
        buf = pack_string("a" * 70000, width=4)
        value, offset = unpack_string(buf, 0, width=4)
        assert value == "a" * 70000
        assert offset == len(buf)

    def test_uint16_overflow_rejected(self):
        with pytest.raises(ValueError, match="too long"):
            pack_string("a" * 70000, width=2)


class TestCRC32C:

    def test_empty(self):
        # CRC-32C of empty string is 0 (Castagnoli initial=all-ones,
        # final XOR = all-ones → 0).
        assert crc32c(b"") == 0

    def test_known_vector(self):
        # google-crc32c known vectors:
        # "123456789" → 0xE3069283
        assert crc32c(b"123456789") == 0xE3069283

    def test_ascii(self):
        # "a" → 0xC1D04330 per crc32c.org / RFC 3720 test vectors
        assert crc32c(b"a") == 0xC1D04330
