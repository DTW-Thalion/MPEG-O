"""v1.5 default codec stack per the M93 design spec §6 (Q5a = B).

When a :class:`~ttio.WrittenGenomicRun` is written with ``signal_compression="gzip"``
(the default) AND ``signal_codec_overrides`` is empty for a given channel,
the writer applies the codec from this table.

M93 registers ``sequences → REF_DIFF``; M94 adds ``qualities →
FQZCOMP_NX16``. M95 adds the integer channels.

Cross-language: ObjC ``TTIODefaultCodecsV15``; Java
``codecs.DefaultCodecsV15``.
"""
from __future__ import annotations

from ttio.enums import Compression


# Channel-name → default codec when caller relies on signal_compression="gzip"
# auto-selection. If a channel is not in this table, the writer falls back to
# the existing ``signal_compression`` string path (zlib/none).
DEFAULT_CODECS_V1_5: dict[str, Compression] = {
    "sequences": Compression.REF_DIFF,
    "qualities": Compression.FQZCOMP_NX16,
    "positions": Compression.DELTA_RANS_ORDER0,
    "flags": Compression.RANS_ORDER0,
    "mapping_qualities": Compression.RANS_ORDER0,
    "template_lengths": Compression.RANS_ORDER0,
    "mate_info_pos": Compression.RANS_ORDER0,
    "mate_info_tlen": Compression.RANS_ORDER0,
    "mate_info_chrom": Compression.NAME_TOKENIZED,
}


def default_codec_for(channel_name: str) -> Compression | None:
    """Return the v1.5 default codec for ``channel_name``, or None if no default."""
    return DEFAULT_CODECS_V1_5.get(channel_name)
