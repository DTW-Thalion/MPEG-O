"""Unsigned LEB128 varint primitives — shared between codec paths.

Used by the cigars / mate_info_chrom rANS schema-lift writers and
readers to length-prefix variable-length string entries before the
length-concatenated byte stream is fed to / produced by the rANS
codec. Lifted out of the v1 NAME_TOKENIZED codec module (deleted in
the v1.0 reset / Phase 2c) so the helpers survive without dragging
the obsolete v1 codec along.

Cross-language: the same ULEB128 layout is reused everywhere TTI-O
needs a self-describing length prefix.
"""
from __future__ import annotations


#: Pre-computed single-byte varints for 0..127 (the hot path —
#: small lengths dominate in real CIGAR / chrom data). Each value
#: is its own LEB128 byte since 0..127 has no continuation bit.
_VARINT_SMALL: tuple[bytes, ...] = tuple(bytes([i]) for i in range(128))


def varint_encode(n: int) -> bytes:
    """Encode a non-negative integer as unsigned LEB128 (varint).

    Raises ValueError if n is negative; non-negative values of any
    magnitude are accepted (Python ints are unbounded).
    """
    if 0 <= n < 128:
        return _VARINT_SMALL[n]
    if n < 0:
        raise ValueError(f"varint_encode: negative value {n}")
    out = bytearray()
    while n >= 0x80:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n & 0x7F)
    return bytes(out)


def varint_decode(buf: bytes, offset: int) -> tuple[int, int]:
    """Decode an unsigned LEB128 varint at ``buf[offset:]``.

    Returns ``(value, new_offset)``. Raises ValueError if the varint
    runs off the end of ``buf`` before a byte with the continuation
    bit cleared is encountered.
    """
    value = 0
    shift = 0
    pos = offset
    n = len(buf)
    while True:
        if pos >= n:
            raise ValueError(
                f"varint runs off end of stream at offset {offset}"
            )
        b = buf[pos]
        pos += 1
        value |= (b & 0x7F) << shift
        if (b & 0x80) == 0:
            return value, pos
        shift += 7
