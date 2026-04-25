"""Numpress-delta codec — Python port of :class:`TTIONumpress`.

Clean-room implementation from Teleman et al. 2014 (*MCP* 13(6),
doi:10.1074/mcp.O114.037879). The encoder multiplies the input
float64 array by a fixed-point scaling factor and stores the
first differences of the quantised integers. The decoder reverses
both passes.

For typical mass-spectrometry m/z data in the 100–2000 range the
resulting round-trip relative error is far below one part per
million. The on-disk representation is a plain ``int64`` array
plus a per-channel ``@<channel>_numpress_fixed_point`` attribute
holding the scaling factor, making the codec cross-language
interoperable with the Objective-C reference implementation by
construction: both sides use the same scale computation, the same
rounding rule, and the same delta pass.

Cross-language equivalents
--------------------------
Objective-C: ``TTIONumpress`` · Java:
``com.dtwthalion.ttio.NumpressCodec``.

API status: Stable.

SPDX-License-Identifier: LGPL-3.0-or-later
"""
from __future__ import annotations

import numpy as np


_HEADROOM = (1 << 62) - 1  # Must agree with TTIONumpress.m exactly.


def scale_for_range(min_value: float, max_value: float) -> int:
    """Pick a fixed-point scaling factor so that the largest absolute
    quantised value fits in 62 bits. Matches ``+[TTIONumpress
    scaleForValueRangeMin:max:]``."""
    abs_max = max(abs(min_value), abs(max_value))
    if abs_max == 0.0 or not np.isfinite(abs_max):
        return 1
    scale = int(_HEADROOM // abs_max)
    return max(scale, 1)


def encode(values: np.ndarray, *, scale: int | None = None) -> tuple[np.ndarray, int]:
    """Encode a float64 array. Returns ``(deltas, scale)``.

    If ``scale`` is ``None`` one is chosen from the value range via
    :func:`scale_for_range`. ``deltas`` is an ``int64`` array of the
    same length as ``values``, with ``deltas[0]`` holding the absolute
    quantised value of ``values[0]`` and subsequent entries holding
    first differences of the quantised signal.
    """
    if values.ndim != 1:
        raise ValueError(f"numpress.encode expects a 1-D array, got shape={values.shape}")
    if values.size == 0:
        return np.zeros(0, dtype=np.int64), scale or 1
    v = np.ascontiguousarray(values, dtype=np.float64)
    if scale is None:
        scale = scale_for_range(float(v.min()), float(v.max()))
    if scale <= 0:
        raise ValueError(f"scale must be positive, got {scale}")

    # Match the ObjC llround() semantics: ties-to-even is what llround
    # uses on Linux (IEEE 754 default). numpy's rint() is ties-to-even
    # too, so the two implementations produce identical quantised ints
    # for any input that matches byte-for-byte.
    quantised = np.rint(v * float(scale)).astype(np.int64)
    deltas = np.empty_like(quantised)
    deltas[0] = quantised[0]
    if quantised.size > 1:
        deltas[1:] = np.diff(quantised)
    return deltas, scale


def decode(deltas: np.ndarray, scale: int) -> np.ndarray:
    """Decode an int64 delta array back to float64."""
    if deltas.ndim != 1:
        raise ValueError(f"numpress.decode expects a 1-D array, got shape={deltas.shape}")
    if deltas.size == 0:
        return np.zeros(0, dtype=np.float64)
    if scale <= 0:
        raise ValueError(f"scale must be positive, got {scale}")
    quantised = np.cumsum(deltas.astype(np.int64))
    return (quantised.astype(np.float64)) / float(scale)
