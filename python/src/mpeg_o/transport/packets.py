"""Packet encoding primitives for the MPEG-O transport format.

All integers and floats are little-endian on the wire. Strings are
UTF-8 with explicit ``uint16`` or ``uint32`` length prefixes and are
NOT NUL-terminated.
"""
from __future__ import annotations

import struct
import time
from dataclasses import dataclass, field
from enum import IntEnum, IntFlag

HEADER_MAGIC = b"MO"
VERSION = 1
HEADER_SIZE = 24

# Little-endian, 2-byte magic, uint8 version, uint8 packet_type,
# uint16 flags, uint16 dataset_id, uint32 au_sequence, uint32
# payload_length, uint64 timestamp_ns.
_HEADER_FMT = "<2sBBHHIIQ"


class PacketType(IntEnum):
    """Transport packet types. See ``docs/transport-spec.md`` §3.2."""

    STREAM_HEADER = 0x01
    DATASET_HEADER = 0x02
    ACCESS_UNIT = 0x03
    PROTECTION_METADATA = 0x04
    ANNOTATION = 0x05
    PROVENANCE = 0x06
    CHROMATOGRAM = 0x07
    END_OF_DATASET = 0x08
    END_OF_STREAM = 0xFF


class PacketFlag(IntFlag):
    ENCRYPTED = 0x0001
    COMPRESSED = 0x0002
    HAS_CHECKSUM = 0x0004
    # v1.0: set in addition to ENCRYPTED when the AU's semantic header
    # fields are also AES-GCM encrypted. See transport-spec §4.3.3.
    # Readers MUST reject ENCRYPTED_HEADER without ENCRYPTED.
    ENCRYPTED_HEADER = 0x0008


# -------------------------------------------------------------- CRC-32C

_CRC32C_POLY_REFLECTED = 0x82F63B78


def _build_crc32c_table() -> tuple[int, ...]:
    table: list[int] = [0] * 256
    for b in range(256):
        crc = b
        for _ in range(8):
            crc = (crc >> 1) ^ (_CRC32C_POLY_REFLECTED if crc & 1 else 0)
        table[b] = crc
    return tuple(table)


_CRC32C_TABLE = _build_crc32c_table()


def crc32c(data: bytes) -> int:
    """CRC-32C (Castagnoli, reflected) of ``data``.

    Matches ``google-crc32c`` and ``java.util.zip.CRC32C`` output.
    Used when :attr:`PacketFlag.HAS_CHECKSUM` is set.
    """
    crc = 0xFFFFFFFF
    table = _CRC32C_TABLE
    for byte in data:
        crc = (crc >> 8) ^ table[(crc ^ byte) & 0xFF]
    return crc ^ 0xFFFFFFFF


# -------------------------------------------------------------- PacketHeader


@dataclass(frozen=True, slots=True)
class PacketHeader:
    """24-byte transport packet header."""

    packet_type: int
    flags: int = 0
    dataset_id: int = 0
    au_sequence: int = 0
    payload_length: int = 0
    timestamp_ns: int = 0

    def to_bytes(self) -> bytes:
        return struct.pack(
            _HEADER_FMT,
            HEADER_MAGIC,
            VERSION,
            int(self.packet_type) & 0xFF,
            int(self.flags) & 0xFFFF,
            int(self.dataset_id) & 0xFFFF,
            int(self.au_sequence) & 0xFFFFFFFF,
            int(self.payload_length) & 0xFFFFFFFF,
            int(self.timestamp_ns) & 0xFFFFFFFFFFFFFFFF,
        )

    @classmethod
    def from_bytes(cls, data: bytes) -> "PacketHeader":
        if len(data) < HEADER_SIZE:
            raise ValueError(
                f"packet header needs {HEADER_SIZE} bytes, got {len(data)}"
            )
        magic, version, ptype, flags, did, aus, plen, ts = struct.unpack_from(
            _HEADER_FMT, data, 0
        )
        if magic != HEADER_MAGIC:
            raise ValueError(f"invalid packet magic: {magic!r}")
        if version != VERSION:
            raise ValueError(f"unsupported transport version: {version}")
        return cls(ptype, flags, did, aus, plen, ts)


# -------------------------------------------------------------- ChannelData


@dataclass(slots=True)
class ChannelData:
    """One signal channel inside an :class:`AccessUnit`.

    ``precision`` and ``compression`` are the wire encoding — the
    :attr:`data` bytes are already encoded. The codec does not
    transcode channels; round-tripping preserves the source encoding.
    """

    name: str
    precision: int  # matches ``Precision`` enum
    compression: int  # matches ``Compression`` enum
    n_elements: int
    data: bytes

    def to_bytes(self) -> bytes:
        name_bytes = self.name.encode("utf-8")
        return (
            struct.pack("<H", len(name_bytes))
            + name_bytes
            + struct.pack(
                "<BBII",
                int(self.precision) & 0xFF,
                int(self.compression) & 0xFF,
                int(self.n_elements) & 0xFFFFFFFF,
                len(self.data) & 0xFFFFFFFF,
            )
            + self.data
        )

    @classmethod
    def from_buffer(cls, buf: bytes, offset: int) -> tuple["ChannelData", int]:
        (name_len,) = struct.unpack_from("<H", buf, offset)
        offset += 2
        name = bytes(buf[offset:offset + name_len]).decode("utf-8")
        offset += name_len
        precision, compression, n_elements, data_length = struct.unpack_from(
            "<BBII", buf, offset
        )
        offset += 10
        data = bytes(buf[offset:offset + data_length])
        offset += data_length
        return (
            cls(name=name, precision=precision, compression=compression,
                n_elements=n_elements, data=data),
            offset,
        )


# -------------------------------------------------------------- AccessUnit

# AU fixed-prefix layout (§4.3): spectrum_class(u8) + acquisition_mode(u8) +
# ms_level(u8) + polarity(u8) + retention_time(f64) + precursor_mz(f64) +
# precursor_charge(u8) + ion_mobility(f64) + base_peak_intensity(f64) +
# n_channels(u8). Total 38 bytes.


@dataclass(slots=True)
class AccessUnit:
    """One spectrum as a transport-layer value.

    The fixed-prefix fields are the **filter keys** a server uses for
    selective access. Channel bytes travel in :attr:`channels`.
    """

    spectrum_class: int  # 0=MassSpectrum, 1=NMRSpectrum, 2=NMR2D,
    #                     3=FID, 4=MSImagePixel
    acquisition_mode: int
    ms_level: int
    polarity: int  # wire: 0=positive, 1=negative, 2=unknown
    retention_time: float
    precursor_mz: float
    precursor_charge: int
    ion_mobility: float
    base_peak_intensity: float
    channels: list[ChannelData] = field(default_factory=list)

    # MSImagePixel extension (written only when ``spectrum_class == 4``).
    pixel_x: int = 0
    pixel_y: int = 0
    pixel_z: int = 0

    def to_bytes(self) -> bytes:
        prefix = (
            struct.pack(
                "<BBBB",
                int(self.spectrum_class) & 0xFF,
                int(self.acquisition_mode) & 0xFF,
                int(self.ms_level) & 0xFF,
                int(self.polarity) & 0xFF,
            )
            + struct.pack("<dd", float(self.retention_time), float(self.precursor_mz))
            + struct.pack("<B", int(self.precursor_charge) & 0xFF)
            + struct.pack("<dd", float(self.ion_mobility), float(self.base_peak_intensity))
            + struct.pack("<B", len(self.channels) & 0xFF)
        )
        body = prefix + b"".join(ch.to_bytes() for ch in self.channels)
        if self.spectrum_class == 4:
            body += struct.pack(
                "<III",
                int(self.pixel_x) & 0xFFFFFFFF,
                int(self.pixel_y) & 0xFFFFFFFF,
                int(self.pixel_z) & 0xFFFFFFFF,
            )
        return body

    @classmethod
    def from_bytes(cls, data: bytes) -> "AccessUnit":
        if len(data) < 38:
            raise ValueError(f"access unit payload too short: {len(data)}")
        spectrum_class, acquisition_mode, ms_level, polarity = struct.unpack_from(
            "<BBBB", data, 0
        )
        retention_time, precursor_mz = struct.unpack_from("<dd", data, 4)
        (precursor_charge,) = struct.unpack_from("<B", data, 20)
        ion_mobility, base_peak_intensity = struct.unpack_from("<dd", data, 21)
        (n_channels,) = struct.unpack_from("<B", data, 37)
        offset = 38
        channels: list[ChannelData] = []
        for _ in range(n_channels):
            ch, offset = ChannelData.from_buffer(data, offset)
            channels.append(ch)
        pixel_x = pixel_y = pixel_z = 0
        if spectrum_class == 4:
            if len(data) - offset < 12:
                raise ValueError("MSImagePixel AU missing pixel coordinates")
            pixel_x, pixel_y, pixel_z = struct.unpack_from("<III", data, offset)
            offset += 12
        return cls(
            spectrum_class=spectrum_class,
            acquisition_mode=acquisition_mode,
            ms_level=ms_level,
            polarity=polarity,
            retention_time=retention_time,
            precursor_mz=precursor_mz,
            precursor_charge=precursor_charge,
            ion_mobility=ion_mobility,
            base_peak_intensity=base_peak_intensity,
            channels=channels,
            pixel_x=pixel_x,
            pixel_y=pixel_y,
            pixel_z=pixel_z,
        )


# -------------------------------------------------------------- helpers


def now_ns() -> int:
    return time.time_ns()


def pack_string(s: str, *, width: int = 2) -> bytes:
    """Encode a UTF-8 string with a length prefix (``width=2`` → uint16,
    ``width=4`` → uint32). Matches the ``{uint<N> len, bytes[len]}``
    wire convention used throughout the transport format.
    """
    encoded = s.encode("utf-8")
    if width == 2:
        if len(encoded) > 0xFFFF:
            raise ValueError(f"string too long for uint16 prefix: {len(encoded)}")
        return struct.pack("<H", len(encoded)) + encoded
    if width == 4:
        return struct.pack("<I", len(encoded) & 0xFFFFFFFF) + encoded
    raise ValueError(f"unsupported prefix width: {width}")


def unpack_string(buf: bytes, offset: int, *, width: int = 2) -> tuple[str, int]:
    """Inverse of :func:`pack_string`."""
    if width == 2:
        (length,) = struct.unpack_from("<H", buf, offset)
        offset += 2
    elif width == 4:
        (length,) = struct.unpack_from("<I", buf, offset)
        offset += 4
    else:
        raise ValueError(f"unsupported prefix width: {width}")
    value = bytes(buf[offset:offset + length]).decode("utf-8")
    return value, offset + length
