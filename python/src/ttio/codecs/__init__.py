"""TTI-O compression codecs — clean-room implementations.

All codecs in this package are implemented from published academic
literature. No third-party codec library source code is consulted.

Codecs:
    rans       — rANS order-0 and order-1 entropy coding (Duda 2014)
    base_pack  — 2-bit nucleotide packing (M84, future)
    quality    — Phred score quantisation (M84, future)
    name_tok   — Read name tokenisation (M85, future)
"""
from __future__ import annotations

from .rans import encode as rans_encode, decode as rans_decode

__all__ = ["rans_encode", "rans_decode"]
