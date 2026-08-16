"""FLOAT_DELTA_ZSTD — lossless float64 channel codec (codec id 17).

Spec: ``docs/superpowers/specs/2026-08-16-float-delta-codec-design.md``.
Per block of ``BLOCK_SIZE`` values: view the float64 bit patterns as
uint64, apply the transform that yields the smaller stream
(``0x00`` none / ``0x01`` delta mod 2**64), transpose the 8 byte
planes, and zstd-compress the planes as one RFC 8878 frame.

Values round-trip bit-exactly (NaN payloads, signed zeros, Inf).
Per the spec's Option B decision, encoders MAY differ byte-wise
across languages (zstd builds differ); decoders MUST accept any
spec-conforming stream. The golden fixture pins the DECODE side.

Wire format (little-endian):

    Offset  Size  Field
    0       4     magic   "FDZ1"
    4       1     version (0x01)
    5       1     flags   (0x00; reserved)
    6       8     n_values      (u64)
    14      4     block_size    (u32, values per block)
    18      4     n_blocks      (u32)
    22      var   per block:
                    1  transform    (0x00 none, 0x01 delta)
                    4  body_length  (u32)
                    body: one zstd frame of the transposed planes

Cross-language equivalents:
    Java: ``global.thalion.ttio.codecs.FloatDeltaZstd``
    ObjC: ``TTIOFloatDeltaZstd`` (Codecs/TTIOFloatDeltaZstd.{h,m})
"""
from __future__ import annotations

import struct

import numpy as np

MAGIC = b"FDZ1"
VERSION = 0x01
HEADER_LEN = 22
BLOCK_SIZE = 1 << 20          # 1 Mi values = 8 MiB raw per block
TRANSFORM_NONE = 0x00
TRANSFORM_DELTA = 0x01

#: zstd level used by this encoder. Wire-invisible; decoders accept
#: any level.
ZSTD_LEVEL = 9


def _transpose(u: np.ndarray) -> bytes:
    """uint64 array -> concatenated byte planes (plane 0 = LSBs)."""
    b = u.view(np.uint8).reshape(-1, 8)
    return np.ascontiguousarray(b.T).tobytes()


def _untranspose(buf: bytes, n: int) -> np.ndarray:
    b = np.frombuffer(buf, dtype=np.uint8).reshape(8, n)
    return np.ascontiguousarray(b.T).reshape(-1).view(np.uint64)


def encode(values: np.ndarray) -> bytes:
    """Encode a float64 array into a self-contained FDZ1 stream."""
    import zstandard

    if values.dtype != np.float64:
        raise ValueError(f"FLOAT_DELTA_ZSTD encodes float64 only, got {values.dtype}")
    u_all = np.ascontiguousarray(values).view(np.uint64)
    n = len(u_all)
    n_blocks = (n + BLOCK_SIZE - 1) // BLOCK_SIZE
    comp = zstandard.ZstdCompressor(level=ZSTD_LEVEL)

    out = bytearray()
    out += MAGIC
    out += struct.pack("<BBQII", VERSION, 0, n, BLOCK_SIZE, n_blocks)
    for bi in range(n_blocks):
        u = u_all[bi * BLOCK_SIZE:(bi + 1) * BLOCK_SIZE]
        d = np.empty_like(u)
        d[0] = u[0]
        np.subtract(u[1:], u[:-1], out=d[1:])
        body_none = comp.compress(_transpose(u))
        body_delta = comp.compress(_transpose(d))
        if len(body_delta) < len(body_none):
            transform, body = TRANSFORM_DELTA, body_delta
        else:
            transform, body = TRANSFORM_NONE, body_none
        out += struct.pack("<BI", transform, len(body))
        out += body
    return bytes(out)


def decode(stream: bytes) -> np.ndarray:
    """Decode an FDZ1 stream back to the exact float64 array."""
    import zstandard

    if len(stream) < HEADER_LEN or stream[:4] != MAGIC:
        raise ValueError("not an FDZ1 stream")
    version, _flags, n, block_size, n_blocks = struct.unpack_from(
        "<BBQII", stream, 4)
    if version != VERSION:
        raise ValueError(f"unknown FDZ1 version {version:#04x}")
    if block_size == 0 or n_blocks != (n + block_size - 1) // block_size:
        raise ValueError("malformed FDZ1 header")
    dec = zstandard.ZstdDecompressor()

    out = np.empty(n, dtype=np.uint64)
    off = HEADER_LEN
    for bi in range(n_blocks):
        if off + 5 > len(stream):
            raise ValueError("FDZ1 stream truncated at block header")
        transform, body_len = struct.unpack_from("<BI", stream, off)
        off += 5
        body = stream[off:off + body_len]
        if len(body) != body_len:
            raise ValueError("FDZ1 stream truncated in block body")
        off += body_len
        blk_n = min(block_size, n - bi * block_size)
        planes = dec.decompress(body, max_output_size=blk_n * 8)
        if len(planes) != blk_n * 8:
            raise ValueError("FDZ1 block inflated to the wrong size")
        u = _untranspose(planes, blk_n)
        if transform == TRANSFORM_DELTA:
            u = np.cumsum(u, dtype=np.uint64)
        elif transform != TRANSFORM_NONE:
            raise ValueError(f"unknown FDZ1 transform {transform:#04x}")
        out[bi * block_size:bi * block_size + blk_n] = u
    if off != len(stream):
        raise ValueError("trailing bytes after the last FDZ1 block")
    return out.view(np.float64)
