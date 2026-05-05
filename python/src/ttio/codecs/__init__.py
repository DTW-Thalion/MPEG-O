"""TTI-O compression codecs — clean-room implementations.

All codecs in this package are implemented from published academic
literature. No third-party codec library source code is consulted.

Codecs:
    rans              — rANS order-0 and order-1 entropy coding (Duda 2014)
    base_pack         — 2-bit nucleotide packing + sidecar mask (M84)
    quality           — Phred score quantisation (Phase A)
    fqzcomp_nx16_z    — CRAM 3.1 fqzcomp_qual port (v1.5 / V4)
    mate_info_v2      — CRAM-style inline mate-pair encoding (v1.7, codec id 13)
    ref_diff_v2       — CRAM-style bit-packed sequence diff (v1.8, codec id 14)
    name_tokenizer_v2 — CRAM-style adaptive name-tokenizer (v1.8, codec id 15)

The v1 ``name_tokenizer`` (codec id 8) and ``ref_diff`` (codec id 9)
implementations were removed in the v1.0 reset (Phase 2c) — readers
reject files written with those codec ids; writers no longer emit them.
"""
from __future__ import annotations

from .base_pack import decode as base_pack_decode, encode as base_pack_encode
from .fqzcomp_nx16_z import (
    decode_with_metadata as fqzcomp_nx16_z_decode,
    encode as fqzcomp_nx16_z_encode,
)
from .quality import decode as quality_decode, encode as quality_encode
from .rans import decode as rans_decode, encode as rans_encode

__all__ = [
    "base_pack_decode",
    "base_pack_encode",
    "fqzcomp_nx16_z_decode",
    "fqzcomp_nx16_z_encode",
    "quality_decode",
    "quality_encode",
    "rans_decode",
    "rans_encode",
]
