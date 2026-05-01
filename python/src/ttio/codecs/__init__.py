"""TTI-O compression codecs — clean-room implementations.

All codecs in this package are implemented from published academic
literature. No third-party codec library source code is consulted.

Codecs:
    rans       — rANS order-0 and order-1 entropy coding (Duda 2014)
    base_pack  — 2-bit nucleotide packing + sidecar mask (M84)
    quality    — Phred score quantisation (M85 Phase A)
    name_tok   — Read name tokenisation (M85 Phase B)
"""
from __future__ import annotations

from .base_pack import decode as base_pack_decode, encode as base_pack_encode
from .fqzcomp_nx16_z import (
    decode_with_metadata as fqzcomp_nx16_z_decode,
    encode as fqzcomp_nx16_z_encode,
)
from .name_tokenizer import decode as name_tok_decode, encode as name_tok_encode
from .quality import decode as quality_decode, encode as quality_encode
from .rans import decode as rans_decode, encode as rans_encode

__all__ = [
    "base_pack_decode",
    "base_pack_encode",
    "fqzcomp_nx16_z_decode",
    "fqzcomp_nx16_z_encode",
    "name_tok_decode",
    "name_tok_encode",
    "quality_decode",
    "quality_encode",
    "rans_decode",
    "rans_encode",
]
