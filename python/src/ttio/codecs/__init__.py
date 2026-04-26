"""TTI-O compression codecs — clean-room implementations.

All codecs in this package are implemented from published academic
literature. No third-party codec library source code is consulted.

Codecs:
    rans       — rANS order-0 and order-1 entropy coding (Duda 2014)
    base_pack  — 2-bit nucleotide packing + sidecar mask (M84)
    quality    — Phred score quantisation (M84, future)
    name_tok   — Read name tokenisation (M85, future)
"""
from __future__ import annotations

from .base_pack import decode as base_pack_decode, encode as base_pack_encode
from .rans import decode as rans_decode, encode as rans_encode

__all__ = [
    "base_pack_decode",
    "base_pack_encode",
    "rans_decode",
    "rans_encode",
]
