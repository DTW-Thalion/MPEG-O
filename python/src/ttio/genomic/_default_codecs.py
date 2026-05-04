"""Default codec stack for the v1.0 genomic pipeline.

When a :class:`~ttio.WrittenGenomicRun` is written with ``signal_compression="gzip"``
(the default) AND ``signal_codec_overrides`` is empty for a given channel,
the writer applies the codec from this table.

v1.0 reset (Phase 2c): the v1 REF_DIFF (codec id 9) implementation
was removed; ``sequences`` now defaults directly to REF_DIFF_V2
(codec id 14). FQZCOMP_NX16_Z (codec id 12) remains the qualities
default — the V4 internal flavour (CRAM 3.1 fqzcomp_qual port) is
the only decoded path; the V1/V2/V3 reader headers were also
removed in Phase 2c.

M95 added the integer channels — REMOVED in v1.6 (positions / flags
/ mapping_qualities now live exclusively under genomic_index/,
mirroring MS's spectrum_index/ pattern).

v1.7: mate_info_chrom / pos / tlen REMOVED — the three per-field
streams are superseded by the single inline_v2 blob (codec id 13,
MATE_INLINE_V2). Setting any mate_info_* key in
signal_codec_overrides raises ValueError.

Cross-language: ObjC ``TTIODefaultCodecsV15``; Java
``codecs.DefaultCodecsV15``.
"""
from __future__ import annotations

from ttio.enums import Compression


# Channel-name → default codec when caller relies on signal_compression="gzip"
# auto-selection. If a channel is not in this table, the writer falls back to
# the existing ``signal_compression`` string path (zlib/none).
#
# v1.0 reset (Phase 2c): sequences → REF_DIFF_V2 (was REF_DIFF v1).
DEFAULT_CODECS_V1_5: dict[str, Compression] = {
    "sequences": Compression.REF_DIFF_V2,
    "qualities": Compression.FQZCOMP_NX16_Z,
}


def default_codec_for(channel_name: str) -> Compression | None:
    """Return the v1.5 default codec for ``channel_name``, or None if no default."""
    return DEFAULT_CODECS_V1_5.get(channel_name)
