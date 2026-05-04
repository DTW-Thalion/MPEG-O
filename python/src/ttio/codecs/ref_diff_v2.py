"""Python ctypes wrapper for ref_diff v2 (CRAM-style sequence diff codec).

Spec: docs/superpowers/specs/2026-05-03-ref-diff-v2-design.md

Encoded blob written as ``signal_channels/sequences/refdiff_v2`` uint8
dataset with ``@compression = 14`` (REF_DIFF_V2). Requires
``TTIO_RANS_LIB_PATH`` to point at a built ``libttio_rans.so``;
without it, ``HAVE_NATIVE_LIB`` is False and v2 write/read is
disabled.
"""
from __future__ import annotations

import ctypes
import numpy as np

from .fqzcomp_nx16_z import _native_lib, _HAVE_NATIVE_LIB

HAVE_NATIVE_LIB: bool = _HAVE_NATIVE_LIB

ERR_PARAM = -1
ERR_ALLOC = -2
ERR_CORRUPT = -3
ERR_ESC_LENGTH_MISMATCH = -6
ERR_RESERVED_ESC_STREAM = -7

_ERR_MESSAGES = {
    ERR_PARAM: "invalid parameters",
    ERR_ALLOC: "out of memory in native code",
    ERR_CORRUPT: "corrupt encoded blob",
    ERR_ESC_LENGTH_MISMATCH: "ESC substream length mismatch",
    ERR_RESERVED_ESC_STREAM: "reserved ESC stream_id seen",
}


class _Input(ctypes.Structure):
    _fields_ = [
        ("sequences",        ctypes.POINTER(ctypes.c_uint8)),
        ("offsets",          ctypes.POINTER(ctypes.c_uint64)),
        ("positions",        ctypes.POINTER(ctypes.c_int64)),
        ("cigar_strings",    ctypes.POINTER(ctypes.c_char_p)),
        ("n_reads",          ctypes.c_uint64),
        ("reference",        ctypes.POINTER(ctypes.c_uint8)),
        ("reference_length", ctypes.c_uint64),
        ("reads_per_slice",  ctypes.c_uint64),
        ("reference_md5",    ctypes.POINTER(ctypes.c_uint8)),
        ("reference_uri",    ctypes.c_char_p),
    ]


if HAVE_NATIVE_LIB:
    _lib = _native_lib

    _lib.ttio_ref_diff_v2_max_encoded_size.argtypes = [ctypes.c_uint64, ctypes.c_uint64]
    _lib.ttio_ref_diff_v2_max_encoded_size.restype = ctypes.c_size_t

    _lib.ttio_ref_diff_v2_encode.argtypes = [
        ctypes.POINTER(_Input),
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.POINTER(ctypes.c_size_t),
    ]
    _lib.ttio_ref_diff_v2_encode.restype = ctypes.c_int

    _lib.ttio_ref_diff_v2_decode.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),  # encoded
        ctypes.c_size_t,                 # encoded_size
        ctypes.POINTER(ctypes.c_int64),  # positions
        ctypes.POINTER(ctypes.c_char_p), # cigar_strings
        ctypes.c_uint64,                 # n_reads
        ctypes.POINTER(ctypes.c_uint8),  # reference
        ctypes.c_uint64,                 # reference_length
        ctypes.POINTER(ctypes.c_uint8),  # out_sequences
        ctypes.POINTER(ctypes.c_uint64), # out_offsets
    ]
    _lib.ttio_ref_diff_v2_decode.restype = ctypes.c_int


def encode(
    sequences: np.ndarray,        # uint8
    offsets: np.ndarray,          # uint64, n_reads + 1
    positions: np.ndarray,        # int64, n_reads
    cigar_strings: list[str],
    reference: bytes,
    reference_md5: bytes,         # 16 bytes
    reference_uri: str,
    reads_per_slice: int = 10_000,
) -> bytes:
    """Encode a slice of reads to the refdiff_v2 blob."""
    if not HAVE_NATIVE_LIB:
        raise RuntimeError(
            "ref_diff_v2.encode requires libttio_rans (set TTIO_RANS_LIB_PATH)")
    if len(reference_md5) != 16:
        raise ValueError("reference_md5 must be 16 bytes")

    seq = np.ascontiguousarray(sequences, dtype=np.uint8)
    off = np.ascontiguousarray(offsets, dtype=np.uint64)
    pos = np.ascontiguousarray(positions, dtype=np.int64)
    n = pos.shape[0]
    if off.shape[0] != n + 1:
        raise ValueError(f"offsets length must be n_reads + 1 = {n+1}")
    if len(cigar_strings) != n:
        raise ValueError(f"cigar_strings length must be n_reads = {n}")

    ref_arr = np.frombuffer(reference, dtype=np.uint8)
    md5_arr = np.frombuffer(reference_md5, dtype=np.uint8)

    cigar_bytes = [c.encode("utf-8") for c in cigar_strings]
    cigar_arr = (ctypes.c_char_p * (n if n > 0 else 1))(*cigar_bytes) if n > 0 else (ctypes.c_char_p * 1)()

    inp = _Input(
        sequences=seq.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8)),
        offsets=off.ctypes.data_as(ctypes.POINTER(ctypes.c_uint64)),
        positions=pos.ctypes.data_as(ctypes.POINTER(ctypes.c_int64)),
        cigar_strings=ctypes.cast(cigar_arr, ctypes.POINTER(ctypes.c_char_p)),
        n_reads=n,
        reference=ref_arr.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8)),
        reference_length=len(reference),
        reads_per_slice=reads_per_slice,
        reference_md5=md5_arr.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8)),
        reference_uri=reference_uri.encode("utf-8"),
    )

    cap = _lib.ttio_ref_diff_v2_max_encoded_size(n, int(off[n]) if n > 0 else 0)
    out = (ctypes.c_uint8 * cap)()
    out_len = ctypes.c_size_t(cap)
    rc = _lib.ttio_ref_diff_v2_encode(ctypes.byref(inp), out, ctypes.byref(out_len))
    if rc != 0:
        raise RuntimeError(_ERR_MESSAGES.get(rc, f"native error {rc}"))
    return bytes(out[:out_len.value])


def decode(
    encoded: bytes,
    positions: np.ndarray,
    cigar_strings: list[str],
    reference: bytes,
    n_reads: int,
    total_bases: int,
) -> tuple[np.ndarray, np.ndarray]:
    """Decode a refdiff_v2 blob to (sequences, offsets).

    Returns (out_sequences[total_bases] uint8, out_offsets[n_reads+1] uint64).
    """
    if not HAVE_NATIVE_LIB:
        raise RuntimeError("ref_diff_v2.decode requires libttio_rans")
    pos = np.ascontiguousarray(positions, dtype=np.int64)
    if pos.shape[0] != n_reads:
        raise ValueError(f"positions length must equal n_reads ({n_reads})")
    if len(cigar_strings) != n_reads:
        raise ValueError(f"cigar_strings length must equal n_reads ({n_reads})")
    enc_arr = np.frombuffer(encoded, dtype=np.uint8)
    ref_arr = np.frombuffer(reference, dtype=np.uint8)
    cigar_bytes = [c.encode("utf-8") for c in cigar_strings]
    cigar_arr = (ctypes.c_char_p * (n_reads if n_reads > 0 else 1))(*cigar_bytes) if n_reads > 0 else (ctypes.c_char_p * 1)()

    out_seq = np.zeros(total_bases if total_bases > 0 else 1, dtype=np.uint8)
    out_offsets = np.zeros(n_reads + 1, dtype=np.uint64)
    rc = _lib.ttio_ref_diff_v2_decode(
        enc_arr.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8)),
        ctypes.c_size_t(len(encoded)),
        pos.ctypes.data_as(ctypes.POINTER(ctypes.c_int64)),
        ctypes.cast(cigar_arr, ctypes.POINTER(ctypes.c_char_p)),
        ctypes.c_uint64(n_reads),
        ref_arr.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8)),
        ctypes.c_uint64(len(reference)),
        out_seq.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8)),
        out_offsets.ctypes.data_as(ctypes.POINTER(ctypes.c_uint64)),
    )
    if rc != 0:
        raise RuntimeError(_ERR_MESSAGES.get(rc, f"native error {rc}"))
    if total_bases == 0:
        return np.empty(0, dtype=np.uint8), out_offsets
    return out_seq[:total_bases], out_offsets


# Outer blob header offsets (spec §4.3 / ref_diff_v2.c):
#   [0:4]   magic b"RDF2"
#   [4]     version
#   [5:8]   reserved
#   [8:12]  n_slices (LE uint32)
#   [12:20] n_reads  (LE uint64)
#   [20:36] reference_md5 (16 raw bytes)
#   [36:38] uri_len (LE uint16)
#   [38:38+uri_len] reference_uri (UTF-8)
_RDV2_MAGIC = b"RDF2"
_RDV2_FIXED_HEADER = 38  # bytes before the URI payload


class _BlobHeader:
    """Parsed outer header from a refdiff_v2 blob."""
    __slots__ = ("reference_md5", "reference_uri")

    def __init__(self, reference_md5: bytes, reference_uri: str) -> None:
        self.reference_md5 = reference_md5
        self.reference_uri = reference_uri


def parse_blob_header(encoded: bytes) -> "_BlobHeader":
    """Parse the reference_uri and reference_md5 from a refdiff_v2 outer header.

    Raises ValueError on a corrupt or truncated blob.
    """
    if len(encoded) < _RDV2_FIXED_HEADER:
        raise ValueError(
            f"refdiff_v2 blob too short ({len(encoded)} < {_RDV2_FIXED_HEADER})"
        )
    if encoded[:4] != _RDV2_MAGIC:
        raise ValueError(
            f"refdiff_v2 magic mismatch: got {encoded[:4]!r}, expected {_RDV2_MAGIC!r}"
        )
    reference_md5 = bytes(encoded[20:36])
    uri_len = int.from_bytes(encoded[36:38], "little")
    if len(encoded) < _RDV2_FIXED_HEADER + uri_len:
        raise ValueError(
            f"refdiff_v2 blob truncated: uri_len={uri_len} but only "
            f"{len(encoded) - _RDV2_FIXED_HEADER} bytes remain after fixed header"
        )
    reference_uri = encoded[38:38 + uri_len].decode("utf-8", errors="replace")
    return _BlobHeader(reference_md5=reference_md5, reference_uri=reference_uri)
