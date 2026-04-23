"""JCAMP-DX 5.01 compressed-XYDATA decoder (SQZ / DIF / DUP / PAC).

Implements the PAC, SQZ, DIF, and DUP compression dialects from
JCAMP-DX 5.01 §5.9. The uncompressed AFFN dialect is handled by the
fast path in :mod:`mpeg_o.importers.jcamp_dx`; this module is invoked
only when the reader detects one of the single-character compression
sentinels below.

Y-axis values are returned in order; X-axis values are synthesised
from ``firstx + i * deltax`` per the JCAMP-DX convention that
``##XYDATA=(X++(Y..Y))`` implies equispaced X.
"""
from __future__ import annotations

import re
from typing import Iterable


_SQZ: dict[str, tuple[int, int]] = {"@": (0, +1)}
for _i, _c in enumerate("ABCDEFGHI", start=1):
    _SQZ[_c] = (_i, +1)
for _i, _c in enumerate("abcdefghi", start=1):
    _SQZ[_c] = (_i, -1)

_DIF: dict[str, tuple[int, int]] = {"%": (0, +1)}
for _i, _c in enumerate("JKLMNOPQR", start=1):
    _DIF[_c] = (_i, +1)
for _i, _c in enumerate("jklmnopqr", start=1):
    _DIF[_c] = (_i, -1)

_DUP: dict[str, int] = {c: n for n, c in enumerate("STUVWXYZ", start=2)}
_DUP["s"] = 9

_COMPRESSION_CHARS = frozenset(_SQZ) | frozenset(_DIF) | frozenset(_DUP)

# AFFN scientific notation ("1.5E-03", "7e+4") embeds 'E'/'e' inside
# numeric tokens; those are in SQZ's alphabet but never signal
# compression on their own, so we exclude them from the detector.
# A genuinely compressed body always carries additional SQZ/DIF/DUP
# chars from the wider alphabet.
_DETECT_CHARS = _COMPRESSION_CHARS - frozenset("Ee")

# PAC bodies carry no SQZ/DIF/DUP chars — the distinguishing feature
# is `\\d[+\\-]\\d` (digit-sign-digit without whitespace) since AFFN
# separates tokens with whitespace and never produces that adjacency.
# Scientific notation like "1.5e+03" is safe: the char before the
# sign is always `e`/`E`, not a digit.
_PAC_RE = re.compile(r"\d[+\-]\d")


def has_compression(body: str) -> bool:
    """Return True if the XYDATA body uses any PAC/SQZ/DIF/DUP char."""
    if any(ch in _DETECT_CHARS for ch in body):
        return True
    return _PAC_RE.search(body) is not None


def _tokenize(line: str) -> list[str]:
    """Split a JCAMP-DX data line into compressed tokens.

    A fresh token starts at whitespace, at any SQZ/DIF/DUP character,
    or at an AFFN sign. Internal digits, decimal points, and E/e
    exponents extend the current token.
    """
    tokens: list[str] = []
    current: list[str] = []

    def flush() -> None:
        if current:
            tokens.append("".join(current))
            current.clear()

    for ch in line:
        if ch.isspace():
            flush()
            continue
        if ch == "$":
            break  # $$ starts an inline comment
        if ch in _COMPRESSION_CHARS or ch in "+-":
            flush()
            current.append(ch)
            continue
        if ch.isdigit() or ch in ".eE":
            current.append(ch)
            continue
        flush()

    flush()
    return tokens


def _parse_sqz_or_affn(tok: str) -> float:
    head = tok[0]
    if head in _SQZ:
        digit, sign = _SQZ[head]
        rest = tok[1:]
        magnitude = float(f"{digit}{rest}") if rest else float(digit)
        return sign * magnitude
    return float(tok)


def _parse_dif(tok: str) -> float:
    digit, sign = _DIF[tok[0]]
    rest = tok[1:]
    magnitude = float(f"{digit}{rest}") if rest else float(digit)
    return sign * magnitude


def _parse_dup_count(tok: str) -> int:
    base = _DUP[tok[0]]
    rest = tok[1:]
    return int(f"{base}{rest}") if rest else base


def decode_xydata(
    lines: Iterable[str],
    *,
    firstx: float,
    deltax: float,
    xfactor: float = 1.0,
    yfactor: float = 1.0,
) -> tuple[list[float], list[float]]:
    """Decode a compressed ``##XYDATA=(X++(Y..Y))`` body.

    ``lines`` is an iterable of raw text lines belonging to the XYDATA
    block (the ``##XYDATA=`` header and the terminal ``##END=`` are
    NOT included).

    Each line is expected to start with an X-anchor token followed by
    one or more Y tokens. Supported Y-token forms:

    - AFFN / PAC absolute (``+``/``-``/digit-led)
    - SQZ absolute (``@``/``A-I``/``a-i`` led)
    - DIF delta (``%``/``J-R``/``j-r`` led) — additive to prior Y
    - DUP repeat (``S-Z``/``s`` led) — repeats the prior Y (count-1)

    When a line starts with an SQZ/AFFN Y value that equals the
    previous line's last Y (within 1e-9), it is treated as a DIF
    Y-check value and dropped. This matches the canonical encoder
    convention of repeating the last Y on the next line for chain
    verification.

    Returns ``(xs, ys)`` with ``xs[i] = firstx + i * deltax`` scaled by
    ``xfactor``, and each Y scaled by ``yfactor``.
    """
    ys_raw: list[float] = []
    prev_last_y: float | None = None

    for raw in lines:
        line = raw.split("$$", 1)[0].strip()
        if not line:
            continue
        toks = _tokenize(line)
        if not toks or len(toks) < 2:
            continue

        # toks[0] is the X-anchor; we ignore it in favour of firstx+deltax.
        current_y: float | None = None
        line_ys: list[float] = []

        for tok in toks[1:]:
            head = tok[0]
            if head in _DIF:
                base = current_y if current_y is not None else prev_last_y
                if base is None:
                    raise ValueError(
                        "JCAMP-DX: DIF token at start of data stream"
                    )
                current_y = base + _parse_dif(tok)
                line_ys.append(current_y)
            elif head in _DUP:
                if current_y is None:
                    raise ValueError(
                        "JCAMP-DX: DUP token before any absolute Y"
                    )
                count = _parse_dup_count(tok) - 1  # current_y already emitted
                line_ys.extend([current_y] * count)
            else:
                current_y = _parse_sqz_or_affn(tok)
                line_ys.append(current_y)

        # DIF Y-check: drop a redundant leading value that matches the
        # previous line's last Y (canonical DIF-chain verifier).
        if prev_last_y is not None and line_ys and abs(line_ys[0] - prev_last_y) < 1e-9:
            line_ys.pop(0)

        if line_ys:
            ys_raw.extend(line_ys)
            prev_last_y = line_ys[-1]

    xs = [(firstx + i * deltax) * xfactor for i in range(len(ys_raw))]
    ys = [y * yfactor for y in ys_raw]
    return xs, ys


__all__ = ["decode_xydata", "has_compression"]
