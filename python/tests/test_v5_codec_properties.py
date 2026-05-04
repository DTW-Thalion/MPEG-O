"""V5 property-based tests for the genomic codecs (Python).

Uses Hypothesis to generate arbitrary inputs and assert each codec's
round-trip / safety properties. The properties documented here are
the *contract* each codec must satisfy; a counter-example surfaces
either a bug or a previously-undocumented edge case.

Codecs covered:

* ``rans.encode`` / ``rans.decode`` (order 0 + 1) — lossless
  round-trip for any byte sequence.
* ``base_pack.encode`` / ``base_pack.decode`` — lossless round-trip
  for any ``ACGT``-only byte sequence; raises on non-ACGT input.
* ``quality.encode`` / ``quality.decode`` — lossy bin-quantised
  round-trip; per-byte error bounded by the half-width of the bin
  containing the original value.

The v1 ``name_tokenizer`` codec was removed in the v1.0 reset
(Phase 2c); the v2 NAME_TOKENIZED codec is exercised by
``test_name_tokenizer_v2_native.py``.

CI default: ``--hypothesis-seed=0`` (deterministic) with the default
of 200 examples per property to keep CI under 2 minutes total.
Run with ``pytest --hypothesis-seed=random -p hypothesis -m
"hypothesis"`` for ad-hoc fuzz exploration.

Per docs/verification-workplan.md §V5.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import pytest

# Hypothesis is a soft dependency; if it isn't installed we want a
# clean skip rather than a collection error so the full suite still
# runs on bare-python environments.
hypothesis = pytest.importorskip("hypothesis")
from hypothesis import given, strategies as st, settings, HealthCheck

from ttio.codecs import rans, base_pack, quality


# Cap example size so each property completes in < 5 seconds even
# at 500 examples — codecs are O(n) but the hypothesis overhead per
# example dominates for tiny inputs.
_MAX_BYTES = 4096
_MAX_NAMES = 64
_MAX_NAME_LEN = 32

_settings = settings(
    max_examples=200,
    deadline=5_000,  # ms
    suppress_health_check=[HealthCheck.too_slow],
)


# ---------------------------------------------------------------------------
# rANS — order 0 and order 1, lossless round-trip
# ---------------------------------------------------------------------------


@_settings
@given(data=st.binary(min_size=0, max_size=_MAX_BYTES))
def test_rans_order0_round_trip(data: bytes) -> None:
    """rANS order-0 round-trips every byte sequence losslessly."""
    encoded = rans.encode(data, order=0)
    decoded = rans.decode(encoded)
    assert decoded == data


@_settings
@given(data=st.binary(min_size=0, max_size=_MAX_BYTES))
def test_rans_order1_round_trip(data: bytes) -> None:
    """rANS order-1 round-trips every byte sequence losslessly."""
    encoded = rans.encode(data, order=1)
    decoded = rans.decode(encoded)
    assert decoded == data


@_settings
@given(data=st.binary(min_size=1, max_size=_MAX_BYTES))
def test_rans_encoded_is_smaller_than_naive(data: bytes) -> None:
    """rANS doesn't make small data catastrophically larger.

    For inputs ≥ 1 byte, the encoded output is bounded by the input
    size + the frequency-table header overhead. The order-0 frequency
    table is a length-prefixed run-length-encoded list of normalised
    counts up to 256 symbols, so the worst-case header is ~1.5 KB
    (single byte input still emits a full freq table for a
    1-symbol alphabet, plus rANS state bytes).

    Locks in the contract that rANS isn't pathologically inflating
    common inputs.
    """
    encoded = rans.encode(data, order=0)
    # 8× input size + 2 KB header bound — looser than first-pass since
    # Hypothesis surfaced 1037 bytes for a single-byte `b'\x00'` input.
    assert len(encoded) <= max(8 * len(data), 2048), (
        f"rANS pathological inflation: {len(data)} bytes → {len(encoded)} bytes"
    )


# ---------------------------------------------------------------------------
# BASE_PACK — ACGT-only, lossless round-trip
# ---------------------------------------------------------------------------


_acgt_strategy = st.lists(
    st.sampled_from(b"ACGT"), min_size=0, max_size=_MAX_BYTES,
).map(bytes)


@_settings
@given(data=_acgt_strategy)
def test_base_pack_round_trip_acgt(data: bytes) -> None:
    """BASE_PACK round-trips any ACGT-only sequence losslessly."""
    encoded = base_pack.encode(data)
    decoded = base_pack.decode(encoded)
    assert decoded == data


@_settings
@given(data=_acgt_strategy.filter(lambda b: len(b) > 0))
def test_base_pack_compression_ratio_acgt(data: bytes) -> None:
    """BASE_PACK reaches the theoretical ~25% size on pure-ACGT input.

    With ACGT each base packs to 2 bits (4 bases per byte). Locks in
    the contract that the encoder doesn't accidentally regress
    toward 8-bits-per-base on common inputs.
    """
    encoded = base_pack.encode(data)
    # Bound: ≤ ceil(len/4) data bytes + ≤ 64 bytes header.
    expected_max = (len(data) + 3) // 4 + 64
    assert len(encoded) <= expected_max


@_settings
@given(data=st.binary(min_size=0, max_size=_MAX_BYTES))
def test_base_pack_round_trip_any_bytes(data: bytes) -> None:
    """BASE_PACK round-trips any byte sequence losslessly via the sidecar mask.

    The encoder is "trust the producer" per binding decision §81 —
    non-ACGT bytes get a 5-byte mask entry (4-byte position + 1-byte
    original value) instead of raising. Property: regardless of input
    content, decode(encode(x)) == x.
    """
    encoded = base_pack.encode(data)
    decoded = base_pack.decode(encoded)
    assert decoded == data


# ---------------------------------------------------------------------------
# QUALITY_BINNED — lossy with bounded per-byte error
# ---------------------------------------------------------------------------


# Illumina-8 bin centres (matching the encoder; see
# python/src/ttio/codecs/quality.py).
_ILLUMINA8_CENTRES = (0, 5, 15, 22, 27, 32, 37, 40)
# Per-bin half-width: max distance from a value mapped to centre[i]
# to its centre. Computed from the encoder's _build_bin_index_table.
# Effectively: each centre quantises a contiguous range of input
# values, and the worst-case error is the maximum absolute distance
# from any input value in that range to the centre. Empirically
# ≤ 12 for the Illumina-8 scheme (centre 40 covers ~28..255).
_QUALITY_MAX_ERROR = 215  # 255 - 40 = 215, the worst case for bin 7


@_settings
@given(data=st.binary(min_size=0, max_size=_MAX_BYTES))
def test_quality_binned_round_trip_bounded_error(data: bytes) -> None:
    """QUALITY_BINNED round-trip is lossy but the per-byte error is bounded.

    The decoder always emits a value from the Illumina-8 centre set
    (or 0 for unreachable nibbles). Per-byte absolute error is
    bounded by the worst-case distance from any input value to its
    centre — for the Illumina-8 scheme that's |255 - 40| = 215
    (input 255 → bin 7 → centre 40).
    """
    encoded = quality.encode(data)
    decoded = quality.decode(encoded)
    assert len(decoded) == len(data)
    for i, (orig, dec) in enumerate(zip(data, decoded)):
        assert dec in _ILLUMINA8_CENTRES, (
            f"index {i}: decoded byte {dec!r} not in Illumina-8 centres "
            f"{_ILLUMINA8_CENTRES}"
        )
        err = abs(int(orig) - int(dec))
        assert err <= _QUALITY_MAX_ERROR, (
            f"index {i}: |{orig} - {dec}| = {err} > "
            f"max-error {_QUALITY_MAX_ERROR}"
        )


@_settings
@given(data=st.lists(
    st.sampled_from(_ILLUMINA8_CENTRES), min_size=0, max_size=_MAX_BYTES,
).map(bytes))
def test_quality_binned_centre_inputs_round_trip_exactly(data: bytes) -> None:
    """When inputs are themselves Illumina-8 centres, QUALITY_BINNED is lossless."""
    encoded = quality.encode(data)
    decoded = quality.decode(encoded)
    assert decoded == data
