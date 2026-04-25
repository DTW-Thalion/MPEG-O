"""JCAMP-DX 5.01 compressed-XYDATA encoder (PAC / SQZ / DIF).

Mirror-image of :mod:`ttio.importers._jcamp_decode`. Takes a
float64 ``ys`` array plus ``firstx`` / ``deltax``, picks a YFACTOR
that gives ~7 significant digits of integer-scaled precision, and
emits the body of an ``##XYDATA=(X++(Y..Y))`` block in one of three
compressed forms.

The same algorithm ships unchanged in the Java
(``com.dtwthalion.ttio.exporters.JcampDxWriter``) and Objective-C
(``TTIOJcampDxWriter``) writers — byte-for-byte identical output is
a hard gate enforced by the conformance fixtures under
``conformance/jcamp_dx/``.

Line format
-----------
All three compressed forms emit a fixed ``VALUES_PER_LINE=10`` Y
values per data line. Each line begins with an X-anchor formatted as
``%.10g`` so a non-TTIO JCAMP-DX reader can audit it; the matching
reader here discards it in favour of ``firstx + i * deltax`` per the
``(X++(Y..Y))`` spec.

Rounding convention
-------------------
``y_int = (int64_t)(y / yfactor + (y >= 0 ? 0.5 : -0.5))``. Explicit
half-away-from-zero (NOT banker's rounding) — Python's ``round`` is
half-to-even, which diverges from Java ``Math.round`` and C ``lround``
on ``.5`` ties; the explicit add-then-truncate form is identical in
all three languages for every finite double.

Cross-language equivalents
--------------------------
Objective-C: ``TTIOJcampDxWriter+Compress.m`` · Java:
``com.dtwthalion.ttio.exporters.JcampDxWriter#encodeXYData``.
"""
from __future__ import annotations

import math

import numpy as np


VALUES_PER_LINE = 10


_SQZ_POS = "@ABCDEFGHI"  # 0..9 positive
_SQZ_NEG = "@abcdefghi"  # 0..9 negative (index 0 reuses '@' = +0)
_DIF_POS = "%JKLMNOPQR"  # 0..9 positive
_DIF_NEG = "%jklmnopqr"  # 0..9 negative (index 0 reuses '%' = +0)


def choose_yfactor(ys: np.ndarray, sig_digits: int = 7) -> float:
    """Pick a YFACTOR that scales ``ys`` to ~``sig_digits``-digit integers.

    Returns ``10 ** (ceil(log10(max_abs)) - sig_digits)`` — the smallest
    power of ten such that every ``round(y / yfactor)`` fits in
    ``sig_digits`` decimal digits without loss beyond 1 ULP of the
    chosen precision. Returns ``1.0`` for an all-zero / empty input.
    """
    if ys.size == 0:
        return 1.0
    max_abs = float(np.max(np.abs(ys)))
    if max_abs == 0.0:
        return 1.0
    exp = math.ceil(math.log10(max_abs))
    return 10.0 ** (exp - sig_digits)


def _round_int(value: float) -> int:
    """Half-away-from-zero rounding (portable across Python/Java/ObjC)."""
    return int(value + (0.5 if value >= 0.0 else -0.5))


def _encode_sqz(value: int) -> str:
    """Encode an integer as a single SQZ-led token.

    Leading decimal digit is replaced by a SQZ character from
    ``@ABCDEFGHI`` (non-negative) or ``@abcdefghi`` (negative); the
    remaining digits are emitted verbatim.
    """
    if value == 0:
        return "@"
    negative = value < 0
    digits = str(abs(value))
    lead = int(digits[0])
    tail = digits[1:]
    table = _SQZ_NEG if negative else _SQZ_POS
    return table[lead] + tail


def _encode_dif(delta: int) -> str:
    """Encode a Y-difference as a single DIF-led token."""
    if delta == 0:
        return "%"
    negative = delta < 0
    digits = str(abs(delta))
    lead = int(digits[0])
    tail = digits[1:]
    table = _DIF_NEG if negative else _DIF_POS
    return table[lead] + tail


def _encode_pac_y(value: int) -> str:
    """Encode a Y value as a PAC token — explicit sign + digits.

    ``+``/``-`` acts as both sign AND token delimiter per JCAMP-DX
    5.01 §5.9; the reader's tokenizer splits there, so space between
    consecutive PAC Y values is redundant.
    """
    return f"{value:+d}"


def _format_anchor(x: float) -> str:
    return f"{x:.10g}"


def encode_xydata(
    ys: np.ndarray,
    *,
    firstx: float,
    deltax: float,
    yfactor: float,
    mode: str,
) -> str:
    """Return the body of an ``##XYDATA=(X++(Y..Y))`` block.

    ``ys`` must already carry the caller-supplied float Y values (raw,
    unscaled). This function performs the ``yfactor`` division and
    integer rounding. ``mode`` ∈ ``{"pac", "sqz", "dif"}``. The AFFN
    fast path lives in :mod:`ttio.exporters.jcamp_dx` and is not
    routed through here.

    Output is newline-separated, with a trailing newline so callers can
    concatenate with ``"##END=\\n"`` without extra bookkeeping.
    """
    if mode not in {"pac", "sqz", "dif"}:
        raise ValueError(f"unknown JCAMP-DX encoding mode: {mode!r}")
    n = int(ys.shape[0])
    if n == 0:
        return ""

    y_int = np.empty(n, dtype=np.int64)
    for i in range(n):
        y_int[i] = _round_int(float(ys[i]) / yfactor)

    lines: list[str] = []
    i = 0
    prev_last: int | None = None
    while i < n:
        j = min(i + VALUES_PER_LINE, n)
        anchor = _format_anchor(firstx + i * deltax)

        if mode == "pac":
            # On lines N>0, emit the previous line's last Y as an
            # explicit Y-check — the decoder drops line-start values
            # matching prev_last_y unconditionally, so a coincidence
            # match (e.g. plateau of zeros) would silently steal data
            # without this prepended sentinel.
            y_tokens: list[str] = []
            if prev_last is not None:
                y_tokens.append(_encode_pac_y(prev_last))
            for k in range(i, j):
                y_tokens.append(_encode_pac_y(int(y_int[k])))
            lines.append(anchor + " " + "".join(y_tokens))
            prev_last = int(y_int[j - 1])
            i = j
            continue

        if mode == "sqz":
            toks = [anchor]
            if prev_last is not None:
                toks.append(_encode_sqz(prev_last))  # Y-check
            for k in range(i, j):
                toks.append(_encode_sqz(int(y_int[k])))
            lines.append(" ".join(toks))
            prev_last = int(y_int[j - 1])
            i = j
            continue

        # mode == "dif"
        # Every line starts with an absolute SQZ value — for line 0
        # it is y[0]; for subsequent lines it is prev_last (the
        # Y-check). DIF tokens in the body encode deltas from the
        # running value.
        toks = [anchor]
        if prev_last is None:
            toks.append(_encode_sqz(int(y_int[i])))
            running = int(y_int[i])
            start = i + 1
        else:
            toks.append(_encode_sqz(prev_last))
            running = prev_last
            start = i
        for k in range(start, j):
            delta = int(y_int[k]) - running
            toks.append(_encode_dif(delta))
            running = int(y_int[k])
        lines.append(" ".join(toks))
        prev_last = int(y_int[j - 1])
        i = j

    return "\n".join(lines) + "\n"


__all__ = ["encode_xydata", "choose_yfactor", "VALUES_PER_LINE"]
