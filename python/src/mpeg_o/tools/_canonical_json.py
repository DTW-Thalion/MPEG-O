"""Deterministic JSON formatter for the M51 compound parity harness.

Byte-identical output across Python, Java, and Objective-C dumpers.

Format rules
------------
- Top-level object, sorted keys.
- Each array element on its own line (LF newlines).
- Within a record: keys sorted alphabetically, tight JSON
  (``"key":<value>`` with no spaces, comma separator with no space).
- Floats formatted with C99 ``%.17g`` semantics (strip trailing zeros
  after the decimal, drop the decimal when no fraction remains).
- Integers formatted as base-10 decimal.
- Strings JSON-escaped with ``ensure_ascii=False`` — raw UTF-8 preserved.
- Trailing newline at end of file.

This module is the Python reference implementation. ``java`` and
``objc`` ports live under the respective language trees and must emit
byte-identical output on the same fixtures.
"""
from __future__ import annotations

from typing import Any


_ESCAPE = {
    ord('"'): '\\"',
    ord('\\'): '\\\\',
    ord('\b'): '\\b',
    ord('\f'): '\\f',
    ord('\n'): '\\n',
    ord('\r'): '\\r',
    ord('\t'): '\\t',
}


def escape_string(s: str) -> str:
    """JSON-escape ``s`` with ``ensure_ascii=False`` semantics — raw UTF-8
    is preserved; only C0 control characters and the two reserved JSON
    chars (``"`` and ``\\``) get backslash-escaped."""
    out = ['"']
    for ch in s:
        code = ord(ch)
        if code in _ESCAPE:
            out.append(_ESCAPE[code])
        elif code < 0x20:
            out.append(f"\\u{code:04x}")
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def format_float(x: float) -> str:
    """C99-style ``%.17g`` formatting.

    Python's ``f"{x:.17g}"`` already implements this (delegates to C
    ``snprintf``). Exposed as a helper so the Java and ObjC ports can
    reference the exact rule they need to mirror."""
    return format(x, ".17g")


def format_int(x: int) -> str:
    """Base-10 decimal."""
    return str(x)


def format_value(v: Any) -> str:
    """Render a single JSON value — scalar or homogeneous list / dict."""
    if isinstance(v, bool):
        # ``bool`` is a subclass of ``int`` — check first.
        return "true" if v else "false"
    if isinstance(v, int):
        return format_int(v)
    if isinstance(v, float):
        return format_float(v)
    if isinstance(v, str):
        return escape_string(v)
    if v is None:
        return "null"
    if isinstance(v, (list, tuple)):
        return "[" + ",".join(format_value(e) for e in v) + "]"
    if isinstance(v, dict):
        parts = []
        for k in sorted(v.keys()):
            parts.append(escape_string(k) + ":" + format_value(v[k]))
        return "{" + ",".join(parts) + "}"
    raise TypeError(f"unsupported canonical JSON value: {type(v).__name__}")


def format_record(record: dict[str, Any]) -> str:
    """Render a dict as a single-line JSON object with sorted keys."""
    return format_value(record)


def format_top_level(
    sections: dict[str, list[dict[str, Any]]],
) -> str:
    """Render the M51 dump: outer object keyed by section name, each
    value an array of records. One record per line."""
    out = ["{"]
    first = True
    for key in sorted(sections.keys()):
        if not first:
            out.append(",")
        first = False
        out.append("\n")
        out.append(escape_string(key))
        out.append(": [")
        records = sections[key]
        for i, r in enumerate(records):
            out.append("\n")
            out.append(format_record(r))
            if i < len(records) - 1:
                out.append(",")
        if records:
            out.append("\n")
        out.append("]")
    out.append("\n}\n")
    return "".join(out)


__all__ = [
    "escape_string",
    "format_float",
    "format_int",
    "format_record",
    "format_top_level",
    "format_value",
]
