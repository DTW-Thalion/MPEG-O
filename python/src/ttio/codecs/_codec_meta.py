"""Codec metadata registry — context-aware codecs (M93+) declare here.

A *context-aware* codec needs more than the channel's bytes to encode or
decode: it consumes sibling channels (e.g. ``positions``, ``cigars``)
and external resources (e.g. a :class:`~ttio.genomic.reference_resolver.ReferenceResolver`).
The M86 pipeline checks this registry to decide whether to plumb the
extra context to the codec call.

Cross-language: ObjC ``TTIOCodecMeta`` (M93+); Java ``codecs.CodecMeta``
(M93+). The registry is a simple frozen set keyed on the M79
``Compression`` enum and so does not need any cross-language wire
representation; each language hard-codes its own copy.
"""
from __future__ import annotations

from ttio.enums import Compression


# Codecs that take (channel_bytes, **context) at encode/decode time.
# Update when adding new context-aware codecs (e.g. mate_info encoders).
_CONTEXT_AWARE: frozenset[Compression] = frozenset(
    {
        Compression.REF_DIFF,     # M93 — needs positions, cigars, reference
        Compression.REF_DIFF_V2,  # v1.8 #11 — same; blob under group child
    }
)


def is_context_aware(codec: Compression) -> bool:
    """Return True if the codec needs sibling channels / external resources."""
    return codec in _CONTEXT_AWARE
