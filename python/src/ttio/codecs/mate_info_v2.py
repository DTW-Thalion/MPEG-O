"""Python ctypes wrapper for mate_info v2 (CRAM-style inline mate-pair codec).

Spec: docs/superpowers/specs/2026-05-03-mate-info-v2-design.md

Encoded blob written as signal_channels/mate_info/inline_v2 uint8
dataset with @compression = 13 (MATE_INLINE_V2). Requires
TTIO_RANS_LIB_PATH to point at a built libttio_rans.so;
without it, HAVE_NATIVE_LIB is False and the writer falls back to
the v1 M82 compound layout.
"""
from __future__ import annotations

import ctypes

import numpy as np

# Reuse the loader from fqzcomp_nx16_z.py -- same library, same env var.
from .fqzcomp_nx16_z import _native_lib, _HAVE_NATIVE_LIB

HAVE_NATIVE_LIB: bool = _HAVE_NATIVE_LIB

# Error codes mirror native/include/ttio_rans.h
ERR_PARAM = -1
ERR_ALLOC = -2
ERR_CORRUPT = -3
ERR_RESERVED_MF = -4
ERR_NS_LENGTH_MISMATCH = -5

_ERR_MESSAGES = {
    ERR_PARAM: "invalid parameters",
    ERR_ALLOC: "out of memory in native code",
    ERR_CORRUPT: "corrupt encoded blob",
    ERR_RESERVED_MF: "reserved MF value 3 in stream",
    ERR_NS_LENGTH_MISMATCH: "NS substream length does not match NUM_CROSS",
}


if HAVE_NATIVE_LIB:
    _lib = _native_lib

    _lib.ttio_mate_info_v2_max_encoded_size.argtypes = [ctypes.c_uint64]
    _lib.ttio_mate_info_v2_max_encoded_size.restype = ctypes.c_size_t

    _lib.ttio_mate_info_v2_encode.argtypes = [
        ctypes.POINTER(ctypes.c_int32),
        ctypes.POINTER(ctypes.c_int64),
        ctypes.POINTER(ctypes.c_int32),
        ctypes.POINTER(ctypes.c_uint16),
        ctypes.POINTER(ctypes.c_int64),
        ctypes.c_uint64,
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.POINTER(ctypes.c_size_t),
    ]
    _lib.ttio_mate_info_v2_encode.restype = ctypes.c_int

    _lib.ttio_mate_info_v2_decode.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_uint16),
        ctypes.POINTER(ctypes.c_int64),
        ctypes.c_uint64,
        ctypes.POINTER(ctypes.c_int32),
        ctypes.POINTER(ctypes.c_int64),
        ctypes.POINTER(ctypes.c_int32),
    ]
    _lib.ttio_mate_info_v2_decode.restype = ctypes.c_int


def _check_input_validity(mate_chrom_ids: np.ndarray) -> None:
    """Mirror the native miv2_classify_mf input validation."""
    if mate_chrom_ids.size > 0 and np.any(mate_chrom_ids < -1):
        bad_idx = int(np.argmax(mate_chrom_ids < -1))
        raise ValueError(
            f"invalid mate_chrom_id at index {bad_idx}: "
            f"{int(mate_chrom_ids[bad_idx])} (must be >= -1)")


def encode(
    mate_chrom_ids: np.ndarray,
    mate_positions: np.ndarray,
    template_lengths: np.ndarray,
    own_chrom_ids: np.ndarray,
    own_positions: np.ndarray,
) -> bytes:
    """Encode a mate triple to the inline_v2 blob.

    All arrays must be 1-D and have the same length. Dtypes are
    enforced via np.ascontiguousarray (will copy if input dtype differs).
    """
    if not HAVE_NATIVE_LIB:
        raise RuntimeError(
            "mate_info_v2.encode requires libttio_rans (set "
            "TTIO_RANS_LIB_PATH); the writer falls back to the v1 "
            "M82 compound layout automatically.")

    mc = np.ascontiguousarray(mate_chrom_ids, dtype=np.int32)
    mp = np.ascontiguousarray(mate_positions, dtype=np.int64)
    ts = np.ascontiguousarray(template_lengths, dtype=np.int32)
    oc = np.ascontiguousarray(own_chrom_ids, dtype=np.uint16)
    op = np.ascontiguousarray(own_positions, dtype=np.int64)

    n = mc.shape[0]
    if not (mp.shape[0] == n and ts.shape[0] == n
            and oc.shape[0] == n and op.shape[0] == n):
        raise ValueError("all input arrays must have the same length")

    _check_input_validity(mc)

    cap = _lib.ttio_mate_info_v2_max_encoded_size(n)
    out = (ctypes.c_uint8 * cap)()
    out_len = ctypes.c_size_t(cap)

    rc = _lib.ttio_mate_info_v2_encode(
        mc.ctypes.data_as(ctypes.POINTER(ctypes.c_int32)),
        mp.ctypes.data_as(ctypes.POINTER(ctypes.c_int64)),
        ts.ctypes.data_as(ctypes.POINTER(ctypes.c_int32)),
        oc.ctypes.data_as(ctypes.POINTER(ctypes.c_uint16)),
        op.ctypes.data_as(ctypes.POINTER(ctypes.c_int64)),
        ctypes.c_uint64(n),
        out, ctypes.byref(out_len))
    if rc != 0:
        raise RuntimeError(_ERR_MESSAGES.get(rc, f"native error {rc}"))
    return bytes(out[:out_len.value])


def decode(
    encoded: bytes,
    own_chrom_ids: np.ndarray,
    own_positions: np.ndarray,
    n_records: int,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Decode an inline_v2 blob to (mate_chrom_ids, mate_positions, template_lengths)."""
    if not HAVE_NATIVE_LIB:
        raise RuntimeError(
            "mate_info_v2.decode requires libttio_rans (set TTIO_RANS_LIB_PATH)")

    oc = np.ascontiguousarray(own_chrom_ids, dtype=np.uint16)
    op = np.ascontiguousarray(own_positions, dtype=np.int64)
    if oc.shape[0] != n_records or op.shape[0] != n_records:
        raise ValueError(
            f"own_chrom_ids/own_positions length must equal n_records ({n_records})")

    enc_arr = np.frombuffer(encoded, dtype=np.uint8)
    out_mc = np.empty(n_records, dtype=np.int32)
    out_mp = np.empty(n_records, dtype=np.int64)
    out_ts = np.empty(n_records, dtype=np.int32)

    rc = _lib.ttio_mate_info_v2_decode(
        enc_arr.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8)),
        ctypes.c_size_t(len(encoded)),
        oc.ctypes.data_as(ctypes.POINTER(ctypes.c_uint16)),
        op.ctypes.data_as(ctypes.POINTER(ctypes.c_int64)),
        ctypes.c_uint64(n_records),
        out_mc.ctypes.data_as(ctypes.POINTER(ctypes.c_int32)),
        out_mp.ctypes.data_as(ctypes.POINTER(ctypes.c_int64)),
        out_ts.ctypes.data_as(ctypes.POINTER(ctypes.c_int32)))
    if rc != 0:
        raise RuntimeError(_ERR_MESSAGES.get(rc, f"native error {rc}"))
    return out_mc, out_mp, out_ts
