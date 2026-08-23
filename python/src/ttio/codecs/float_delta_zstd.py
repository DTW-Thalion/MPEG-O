"""FLOAT_DELTA_ZSTD — lossless float64 channel codec (codec id 17).

Per block of ``BLOCK_SIZE`` values: view the float64 bit patterns as
uint64, then take whichever of the four transforms yields the smaller
stream (bit 0 is a delta mod 2**64, bit 1 keeps the values as plain
little-endian uint64 instead of 8 byte planes), and zstd-compress the
result as one RFC 8878 frame.

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
                    1  transform    (bit 0 delta, bit 1 plain)
                    4  body_length  (u32)
                    body: one zstd frame of the block

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
#: Bit 0 is a prefix delta on the uint64 bit view; bit 1 puts the values
#: in the frame as plain little-endian uint64 rather than 8 byte planes.
#: The transpose pays on intensity arrays and costs on m/z, so both are
#: chosen per block by exact size.
TRANSFORM_DELTA = 0x01
TRANSFORM_PLAIN = 0x02
TRANSFORM_MASK = 0x03

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


def _plain(u: np.ndarray) -> bytes:
    """uint64 array -> plain little-endian bytes."""
    return np.ascontiguousarray(u, dtype="<u8").tobytes()


def _unplain(buf: bytes, n: int) -> np.ndarray:
    return np.frombuffer(buf, dtype="<u8", count=n).astype(np.uint64, copy=False)


def _detransform(buf: bytes, n: int, transform: int) -> np.ndarray:
    """Block body bytes -> the uint64 values they encode."""
    if transform & ~TRANSFORM_MASK:
        raise ValueError(f"unknown FDZ1 transform {transform:#04x}")
    u = _unplain(buf, n) if transform & TRANSFORM_PLAIN else _untranspose(buf, n)
    if transform & TRANSFORM_DELTA:
        u = np.cumsum(u, dtype=np.uint64)
    return u


def header_bytes(n_values: int, n_blocks: int, block_size: int = BLOCK_SIZE) -> bytes:
    """The 22-byte FDZ1 stream header."""
    return MAGIC + struct.pack("<BBQII", VERSION, 0, int(n_values), int(block_size), int(n_blocks))


def encode_block(values: np.ndarray) -> tuple[int, bytes]:
    """Encode one block (at most BLOCK_SIZE float64 values):
    returns (transform, zstd body) for the smallest of the four."""
    import zstandard

    if values.dtype != np.float64:
        raise ValueError(f"FLOAT_DELTA_ZSTD encodes float64 only, got {values.dtype}")
    if len(values) == 0 or len(values) > BLOCK_SIZE:
        raise ValueError(f"FDZ1 block must hold 1..{BLOCK_SIZE} values, got {len(values)}")
    comp = zstandard.ZstdCompressor(level=ZSTD_LEVEL)
    u = np.ascontiguousarray(values).view(np.uint64)
    d = np.empty_like(u)
    d[0] = u[0]
    np.subtract(u[1:], u[:-1], out=d[1:])
    bodies = {
        TRANSFORM_NONE: comp.compress(_transpose(u)),
        TRANSFORM_DELTA: comp.compress(_transpose(d)),
        TRANSFORM_PLAIN: comp.compress(_plain(u)),
        TRANSFORM_PLAIN | TRANSFORM_DELTA: comp.compress(_plain(d)),
    }
    best = min(bodies, key=lambda t: (len(bodies[t]), t))
    return best, bodies[best]


def block_bytes(transform: int, body: bytes) -> bytes:
    """One block as it appears in the stream: transform byte, body length, body."""
    return struct.pack("<BI", transform, len(body)) + body


def encode(values: np.ndarray) -> bytes:
    """Encode a float64 array into a self-contained FDZ1 stream."""
    if values.dtype != np.float64:
        raise ValueError(f"FLOAT_DELTA_ZSTD encodes float64 only, got {values.dtype}")
    n = len(values)
    n_blocks = (n + BLOCK_SIZE - 1) // BLOCK_SIZE
    out = bytearray(header_bytes(n, n_blocks))
    for bi in range(n_blocks):
        transform, body = encode_block(values[bi * BLOCK_SIZE:(bi + 1) * BLOCK_SIZE])
        out += block_bytes(transform, body)
    return bytes(out)


def decode_block_bytes(transform: int, body: bytes, blk_n: int) -> np.ndarray:
    """Decode one block body to blk_n float64 values."""
    import zstandard

    raw = zstandard.ZstdDecompressor().decompress(body, max_output_size=blk_n * 8)
    if len(raw) != blk_n * 8:
        raise ValueError("FDZ1 block inflated to the wrong size")
    u = _detransform(raw, blk_n, transform)
    return np.ascontiguousarray(u).view(np.float64)


class BlockTable:
    """Where each block of an FDZ1 stream lives, read from a dataset
    without loading the bodies (spec 3, per-block decode)."""

    __slots__ = ("n_values", "block_size", "n_blocks", "offsets", "transforms", "lengths")

    def __init__(self, n_values, block_size, n_blocks, offsets, transforms, lengths):
        self.n_values, self.block_size, self.n_blocks = n_values, block_size, n_blocks
        self.offsets, self.transforms, self.lengths = offsets, transforms, lengths

    def block_values(self, k: int) -> int:
        return min(self.block_size, self.n_values - k * self.block_size)


def read_block_table(read_bytes) -> BlockTable:
    """Build the block table by reading only the stream header and the
    5-byte block headers. read_bytes(offset, count) -> bytes."""
    hdr = bytes(read_bytes(0, HEADER_LEN))
    if len(hdr) < HEADER_LEN or hdr[:4] != MAGIC:
        raise ValueError("not an FDZ1 stream")
    version, _flags, n, block_size, n_blocks = struct.unpack_from("<BBQII", hdr, 4)
    if version != VERSION:
        raise ValueError(f"unknown FDZ1 version {version:#04x}")
    if block_size == 0 or n_blocks != (n + block_size - 1) // block_size:
        raise ValueError("malformed FDZ1 header")
    offsets, transforms, lengths = [], [], []
    off = HEADER_LEN
    for _ in range(n_blocks):
        bh = bytes(read_bytes(off, 5))
        if len(bh) < 5:
            raise ValueError("FDZ1 stream truncated at block header")
        transform, body_len = struct.unpack_from("<BI", bh, 0)
        offsets.append(off + 5)
        transforms.append(transform)
        lengths.append(body_len)
        off += 5 + body_len
    return BlockTable(int(n), int(block_size), int(n_blocks), offsets, transforms, lengths)


def decode_block(read_bytes, table: BlockTable, k: int) -> np.ndarray:
    """Decode block k of a stream addressed by read_bytes."""
    body = bytes(read_bytes(table.offsets[k], table.lengths[k]))
    if len(body) != table.lengths[k]:
        raise ValueError("FDZ1 stream truncated in block body")
    return decode_block_bytes(table.transforms[k], body, table.block_values(k))


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
        raw = dec.decompress(body, max_output_size=blk_n * 8)
        if len(raw) != blk_n * 8:
            raise ValueError("FDZ1 block inflated to the wrong size")
        out[bi * block_size:bi * block_size + blk_n] = _detransform(raw, blk_n, transform)
    if off != len(stream):
        raise ValueError("trailing bytes after the last FDZ1 block")
    return out.view(np.float64)
