"""Base64 + optional zlib decode for mzML / nmrML binary payloads.

Cross-language equivalents
--------------------------
Objective-C: ``TTIOBase64`` class · Java:
uses ``java.util.Base64`` from the standard library directly — no
TTIO wrapper needed.

API status: Stable (internal helper).
"""
from __future__ import annotations

import base64
import zlib


def decode(text: str, *, zlib_compressed: bool) -> bytes:
    """Decode a base64 payload, optionally running the output through zlib.

    Whitespace inside the base64 string is tolerated. ``zlib_compressed``
    corresponds to the PSI-MS ``zlib`` compression cvParam (MS:1000574) or
    the nmrML ``compressed="true"`` attribute.
    """
    cleaned = "".join(text.split())
    raw = base64.b64decode(cleaned, validate=False)
    if zlib_compressed:
        raw = zlib.decompress(raw)
    return raw
