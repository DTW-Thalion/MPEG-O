"""Packed storage for embedded reference chromosomes — 2-bit body + run mask.

Layout of a ``data_packed`` stream (big-endian, self-contained; the
BASE_PACK per-byte mask is 5 bytes per exception, which explodes on
the multi-megabase N runs every real chromosome carries, so this
layout records exceptions as runs instead):

    Offset   Size  Field
    ──────   ────  ─────────────────────────────────────────────
    0        1     version          (0x01)
    1        4     original_length  (uint32 BE)
    5        4     run_count        (uint32 BE)
    9        var   runs             (run_count x 8 bytes:
                                      uint32 BE position,
                                      uint32 BE length)
    9+8*rc   var   run_bytes        (sum of run lengths — the
                                      original bytes of every run,
                                      concatenated in run order)
    ...      var   packed_body      (ceil(n_acgt / 4) bytes;
                                      2-bit big-endian within byte,
                                      ACGT bytes only, in order,
                                      exception positions excluded)

Runs are maximal stretches of non-``ACGT`` (uppercase) bytes, sorted
ascending and non-overlapping. ``n_acgt = original_length - sum(run
lengths)``. Decode re-interleaves: walk positions 0..N, emitting run
bytes inside runs and unpacked ACGT bytes elsewhere.

Writers only use this layout when it wins: sequences whose packable
fraction is below ``MIN_PACKABLE_FRACTION`` (soft-masked lowercase
genomes, IUPAC-dense contigs) stay in the raw ``data`` layout.
"""
from __future__ import annotations

import struct

import numpy as np

VERSION = 0x01
HEADER_LEN = 9
RUN_ENTRY_LEN = 8

# Below this ACGT fraction the packed layout loses to raw+zlib and the
# writer keeps the legacy layout.
MIN_PACKABLE_FRACTION = 0.5

_CODE = np.full(256, 255, dtype=np.uint8)
_CODE[ord("A")] = 0
_CODE[ord("C")] = 1
_CODE[ord("G")] = 2
_CODE[ord("T")] = 3


def packable_fraction(data: bytes) -> float:
    """Fraction of bytes that are uppercase ACGT (1.0 for empty input)."""
    if not data:
        return 1.0
    arr = np.frombuffer(data, dtype=np.uint8)
    return float(np.count_nonzero(_CODE[arr] != 255)) / len(arr)


def encode(data: bytes) -> bytes:
    """Pack ``data`` into the ``data_packed`` layout. Lossless for any
    byte content; callers should gate on :func:`packable_fraction`."""
    n = len(data)
    if n > 0xFFFFFFFF:
        raise ValueError(f"sequence too long for uint32 length: {n}")
    arr = np.frombuffer(data, dtype=np.uint8)
    codes = _CODE[arr]
    exc = codes == 255

    # Maximal exception runs from the boundary positions of `exc`.
    boundaries = np.flatnonzero(np.diff(exc.astype(np.int8)))
    starts_ends = np.concatenate([[0], boundaries + 1, [n]]) if n else np.array([0, 0])
    runs: list[tuple[int, int]] = []
    for i in range(len(starts_ends) - 1):
        s, e = int(starts_ends[i]), int(starts_ends[i + 1])
        if s < e and exc[s]:
            runs.append((s, e - s))

    out = bytearray()
    out += struct.pack(">BII", VERSION, n, len(runs))
    for pos, length in runs:
        out += struct.pack(">II", pos, length)
    for pos, length in runs:
        out += data[pos:pos + length]

    acgt = codes[~exc]
    pad = (-len(acgt)) % 4
    if pad:
        acgt = np.concatenate([acgt, np.zeros(pad, dtype=np.uint8)])
    q = acgt.reshape(-1, 4)
    body = (q[:, 0] << 6) | (q[:, 1] << 4) | (q[:, 2] << 2) | q[:, 3]
    out += body.tobytes()
    return bytes(out)


def write_chromosome_dataset(chrom_group, seq: bytes) -> None:
    """Write one chromosome's bytes under ``chrom_group`` — as
    ``data_packed`` when the packed layout is smaller, else as the
    legacy raw ``data`` dataset. Both get the ZLIB filter; the entropy
    stage runs over the packed body when packing wins (chr22: 8.24 MB
    vs 9.71 MB raw+zlib)."""
    from .. import _hdf5_io as io
    from ..enums import Compression as _Compression
    from ..enums import Precision as _Precision

    packed: bytes | None = None
    if packable_fraction(seq) >= MIN_PACKABLE_FRACTION:
        candidate = encode(seq)
        if len(candidate) < len(seq):
            packed = candidate
    name = "data_packed" if packed is not None else "data"
    payload = packed if packed is not None else seq
    arr = np.frombuffer(payload, dtype=np.uint8)
    ds = chrom_group.create_dataset(
        name,
        _Precision.UINT8,
        length=int(arr.shape[0]),
        chunk_size=io.DEFAULT_SIGNAL_CHUNK,
        compression=_Compression.ZLIB,
        compression_level=6,
    )
    ds.write(arr)


def read_chromosome_bytes(chrom_group) -> bytes:
    """Read one chromosome's bytes from ``chrom_group``, decoding the
    ``data_packed`` layout when present and falling back to the legacy
    raw ``data`` dataset otherwise."""
    if chrom_group.has_child("data_packed"):
        ds = chrom_group.open_dataset("data_packed")
        try:
            return decode(bytes(ds.read()))
        finally:
            ds.close()
    ds = chrom_group.open_dataset("data")
    try:
        return bytes(ds.read())
    finally:
        ds.close()


def decode(stream: bytes) -> bytes:
    """Inverse of :func:`encode`."""
    if len(stream) < HEADER_LEN:
        raise ValueError("packed reference stream shorter than its header")
    version, n, run_count = struct.unpack_from(">BII", stream, 0)
    if version != VERSION:
        raise ValueError(f"unknown packed reference version {version:#04x}")
    off = HEADER_LEN
    runs = []
    prev_end = -1
    for _ in range(run_count):
        pos, length = struct.unpack_from(">II", stream, off)
        off += RUN_ENTRY_LEN
        if length == 0 or pos <= prev_end or pos + length > n:
            raise ValueError("malformed exception run table")
        runs.append((pos, length))
        prev_end = pos + length - 1
    run_total = sum(length for _, length in runs)
    run_bytes = stream[off:off + run_total]
    if len(run_bytes) != run_total:
        raise ValueError("packed reference stream truncated in run bytes")
    off += run_total

    n_acgt = n - run_total
    body_len = (n_acgt + 3) // 4
    body = np.frombuffer(stream[off:off + body_len], dtype=np.uint8)
    if len(body) != body_len:
        raise ValueError("packed reference stream truncated in body")

    # Unpack 2-bit slots to ACGT bytes.
    lut = np.frombuffer(b"ACGT", dtype=np.uint8)
    slots = np.empty(body_len * 4, dtype=np.uint8)
    slots[0::4] = lut[(body >> 6) & 0b11]
    slots[1::4] = lut[(body >> 4) & 0b11]
    slots[2::4] = lut[(body >> 2) & 0b11]
    slots[3::4] = lut[body & 0b11]
    acgt = slots[:n_acgt]

    out = np.empty(n, dtype=np.uint8)
    exc_mask = np.zeros(n, dtype=bool)
    cursor = 0
    for pos, length in runs:
        exc_mask[pos:pos + length] = True
        out[pos:pos + length] = np.frombuffer(
            run_bytes[cursor:cursor + length], dtype=np.uint8)
        cursor += length
    out[~exc_mask] = acgt
    return out.tobytes()
