"""Python ctypes wrapper for NAME_TOKENIZED v2 (codec id 15).

Spec: docs/superpowers/specs/2026-05-04-name-tokenized-v2-design.md
"""
from __future__ import annotations

import ctypes

from .fqzcomp_nx16_z import _native_lib, _HAVE_NATIVE_LIB

HAVE_NATIVE_LIB: bool = _HAVE_NATIVE_LIB

ERR_PARAM = -1
ERR_CORRUPT = -3
ERR_NTV2_BAD_FLAG = -8
ERR_NTV2_POOL_OOB = -9
ERR_NTV2_BAD_K = -10
ERR_NTV2_DICT_OVERFLOW = -11
ERR_NTV2_BAD_VERSION = -12
ERR_NTV2_BAD_MAGIC = -13

_ERR_MESSAGES = {
    ERR_PARAM: "invalid parameters",
    ERR_CORRUPT: "corrupt encoded blob",
    ERR_NTV2_BAD_FLAG: "name_tok_v2: invalid 2-bit FLAG",
    ERR_NTV2_POOL_OOB: "name_tok_v2: pool_idx out of range",
    ERR_NTV2_BAD_K: "name_tok_v2: K=0 or K>=n_cols",
    ERR_NTV2_DICT_OVERFLOW: "name_tok_v2: dict code > dict size",
    ERR_NTV2_BAD_VERSION: "name_tok_v2: bad container version",
    ERR_NTV2_BAD_MAGIC: "name_tok_v2: magic != NTK2",
}


_lib = None
if HAVE_NATIVE_LIB:
    _lib = _native_lib

    _lib.ttio_name_tok_v2_max_encoded_size.argtypes = [
        ctypes.c_uint64, ctypes.c_uint64,
    ]
    _lib.ttio_name_tok_v2_max_encoded_size.restype = ctypes.c_size_t

    _lib.ttio_name_tok_v2_encode.argtypes = [
        ctypes.POINTER(ctypes.c_char_p),
        ctypes.c_uint64,
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.POINTER(ctypes.c_size_t),
    ]
    _lib.ttio_name_tok_v2_encode.restype = ctypes.c_int

    # Use c_void_p inner pointer so [i] access returns raw addresses
    # (c_char_p auto-decodes to bytes, breaking the libc.free pairing).
    _lib.ttio_name_tok_v2_decode.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p)),
        ctypes.POINTER(ctypes.c_uint64),
    ]
    _lib.ttio_name_tok_v2_decode.restype = ctypes.c_int


_libc = None


def _get_libc():
    global _libc
    if _libc is None:
        _libc = ctypes.CDLL("libc.so.6")
        _libc.free.argtypes = [ctypes.c_void_p]
    return _libc


def encode(names: list[str]) -> bytes:
    """Encode names to NAME_TOKENIZED v2 wire format."""
    if not HAVE_NATIVE_LIB or _lib is None:
        raise RuntimeError(
            "name_tokenizer_v2.encode requires libttio_rans (set TTIO_RANS_LIB_PATH)"
        )
    n = len(names)
    encoded_names = [name.encode("ascii") for name in names]
    arr_size = max(n, 1)
    name_arr = (ctypes.c_char_p * arr_size)()
    for i, b in enumerate(encoded_names):
        name_arr[i] = b
    total_bytes = sum(len(b) for b in encoded_names)
    cap = _lib.ttio_name_tok_v2_max_encoded_size(n, total_bytes)
    out = (ctypes.c_uint8 * cap)()
    out_len = ctypes.c_size_t(cap)
    rc = _lib.ttio_name_tok_v2_encode(name_arr, n, out, ctypes.byref(out_len))
    if rc != 0:
        raise RuntimeError(_ERR_MESSAGES.get(rc, f"native error {rc}"))
    return bytes(out[:out_len.value])


def decode(blob: bytes) -> list[str]:
    """Decode a NAME_TOKENIZED v2 wire format blob."""
    if not HAVE_NATIVE_LIB or _lib is None:
        raise RuntimeError("name_tokenizer_v2.decode requires libttio_rans")
    if len(blob) < 12:
        raise RuntimeError(_ERR_MESSAGES[ERR_PARAM])
    enc_arr = (ctypes.c_uint8 * len(blob)).from_buffer_copy(blob)
    out_names_ptr = ctypes.POINTER(ctypes.c_void_p)()
    out_n = ctypes.c_uint64(0)
    rc = _lib.ttio_name_tok_v2_decode(
        enc_arr, len(blob),
        ctypes.byref(out_names_ptr),
        ctypes.byref(out_n),
    )
    if rc != 0:
        raise RuntimeError(_ERR_MESSAGES.get(rc, f"native error {rc}"))
    n = out_n.value
    libc = _get_libc()
    result: list[str] = []
    for i in range(n):
        p = out_names_ptr[i]
        s = ctypes.string_at(p) if p else b""
        result.append(s.decode("ascii"))
        libc.free(p)
    libc.free(ctypes.cast(out_names_ptr, ctypes.c_void_p))
    return result


def get_backend_name() -> str:
    return "native" if HAVE_NATIVE_LIB else "pure-python"
