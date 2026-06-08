# cython: language_level=3, boundscheck=False, wraparound=False, cdivision=True, initializedcheck=False
"""TTI-O DELTA_RANS Cython accelerator — varint (LEB128) hot loops.

Byte-exact port of the serial varint emit/parse loops in the pure-Python
reference :mod:`ttio.codecs.delta_rans`. Public API:

* :func:`varint_encode_all(zz)` -> ``bytes``
* :func:`varint_decode_all(buf)` -> ``numpy.ndarray`` (dtype ``uint64``)

The wrapper in :mod:`ttio.codecs.delta_rans` handles the ``DRA0`` header,
the zigzag transform, the int64 prefix-sum, and the native-rANS body; it
dispatches to these functions when this extension is loadable. The bytes
produced/consumed here are identical to the Python loops:

* encode emits unsigned LEB128: 7 data bits per byte, little-endian groups,
  continuation bit 0x80 set on all but the last group, and ALWAYS at least
  one byte (a zero value emits a single 0x00) — matching ``_varint_encode``.
* decode accumulates 7-bit groups little-endian and raises
  ``ValueError("DELTA_RANS: truncated varint")`` if the stream ends mid-varint,
  matching ``_varint_decode_all``.

The zigzag deltas fed in here are masked to 64 bits by the wrapper, so each
value fits in a ``uint64_t`` and a LEB128 varint is at most 10 bytes.

This module deliberately uses only the C buffer protocol (no ``cimport
numpy``) so it builds with the same minimal setuptools wiring as the other
TTI-O Cython accelerators — no numpy headers required at compile time.
"""

from cpython.buffer cimport (
    Py_buffer,
    PyBUF_SIMPLE,
    PyObject_GetBuffer,
    PyBuffer_Release,
)
from libc.stdint cimport uint8_t, uint64_t
from libc.stdlib cimport malloc, free
from libc.string cimport memcpy

import numpy as np


# ── varint encode ──────────────────────────────────────────────────────

def varint_encode_all(zz):
    """Emit the unsigned LEB128 byte stream for the zigzag deltas ``zz``.

    ``zz`` is a 1-D contiguous array of 64-bit unsigned integers (the masked
    zigzag deltas). Returns the concatenated LEB128 encoding as ``bytes``,
    byte-for-byte identical to ``b"".join(_varint_encode(z) for z in zz)``.
    """
    arr = np.ascontiguousarray(zz, dtype=np.uint64)

    cdef Py_buffer view
    if PyObject_GetBuffer(arr, &view, PyBUF_SIMPLE) != 0:
        raise BufferError("DELTA_RANS: could not acquire zigzag buffer")

    cdef Py_ssize_t n = view.len // sizeof(uint64_t)
    cdef const uint64_t* vals = <const uint64_t*>view.buf

    if n == 0:
        PyBuffer_Release(&view)
        return b""

    # Worst case: a 64-bit value needs ceil(64/7) = 10 LEB128 bytes.
    cdef uint8_t* out = <uint8_t*>malloc(n * 10)
    if out == NULL:
        PyBuffer_Release(&view)
        raise MemoryError()

    cdef Py_ssize_t out_len = 0
    cdef Py_ssize_t i
    cdef uint64_t value
    try:
        for i in range(n):
            value = vals[i]
            while value > 0x7F:
                out[out_len] = <uint8_t>((value & 0x7F) | 0x80)
                out_len += 1
                value >>= 7
            out[out_len] = <uint8_t>(value & 0x7F)
            out_len += 1
        result = (<char*>out)[:out_len]
    finally:
        free(out)
        PyBuffer_Release(&view)
    return result


# ── varint decode ──────────────────────────────────────────────────────

def varint_decode_all(buf):
    """Parse the unsigned LEB128 stream ``buf`` into a ``uint64`` array.

    Returns a 1-D ``numpy.ndarray`` (dtype ``uint64``) of the decoded values,
    identical to the integers produced by ``_varint_decode_all``. Raises
    ``ValueError("DELTA_RANS: truncated varint")`` if the stream ends in the
    middle of a varint (matching the pure-Python reference).
    """
    cdef Py_buffer view
    if PyObject_GetBuffer(buf, &view, PyBUF_SIMPLE) != 0:
        raise BufferError("DELTA_RANS: could not acquire varint buffer")

    cdef const uint8_t* data = <const uint8_t*>view.buf
    cdef Py_ssize_t n = view.len

    if n == 0:
        PyBuffer_Release(&view)
        return np.empty(0, dtype=np.uint64)

    # Upper bound on the count: at most one value per byte.
    cdef uint64_t* out = <uint64_t*>malloc(n * sizeof(uint64_t))
    if out == NULL:
        PyBuffer_Release(&view)
        raise MemoryError()

    cdef Py_ssize_t i = 0
    cdef Py_ssize_t count = 0
    cdef uint64_t value
    cdef unsigned int shift
    cdef uint8_t byte
    try:
        while i < n:
            value = 0
            shift = 0
            while True:
                if i >= n:
                    raise ValueError("DELTA_RANS: truncated varint")
                byte = data[i]
                i += 1
                value |= (<uint64_t>(byte & 0x7F)) << shift
                if (byte & 0x80) == 0:
                    break
                shift += 7
            out[count] = value
            count += 1

        result = np.empty(count, dtype=np.uint64)
        if count > 0:
            memcpy(
                <void*><Py_ssize_t>result.ctypes.data,
                <const void*>out,
                count * sizeof(uint64_t),
            )
    finally:
        free(out)
        PyBuffer_Release(&view)
    return result
