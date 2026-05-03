"""v1.5 default codec stack per the M93 design spec §6 (Q5a = B).

When a :class:`~ttio.WrittenGenomicRun` is written with ``signal_compression="gzip"``
(the default) AND ``signal_codec_overrides`` is empty for a given channel,
the writer applies the codec from this table.

M93 registers ``sequences → REF_DIFF``; M94.Z adds ``qualities →
FQZCOMP_NX16_Z``. M95 added the integer channels — REMOVED in v1.6
(positions / flags / mapping_qualities now live exclusively under
genomic_index/, mirroring MS's spectrum_index/ pattern).

Cross-language: ObjC ``TTIODefaultCodecsV15``; Java
``codecs.DefaultCodecsV15``.
"""
from __future__ import annotations

from ttio.enums import Compression


# Channel-name → default codec when caller relies on signal_compression="gzip"
# auto-selection. If a channel is not in this table, the writer falls back to
# the existing ``signal_compression`` string path (zlib/none).
#
# v1.6: positions / flags / mapping_qualities / template_lengths
# REMOVED — these per-record integer fields are stored only under
# genomic_index/ (positions / flags / mapping_qualities) or inside
# the mate_info subgroup (template_lengths via mate_info_tlen).
DEFAULT_CODECS_V1_5: dict[str, Compression] = {
    "sequences": Compression.REF_DIFF,
    "qualities": Compression.FQZCOMP_NX16_Z,
    "mate_info_pos": Compression.RANS_ORDER0,
    "mate_info_tlen": Compression.RANS_ORDER0,
    "mate_info_chrom": Compression.NAME_TOKENIZED,
}


def default_codec_for(channel_name: str) -> Compression | None:
    """Return the v1.5 default codec for ``channel_name``, or None if no default."""
    return DEFAULT_CODECS_V1_5.get(channel_name)
