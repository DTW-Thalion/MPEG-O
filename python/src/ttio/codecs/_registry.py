"""Codec registry: maps Compression ids to Codec adapters (codec-registry refactor).

Context-aware codecs are added in Task 3. No wire change — adapters wrap the
existing codec functions verbatim.
"""
from __future__ import annotations

from typing import Protocol

from ..enums import Compression
from . import base_pack, delta_rans, quality, rans
from ._context import ChannelPayload, CodecContext, DecodedChannel, EncodedChannel


class Codec(Protocol):
    id: Compression
    is_context_aware: bool

    def decode(self, payload: ChannelPayload, ctx: CodecContext) -> DecodedChannel: ...
    def encode(self, value: DecodedChannel, ctx: CodecContext) -> EncodedChannel: ...


class _RansCodec:
    """rANS O0/O1. decode() is order-agnostic (order is in the stream)."""
    def __init__(self, cid: Compression, order: int) -> None:
        self.id = cid
        self._order = order
        self.is_context_aware = False

    def decode(self, payload, ctx):
        return DecodedChannel.of_bytes(rans.decode(payload.as_bytes()))

    def encode(self, value, ctx):
        return EncodedChannel.of_dataset(rans.encode(value.as_bytes(), order=self._order))


class _BasePackCodec:
    id = Compression.BASE_PACK
    is_context_aware = False

    def decode(self, payload, ctx):
        return DecodedChannel.of_bytes(base_pack.decode(payload.as_bytes()))

    def encode(self, value, ctx):
        return EncodedChannel.of_dataset(base_pack.encode(value.as_bytes()))


class _QualityBinnedCodec:
    id = Compression.QUALITY_BINNED
    is_context_aware = False

    def decode(self, payload, ctx):
        return DecodedChannel.of_bytes(quality.decode(payload.as_bytes()))

    def encode(self, value, ctx):
        return EncodedChannel.of_dataset(quality.encode(value.as_bytes()))


class _DeltaRansCodec:
    id = Compression.DELTA_RANS_ORDER0
    is_context_aware = False

    def decode(self, payload, ctx):
        return DecodedChannel.of_bytes(delta_rans.decode(payload.as_bytes()))

    def encode(self, value, ctx):
        if ctx.element_size is None:
            raise ValueError("DELTA_RANS encode requires CodecContext.element_size")
        return EncodedChannel.of_dataset(
            delta_rans.encode(value.as_bytes(), ctx.element_size)
        )


CODEC_REGISTRY: "dict[Compression, Codec]" = {
    Compression.RANS_ORDER0: _RansCodec(Compression.RANS_ORDER0, 0),
    Compression.RANS_ORDER1: _RansCodec(Compression.RANS_ORDER1, 1),
    Compression.BASE_PACK: _BasePackCodec(),
    Compression.QUALITY_BINNED: _QualityBinnedCodec(),
    Compression.DELTA_RANS_ORDER0: _DeltaRansCodec(),
}
