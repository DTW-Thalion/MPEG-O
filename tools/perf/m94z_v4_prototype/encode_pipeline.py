"""Shared encode pipeline for prototype candidates.

Takes a sparse context sequence (from a candidate's
``derive_contexts_<id>``) plus the raw qualities and produces a
compressed body via the existing V3 C kernel
``ttio_rans_encode_block_adaptive``. Reuses
``_vectorize_first_encounter`` from the production codec.
"""

from __future__ import annotations

import ctypes
from dataclasses import dataclass

import numpy as np

from ttio.codecs.fqzcomp_nx16_z import (
    _HAVE_NATIVE_LIB,
    _lib,
    _vectorize_first_encounter,
    m94z_context,
)


@dataclass
class EncodeResult:
    body_bytes: bytes        # raw RC body produced by the C kernel
    n_active: int            # distinct contexts actually used
    sparse_ids: list[int]    # encounter-ordered list of sparse ctx values
    max_sym: int             # max symbol byte + 1, clamped to [1, 256]
    n_padded: int            # padded symbol count (multiple of 4)


def encode_with_kernel(
    qualities: bytes,
    sparse_seq: np.ndarray,
    n_padded: int,
    sloc: int,
) -> EncodeResult:
    """Run the V3 C kernel on a candidate's sparse context sequence.

    Mirrors the pipeline in ``_encode_v3_native`` but factored out for
    prototype reuse. ``sparse_seq`` must be uint32 with values in
    ``[0, 2 ** sloc)``; this function does first-encounter dense
    remap, marshals symbols + dense contexts to ctypes buffers, and
    invokes ``ttio_rans_encode_block_adaptive``.
    """
    if not _HAVE_NATIVE_LIB:
        raise RuntimeError(
            "encode_with_kernel: libttio_rans is not loaded. Set "
            "TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so."
        )
    if sparse_seq.shape[0] != n_padded:
        raise ValueError(
            f"sparse_seq length {sparse_seq.shape[0]} != n_padded {n_padded}"
        )

    n = len(qualities)
    sym_arr = np.zeros(n_padded, dtype=np.uint8)
    if n > 0:
        sym_arr[:n] = np.frombuffer(qualities, dtype=np.uint8)

    dense_seq, sparse_ids, n_active = _vectorize_first_encounter(
        sparse_seq, sloc,
    )
    if n_active == 0:
        n_active = 1
        sparse_ids = [m94z_context(0, 0, 0, 12, 2, sloc)]

    if n_padded == 0:
        max_sym = 1
    else:
        max_sym = int(sym_arr.max()) + 1
        if max_sym < 1:
            max_sym = 1
        if max_sym > 256:
            max_sym = 256

    sym_buf = (ctypes.c_uint8 * n_padded).from_buffer(sym_arr)
    ctx_buf = (ctypes.c_uint16 * n_padded).from_buffer(dense_seq)
    out_cap = 16 + n_padded * 2 + 64
    out_buf = (ctypes.c_uint8 * out_cap)()
    out_len = ctypes.c_size_t(out_cap)

    rc = _lib.ttio_rans_encode_block_adaptive(
        sym_buf, ctx_buf,
        ctypes.c_size_t(n_padded),
        ctypes.c_uint16(n_active),
        ctypes.c_uint16(max_sym),
        out_buf,
        ctypes.byref(out_len),
    )
    if rc != 0:
        raise RuntimeError(
            f"ttio_rans_encode_block_adaptive failed: rc={rc}"
        )
    body = bytes(out_buf[:out_len.value])
    return EncodeResult(
        body_bytes=body,
        n_active=n_active,
        sparse_ids=sparse_ids,
        max_sym=max_sym,
        n_padded=n_padded,
    )


def pad_count_for(n: int) -> int:
    """Return the number of zero pad bytes to append so n + pad is a multiple of 4."""
    return (-n) & 0x3
