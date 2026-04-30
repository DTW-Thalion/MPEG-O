"""DELTA_RANS_ORDER0 codec (M95, codec id 11).

Delta + zigzag + unsigned LEB128 varint + rANS order-0. Designed for
sorted-ascending integer channels (e.g. genomic positions) where deltas
are small and concentrated.

Cross-language equivalents:
    Objective-C: TTIODeltaRans (objc/Source/Codecs/TTIODeltaRans.{h,m})
    Java:        global.thalion.ttio.codecs.DeltaRans

Wire format:

    Offset  Size   Field
    0       4      magic: "DRA0"
    4       1      version: uint8 = 1
    5       1      element_size: uint8 (1, 4, or 8)
    6       2      reserved: uint8[2] = 0x00
    8       var    body: rANS order-0 encoded varint stream
"""
from __future__ import annotations

import struct

from . import rans

_MAGIC = b"DRA0"
_VERSION = 1
_HEADER_LEN = 8
_VALID_ELEMENT_SIZES = (1, 4, 8)

_STRUCT_FMTS = {1: "b", 4: "<i", 8: "<q"}
_BITS = {1: 8, 4: 32, 8: 64}


def _zigzag_encode(value: int) -> int:
    return (value << 1) ^ (value >> 63)


def _zigzag_decode(zz: int) -> int:
    return (zz >> 1) ^ -(zz & 1)


def _varint_encode(value: int) -> bytes:
    out = bytearray()
    while value > 0x7F:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value & 0x7F)
    return bytes(out)


def _varint_decode_all(data: bytes) -> list[int]:
    values: list[int] = []
    i = 0
    n = len(data)
    while i < n:
        value = 0
        shift = 0
        while True:
            if i >= n:
                raise ValueError("DELTA_RANS: truncated varint")
            b = data[i]
            i += 1
            value |= (b & 0x7F) << shift
            if (b & 0x80) == 0:
                break
            shift += 7
        values.append(value)
    return values


def encode(data: bytes, element_size: int) -> bytes:
    if element_size not in _VALID_ELEMENT_SIZES:
        raise ValueError(
            f"DELTA_RANS: element_size must be one of "
            f"{_VALID_ELEMENT_SIZES}, got {element_size}"
        )
    n_elements = len(data) // element_size
    if len(data) % element_size != 0:
        raise ValueError(
            f"DELTA_RANS: data length {len(data)} not a multiple of "
            f"element_size {element_size}"
        )

    header = _MAGIC + bytes([_VERSION, element_size, 0, 0])

    if n_elements == 0:
        return header + rans.encode(b"", order=0)

    fmt = f"<{n_elements}{_STRUCT_FMTS[element_size].lstrip('<')}"
    values = list(struct.unpack(fmt, data))

    bits = _BITS[element_size]
    mask = (1 << bits) - 1
    varint_buf = bytearray()
    prev = 0
    for v in values:
        delta = v - prev
        if bits < 64:
            if delta < -(1 << (bits - 1)):
                delta += 1 << bits
            elif delta >= (1 << (bits - 1)):
                delta -= 1 << bits
        zz = (delta << 1) ^ (delta >> (bits - 1))
        zz &= mask if bits < 64 else (1 << 64) - 1
        varint_buf.extend(_varint_encode(zz))
        prev = v

    body = rans.encode(bytes(varint_buf), order=0)
    return header + body


def decode(encoded: bytes) -> bytes:
    if len(encoded) < _HEADER_LEN:
        raise ValueError("DELTA_RANS: encoded data too short for header")
    if encoded[:4] != _MAGIC:
        raise ValueError(
            f"DELTA_RANS: bad magic {encoded[:4]!r} (expected {_MAGIC!r})"
        )
    version = encoded[4]
    if version != _VERSION:
        raise ValueError(
            f"DELTA_RANS: unsupported version {version} (expected {_VERSION})"
        )
    element_size = encoded[5]
    if element_size not in _VALID_ELEMENT_SIZES:
        raise ValueError(
            f"DELTA_RANS: invalid element_size {element_size}"
        )

    varint_bytes = rans.decode(encoded[_HEADER_LEN:])

    if len(varint_bytes) == 0:
        return b""

    zigzag_values = _varint_decode_all(varint_bytes)

    bits = _BITS[element_size]
    half = 1 << (bits - 1)
    mask = (1 << bits) - 1
    values: list[int] = []
    prev = 0
    for zz in zigzag_values:
        delta = (zz >> 1) ^ -(zz & 1)
        if bits < 64:
            if delta >= half:
                delta -= 1 << bits
            elif delta < -half:
                delta += 1 << bits
        v = prev + delta
        if bits < 64:
            v &= mask
            if v >= half:
                v -= 1 << bits
        values.append(v)
        prev = v

    fmt = f"<{len(values)}{_STRUCT_FMTS[element_size].lstrip('<')}"
    return struct.pack(fmt, *values)
