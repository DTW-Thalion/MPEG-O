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


from ttio.codecs._registry import CODEC_REGISTRY, Codec
from ttio.enums import Compression


@pytest.mark.parametrize("cid", [
    Compression.RANS_ORDER0, Compression.RANS_ORDER1, Compression.BASE_PACK,
])
def test_plain_codec_registry_roundtrip(cid):
    # NOTE: QUALITY_BINNED is excluded — it is lossy by design (Phred binning),
    # so a byte-exact round-trip with arbitrary data is impossible. It gets its
    # own idempotency test below.
    codec = CODEC_REGISTRY[cid]
    assert codec.id == cid
    assert codec.is_context_aware is False
    data = bytes(range(64)) * 4
    enc = codec.encode(DecodedChannel.of_bytes(data), CodecContext.empty())
    assert enc.is_group is False
    dec = codec.decode(ChannelPayload.of_bytes(enc.dataset_bytes), CodecContext.empty())
    assert dec.as_bytes() == data


def _qb_roundtrip(codec, data: bytes) -> bytes:
    enc = codec.encode(DecodedChannel.of_bytes(data), CodecContext.empty())
    return codec.decode(ChannelPayload.of_bytes(enc.dataset_bytes), CodecContext.empty()).as_bytes()


def test_quality_binned_registry_idempotent_and_length_preserving():
    # QUALITY_BINNED is lossy (bins → bin centres). Assert the registry path is
    # length-preserving and idempotent (re-encoding bin centres is stable),
    # rather than byte-lossless.
    codec = CODEC_REGISTRY[Compression.QUALITY_BINNED]
    assert codec.id == Compression.QUALITY_BINNED
    assert codec.is_context_aware is False
    data = bytes(range(64)) * 4
    once = _qb_roundtrip(codec, data)
    twice = _qb_roundtrip(codec, once)
    assert len(once) == len(data)
    assert once == twice


def test_delta_rans_registry_roundtrip_needs_element_size():
    codec = CODEC_REGISTRY[Compression.DELTA_RANS_ORDER0]
    data = np.arange(100, dtype="<u4").tobytes()
    enc = codec.encode(DecodedChannel.of_bytes(data), CodecContext(element_size=4))
    dec = codec.decode(ChannelPayload.of_bytes(enc.dataset_bytes), CodecContext.empty())
    assert dec.as_bytes() == data
    with pytest.raises(ValueError):
        codec.encode(DecodedChannel.of_bytes(data), CodecContext.empty())


def test_registry_entry_id_matches_key():
    for cid, codec in CODEC_REGISTRY.items():
        assert codec.id == cid


def test_name_tokenized_registry_roundtrip():
    codec = CODEC_REGISTRY[Compression.NAME_TOKENIZED_V2]
    assert codec.is_context_aware is False
    names = [f"read{i}" for i in range(200)]
    enc = codec.encode(DecodedChannel.of_str_list(names), CodecContext.empty())
    dec = codec.decode(ChannelPayload.of_bytes(enc.dataset_bytes), CodecContext.empty())
    assert dec.as_str_list() == names


def test_context_aware_codecs_registered():
    for cid in (Compression.FQZCOMP_NX16_Z, Compression.MATE_INLINE_V2,
                Compression.REF_DIFF_V2, Compression.NAME_TOKENIZED_V2):
        assert cid in CODEC_REGISTRY
    assert CODEC_REGISTRY[Compression.REF_DIFF_V2].is_context_aware is True
    assert CODEC_REGISTRY[Compression.FQZCOMP_NX16_Z].is_context_aware is True
    assert CODEC_REGISTRY[Compression.MATE_INLINE_V2].is_context_aware is True


def test_genomic_run_has_codec_context():
    """GenomicRun exposes a _codec_context() builder (decode routing depends on it)."""
    from ttio.genomic_run import GenomicRun
    assert hasattr(GenomicRun, "_codec_context")


def test_delta_rans_encode_via_registry_matches_direct():
    from ttio.codecs import delta_rans
    data = np.arange(256, dtype="<u4").tobytes()
    direct = delta_rans.encode(data, 4)
    via = CODEC_REGISTRY[Compression.DELTA_RANS_ORDER0].encode(
        DecodedChannel.of_bytes(data), CodecContext(element_size=4)).dataset_bytes
    assert via == direct


def test_needs_embedded_reference_matches_legacy_meta():
    """needs_embedded_reference matches the legacy _CONTEXT_AWARE set ({REF_DIFF_V2})."""
    import importlib
    try:
        meta = importlib.import_module("ttio.codecs._codec_meta")
        legacy = set(getattr(meta, "_CONTEXT_AWARE"))
    except (ModuleNotFoundError, AttributeError):
        legacy = {Compression.REF_DIFF_V2}  # legacy membership (verified in T6)
    assert legacy == {Compression.REF_DIFF_V2}
    for cid, codec in CODEC_REGISTRY.items():
        assert codec.needs_embedded_reference == (cid in legacy), cid


def test_is_context_aware_is_broader_than_embed():
    """is_context_aware (needs CodecContext) is the broader flag."""
    aware = {cid for cid, c in CODEC_REGISTRY.items() if c.is_context_aware}
    embed = {cid for cid, c in CODEC_REGISTRY.items() if c.needs_embedded_reference}
    assert embed == {Compression.REF_DIFF_V2}
    assert {Compression.REF_DIFF_V2, Compression.FQZCOMP_NX16_Z,
            Compression.MATE_INLINE_V2} <= aware


def test_embed_predicate_safe_for_unregistered_compressions():
    """The reference-embed predicate must treat valid-but-unregistered codecs as
    False (not KeyError). Mirrors spectral_dataset._embed_references_for_runs."""
    # NONE/ZLIB/LZ4 are valid Compression members but are NOT registered codecs
    # (they are HDF5-native filters), so the embed predicate must not raise.
    for c in (Compression.NONE, Compression.ZLIB, Compression.LZ4):
        result = getattr(CODEC_REGISTRY.get(c), "needs_embedded_reference", False)
        assert result is False
    # REF_DIFF_V2 is the only registered codec that needs an embedded reference.
    assert getattr(CODEC_REGISTRY.get(Compression.REF_DIFF_V2),
                   "needs_embedded_reference", False) is True


def test_registry_covers_all_real_codec_ids():
    expected = {
        Compression.RANS_ORDER0, Compression.RANS_ORDER1, Compression.BASE_PACK,
        Compression.QUALITY_BINNED, Compression.DELTA_RANS_ORDER0,
        Compression.FQZCOMP_NX16_Z, Compression.MATE_INLINE_V2,
        Compression.REF_DIFF_V2, Compression.NAME_TOKENIZED_V2,
    }
    assert expected.issubset(set(CODEC_REGISTRY.keys()))
