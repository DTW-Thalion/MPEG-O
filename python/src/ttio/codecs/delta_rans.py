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

import numpy as np

from . import rans

# Optional Cython accelerator for the inherently-serial LEB128 varint
# emit/parse loops. Byte-exact with the pure-Python fallbacks below (see
# setup.py for the extension declaration). When absent, the pure-Python
# loops are used and produce identical bytes, just slower.
try:
    from ._delta_rans import _delta_rans as _c  # type: ignore[import-not-found]
    _HAVE_C_EXTENSION = True
except ImportError:  # pragma: no cover — Cython optional
    _c = None
    _HAVE_C_EXTENSION = False

_MAGIC = b"DRA0"
_VERSION = 1
_HEADER_LEN = 8
_VALID_ELEMENT_SIZES = (1, 4, 8)

_STRUCT_FMTS = {1: "b", 4: "<i", 8: "<q"}
_BITS = {1: 8, 4: 32, 8: 64}

# Little-endian signed/unsigned numpy dtypes per element size. The signed
# dtype matches struct.pack('<bN'/'<iN'/'<qN') byte-for-byte; the unsigned
# view is used to reproduce the masked zigzag of the original scalar loop.
_NUMPY_DTYPE = {1: "<i1", 4: "<i4", 8: "<i8"}
_NUMPY_UDTYPE = {1: "<u1", 4: "<u4", 8: "<u8"}


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

    bits = _BITS[element_size]
    zz = _encode_zigzag(data, element_size, bits)

    if _HAVE_C_EXTENSION:
        # C LEB128 emit — byte-identical to the serial loop below.
        varint_bytes = _c.varint_encode_all(zz)
    else:
        # Variable-length varint emit stays serial (kept byte-identical).
        varint_buf = bytearray()
        for z in zz:
            varint_buf.extend(_varint_encode(int(z)))
        varint_bytes = bytes(varint_buf)

    body = rans.encode(varint_bytes, order=0)
    return header + body


def _encode_zigzag(data: bytes, element_size: int, bits: int) -> np.ndarray:
    """Return the per-element zigzag-encoded deltas as a uint64 array.

    Sizes 1 and 4 are vectorized with numpy; size 8 (int64) stays on the
    scalar loop. For bits < 64 numpy's fixed-width two's-complement wrap of
    np.diff matches the manual delta wrap exactly. For bits == 64 the scalar
    path computes deltas in Python's *unbounded* integers (it has no wrap
    clause), so a delta that overflows int64 -- e.g. INT64_MAX - (-1) --
    produces a different zigzag than numpy's wrapped int64 delta. Such inputs
    are not decodable by this codec anyway, but to keep the byte stream
    identical for ALL inputs the int64 path is left scalar.
    """
    if element_size == 8:
        mask = (1 << 64) - 1
        n = len(data) // 8
        values = struct.unpack(f"<{n}q", data)
        prev = 0
        out = np.empty(n, dtype=np.uint64)
        for idx, v in enumerate(values):
            delta = v - prev
            zz = ((delta << 1) ^ (delta >> 63)) & mask
            out[idx] = zz
            prev = v
        return out

    sdtype = np.dtype(_NUMPY_DTYPE[element_size])
    udtype = np.dtype(_NUMPY_UDTYPE[element_size])
    # np.diff with prepend=0 reproduces the scalar `delta = v - prev` (prev
    # starting at 0); in a fixed-width signed dtype it wraps in two's
    # complement, matching the manual [-2^(b-1), 2^(b-1)) wrap. Then
    # (delta << 1) ^ (delta >> (bits-1)) in the signed width, viewed as
    # unsigned, equals the masked zigzag of the scalar path. `>> (bits-1)`
    # is an arithmetic shift (0 for >=0, all-ones for <0) like Python's.
    vals = np.frombuffer(data, dtype=sdtype)
    with np.errstate(over="ignore"):
        deltas = np.diff(vals, prepend=sdtype.type(0))
        zz_signed = (deltas << 1) ^ (deltas >> (bits - 1))
    # Return as uint64 so the varint emit (C or Python) sees a uniform,
    # contiguous unsigned array. The widening from u1/u4 to u8 is value-
    # preserving (zigzag values are non-negative), so the emitted LEB128
    # bytes are unchanged.
    return zz_signed.view(udtype).astype(np.uint64)


def _decode_int64_scalar(zigzag_values) -> bytes:
    """Scalar int64 zigzag-decode + prefix sum (overflow fallback).

    Mirrors the original reference exactly: it sums in Python's unbounded
    integers and raises ``struct.error`` if a reconstructed value falls
    outside the int64 range. Only used when the vectorized path detects a
    signed-addition overflow, so byte-for-byte behavior (including the error)
    is preserved for malformed streams.
    """
    values: list[int] = []
    prev = 0
    for zz in zigzag_values:
        zz = int(zz)
        delta = (zz >> 1) ^ -(zz & 1)
        v = prev + delta
        values.append(v)
        prev = v
    return struct.pack(f"<{len(values)}q", *values)


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

    # Variable-length varint parse — C accelerator when available (returns a
    # uint64 numpy array), else the byte-identical serial Python loop (returns
    # a list). Both yield the same zigzag values.
    if _HAVE_C_EXTENSION:
        zz_arr = _c.varint_decode_all(varint_bytes)
    else:
        zz_arr = np.array(_varint_decode_all(varint_bytes), dtype=np.uint64)

    sdtype = np.dtype(_NUMPY_DTYPE[element_size])
    udtype = np.dtype(_NUMPY_UDTYPE[element_size])

    if element_size == 8:
        # Vectorized int64 zigzag-decode + prefix sum. zz arrives as uint64;
        # the signed delta is `(zz >> 1) ^ -(zz & 1)` in 64-bit two's
        # complement. cumsum in uint64 wraps mod 2**64, and viewing the result
        # as int64 reinterprets the bits — identical to the scalar
        # `v = prev + delta` for every sequence whose running sum stays in
        # int64 range. The little-endian signed dtype makes tobytes()
        # byte-identical to struct.pack('<...q').
        #
        # The scalar reference sums in Python's *unbounded* integers and raises
        # struct.error when a reconstructed value falls outside int64. To
        # preserve that behavior byte-for-byte we detect signed-addition
        # overflow vectorially (prev and delta same sign, result opposite sign)
        # and, if any step overflowed, defer to the scalar loop so the same
        # struct.error is raised.
        ones = np.uint64(1)
        delta = (zz_arr >> ones).view(sdtype) ^ -(zz_arr & ones).view(sdtype)
        with np.errstate(over="ignore"):
            vals_u = np.cumsum(delta.view(udtype), dtype=udtype)
        vals = vals_u.view(sdtype)
        # Signed overflow at step i: prev=vals[i-1], d=delta[i], r=vals[i];
        # overflow iff sign(prev)==sign(d) != sign(r). prev for i=0 is 0, so
        # the first step never overflows.
        prev = np.empty_like(vals)
        prev[0] = 0
        prev[1:] = vals[:-1]
        same_sign = (prev >= 0) == (delta >= 0)
        result_diff = (vals >= 0) != (prev >= 0)
        if np.any(same_sign & result_diff):
            return _decode_int64_scalar(zz_arr)
        return vals.tobytes()

    # Vectorized zigzag-decode + prefix sum (sizes 1 and 4). zz arrives
    # unsigned; the signed delta is `(zz >> 1) ^ -(zz & 1)` computed in the
    # fixed width. np.cumsum in the signed dtype wraps in two's complement,
    # reproducing the scalar `v = prev + delta` together with the bits<64
    # normalization (`v &= mask; if v >= half: v -= 1<<bits`). The
    # little-endian signed dtype makes tobytes() byte-identical to
    # struct.pack('<...').
    zz = zz_arr.astype(udtype)
    with np.errstate(over="ignore"):
        delta = (zz >> 1).view(sdtype) ^ -(zz & udtype.type(1)).view(sdtype)
        vals = np.cumsum(delta, dtype=sdtype)
    return vals.astype(sdtype).tobytes()
