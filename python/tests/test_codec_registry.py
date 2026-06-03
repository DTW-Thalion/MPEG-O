"""Codec registry + value-object tests (codec-registry refactor)."""
from __future__ import annotations

import numpy as np
import pytest

from ttio.codecs._context import (
    CodecContext, ChannelPayload, DecodedChannel, EncodedChannel,
)


def test_decoded_channel_bytes_roundtrip():
    d = DecodedChannel.of_bytes(b"abc")
    assert d.as_bytes() == b"abc"
    with pytest.raises(TypeError):
        d.as_str_list()


def test_decoded_channel_str_list():
    d = DecodedChannel.of_str_list(["r1", "r2"])
    assert d.as_str_list() == ["r1", "r2"]
    with pytest.raises(TypeError):
        d.as_bytes()


def test_decoded_channel_mate_info():
    d = DecodedChannel.of_mate_info({"x": 1})
    assert d.as_mate_info() == {"x": 1}
    with pytest.raises(TypeError):
        d.as_bytes()


def test_encoded_channel_variants():
    a = EncodedChannel.of_dataset(b"xy")
    assert a.is_group is False and a.dataset_bytes == b"xy"
    b = EncodedChannel.of_group({"refdiff_v2": b"zz"}, {"k": 1})
    assert b.is_group is True and b.group_children["refdiff_v2"] == b"zz"


def test_channel_payload_bytes_vs_group():
    p = ChannelPayload.of_bytes(b"q")
    assert p.as_bytes() == b"q"
    with pytest.raises(TypeError):
        p.group()


def test_codec_context_empty_is_all_none():
    ctx = CodecContext.empty()
    assert ctx.read_lengths is None and ctx.element_size is None
    assert ctx.reference_resolver is None and ctx.cigars_provider is None
