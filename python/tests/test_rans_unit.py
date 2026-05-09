"""Unit tests for the pure-Python rANS reference path.

The Cython acceleration in :mod:`ttio.codecs._rans` short-circuits the
public :func:`ttio.codecs.rans.encode` / :func:`decode` away from the
pure-Python implementation, so the reference functions stay
uncovered in the default coverage run. These tests target
``_encode_order0`` / ``_decode_order0`` / ``_encode_order1`` /
``_decode_order1`` and the frequency-table (de)serialisers
directly so the byte-exact reference path is exercised end-to-end.

This complements ``test_m83_rans.py`` (which covers the public API
through the Cython fast path).
"""
from __future__ import annotations

import pytest

from ttio.codecs import rans as R


# ---------------------------------------------------------------- helpers ---


def _force_python_roundtrip(data: bytes, order: int) -> bytes:
    """Encode/decode through the public API but explicitly disable the
    Cython fast path so the pure-Python branches (lines 522, 528, 577,
    581 in the source) are exercised."""
    saved = R._HAVE_C_EXTENSION
    R._HAVE_C_EXTENSION = False
    try:
        enc = R.encode(data, order)
        return R.decode(enc)
    finally:
        R._HAVE_C_EXTENSION = saved


# ---------------------------------------------------- _normalise_freqs ---

# Note: the "alphabet too large" error path in _normalise_freqs is unreachable
# from the public API (which fixes the alphabet at 256 with M=4096); it would
# only fire for M-symbol alphabets. No behavioural test covers it.


class TestNormaliseFreqs:
    def test_uniform_input_normalises_to_M(self) -> None:
        cnt = [4] * 256  # uniform
        freq = R._normalise_freqs(cnt)
        assert sum(freq) == R.M
        assert all(f == R.M // 256 for f in freq)

    def test_skewed_input_preserves_M_total(self) -> None:
        # Heavy on byte 0, sparse elsewhere — exercises the +1 redistribution
        # path (delta > 0).
        cnt = [0] * 256
        cnt[0] = 1000
        cnt[1] = 3
        cnt[2] = 1
        freq = R._normalise_freqs(cnt)
        assert sum(freq) == R.M
        # Symbols with cnt > 0 must have freq >= 1.
        assert freq[0] >= 1
        assert freq[1] >= 1
        assert freq[2] >= 1
        # Symbols with cnt == 0 must have freq == 0.
        for s in range(3, 256):
            assert freq[s] == 0

    def test_negative_delta_subtraction_path(self) -> None:
        # 200 symbols at scaled = max(1, 1*M//200) = max(1, 20) = 20, summing to
        # 4000 < M=4096 — but the floored proportional scale combined with the
        # round-robin top-up exercises the negative-delta subtraction branch.
        cnt = [1] * 200 + [0] * 56
        freq = R._normalise_freqs(cnt)
        assert sum(freq) == R.M

    def test_wrong_length_raises(self) -> None:
        with pytest.raises(ValueError, match="length 256"):
            R._normalise_freqs([1] * 100)

    def test_empty_count_vector_raises(self) -> None:
        with pytest.raises(ValueError, match="empty"):
            R._normalise_freqs([0] * 256)

    def test_single_symbol_collapses_to_M(self) -> None:
        cnt = [0] * 256
        cnt[42] = 7
        freq = R._normalise_freqs(cnt)
        assert freq[42] == R.M
        assert sum(freq) == R.M
        for s in range(256):
            if s != 42:
                assert freq[s] == 0


# ------------------------------------------------------ _cumulative ---


class TestCumulative:
    def test_basic_cumulative_sums(self) -> None:
        freq = [0] * 256
        freq[0] = 100
        freq[1] = 200
        freq[5] = 50
        cum = R._cumulative(freq)
        assert len(cum) == 257
        assert cum[0] == 0
        assert cum[1] == 100
        assert cum[2] == 300
        assert cum[5] == 300
        assert cum[6] == 350
        assert cum[256] == 350


# ------------------------------------------------------- _slot_to_symbol ---


class TestSlotToSymbol:
    def test_single_symbol_full_table(self) -> None:
        freq = [0] * 256
        freq[7] = R.M
        table = R._slot_to_symbol(freq)
        assert len(table) == R.M
        assert all(s == 7 for s in table)

    def test_two_symbols_split(self) -> None:
        freq = [0] * 256
        freq[1] = R.M // 2
        freq[2] = R.M // 2
        table = R._slot_to_symbol(freq)
        assert table[0] == 1
        assert table[R.M // 2 - 1] == 1
        assert table[R.M // 2] == 2
        assert table[R.M - 1] == 2


# -------------------------------------------- _encode/_decode_order0 ---


class TestEncodeOrder0:
    def test_round_trip_short_input(self) -> None:
        data = b"hello world rANS reference"
        payload, freq = R._encode_order0(data)
        # Payload starts with 4 bytes of final state.
        assert len(payload) >= 4
        assert sum(freq) == R.M
        recovered = R._decode_order0(payload, len(data), freq)
        assert recovered == data

    def test_round_trip_64_bytes(self) -> None:
        data = bytes(range(64))
        payload, freq = R._encode_order0(data)
        recovered = R._decode_order0(payload, len(data), freq)
        assert recovered == data

    def test_round_trip_4kb_skewed(self) -> None:
        # Heavily skewed payload — exercises hot loop with non-trivial
        # renormalisation.
        data = bytes([0] * 3000 + [1] * 700 + [2] * 296 + [3] * 100)
        payload, freq = R._encode_order0(data)
        recovered = R._decode_order0(payload, len(data), freq)
        assert recovered == data

    def test_empty_input_returns_seed_state(self) -> None:
        payload, freq = R._encode_order0(b"")
        # Empty input emits just the 4-byte state seed.
        assert payload == R.L.to_bytes(4, "big")
        # Default flat freq table sums to M.
        assert sum(freq) == R.M
        # Decode of empty input returns empty.
        assert R._decode_order0(payload, 0, freq) == b""

    def test_decode_truncated_payload_raises(self) -> None:
        # Payload too short to contain bootstrap state.
        with pytest.raises(ValueError, match="too short"):
            R._decode_order0(b"\x00\x00", 5, [R.M // 256] * 256)

    def test_decode_premature_eof_during_renorm(self) -> None:
        data = b"abc" * 100
        payload, freq = R._encode_order0(data)
        # Truncate the payload: the renormalisation loop will run out of
        # bytes mid-stream.
        with pytest.raises(ValueError, match="unexpected end of payload"):
            R._decode_order0(payload[:8], len(data), freq)


# -------------------------------------------- _encode/_decode_order1 ---


class TestEncodeOrder1:
    def test_round_trip_cyclic(self) -> None:
        data = bytes([i % 4 for i in range(512)])
        payload, freqs = R._encode_order1(data)
        recovered = R._decode_order1(payload, len(data), freqs)
        assert recovered == data

    def test_round_trip_random_short(self) -> None:
        import os as _os
        data = _os.urandom(256)
        payload, freqs = R._encode_order1(data)
        recovered = R._decode_order1(payload, len(data), freqs)
        assert recovered == data

    def test_empty_input(self) -> None:
        payload, freqs = R._encode_order1(b"")
        assert payload == R.L.to_bytes(4, "big")
        # All freq rows are zero for empty input.
        for row in freqs:
            assert sum(row) == 0
        assert R._decode_order1(payload, 0, freqs) == b""

    def test_single_byte(self) -> None:
        data = b"\xab"
        payload, freqs = R._encode_order1(data)
        recovered = R._decode_order1(payload, 1, freqs)
        assert recovered == data

    def test_decode_truncated_payload_raises(self) -> None:
        with pytest.raises(ValueError, match="too short"):
            R._decode_order1(b"\x00\x00\x00", 5, [[0] * 256 for _ in range(256)])

    def test_decode_empty_context_raises(self) -> None:
        # Build a stream where the prev context has no frequencies.
        # Encode a single byte in context 0, then truncate the freqs so
        # that the lookup fails on the first transition.
        data = b"\x05\x07"
        payload, freqs = R._encode_order1(data)
        # Wipe the row for symbol 5 so decoding the second byte (ctx=5)
        # hits the empty-table guard.
        freqs[5] = [0] * 256
        with pytest.raises(ValueError, match="empty frequency table"):
            R._decode_order1(payload, 2, freqs)

    def test_decode_premature_eof(self) -> None:
        # Use random-ish data with long output so truncation forces
        # renormalisation past the last available byte.
        import os as _os
        data = _os.urandom(2000)
        payload, freqs = R._encode_order1(data)
        # Keep only the bootstrap state — decoder will need many
        # renorm bytes for 2000 symbols.
        with pytest.raises(ValueError, match="unexpected end of payload"):
            R._decode_order1(payload[:4], len(data), freqs)


# ------------------------------------------------- _build_order1_counts ---


class TestBuildOrder1Counts:
    def test_empty_input(self) -> None:
        tables = R._build_order1_counts(b"")
        assert len(tables) == 256
        for row in tables:
            assert sum(row) == 0

    def test_first_byte_uses_zero_context(self) -> None:
        tables = R._build_order1_counts(b"\x05\x07")
        # First byte: ctx=0, sym=5 → tables[0][5] += 1
        # Second: ctx=5, sym=7 → tables[5][7] += 1
        assert tables[0][5] == 1
        assert tables[5][7] == 1

    def test_repeated_pattern(self) -> None:
        tables = R._build_order1_counts(b"ABABAB")
        # A=0x41, B=0x42; first ctx=0 → tables[0][A] = 1
        # Then transitions: A→B (3 times: positions 1,3,5), B→A (2 times: positions 2,4)
        assert tables[0][0x41] == 1
        assert tables[0x41][0x42] == 3
        assert tables[0x42][0x41] == 2


# ------------------------------------------- freq-table (de)serialisers ---


class TestSerialiseFreqsO0:
    def test_round_trip(self) -> None:
        cnt = [0] * 256
        cnt[10] = 100
        cnt[20] = 200
        cnt[30] = 50
        freq = R._normalise_freqs(cnt)
        buf = R._serialise_freqs_o0(freq)
        assert len(buf) == 1024
        recovered, off = R._deserialise_freqs_o0(buf, 0)
        assert off == 1024
        assert recovered == freq

    def test_truncated_buffer_raises(self) -> None:
        with pytest.raises(ValueError, match="truncated"):
            R._deserialise_freqs_o0(b"\x00" * 100, 0)

    def test_bad_sum_raises(self) -> None:
        # All zero buffer → sum = 0 ≠ M.
        with pytest.raises(ValueError, match="!= M"):
            R._deserialise_freqs_o0(b"\x00" * 1024, 0)


class TestSerialiseFreqsO1:
    def test_round_trip(self) -> None:
        # Build via the encoder so each row is valid.
        _, freqs = R._encode_order1(b"hello world hello world")
        buf = R._serialise_freqs_o1(freqs)
        recovered, off = R._deserialise_freqs_o1(buf, 0)
        assert off == len(buf)
        assert recovered == freqs

    def test_truncated_count_field_raises(self) -> None:
        # Buffer only has one byte where 2 are needed for n_nonzero.
        with pytest.raises(ValueError, match="truncated \\(count\\)"):
            R._deserialise_freqs_o1(b"\x00", 0)

    def test_truncated_entry_raises(self) -> None:
        # n_nonzero=1 but missing the 3 entry bytes.
        buf = b"\x00\x01\x05"  # n_nonzero=1, then incomplete entry
        with pytest.raises(ValueError, match="truncated \\(entry\\)"):
            R._deserialise_freqs_o1(buf, 0)

    def test_zero_freq_in_nonzero_entry_raises(self) -> None:
        # n_nonzero=1, sym=5, freq=0 → invalid.
        buf = b"\x00\x01\x05\x00\x00"
        with pytest.raises(ValueError, match="freq 0"):
            R._deserialise_freqs_o1(buf, 0)


# ----------------------------------------- public API edge branches ---


class TestPublicApiBranches:
    def test_encode_rejects_unsupported_order(self) -> None:
        with pytest.raises(ValueError, match="unsupported order"):
            R.encode(b"abc", order=3)

    def test_encode_rejects_non_bytes(self) -> None:
        with pytest.raises(TypeError, match="bytes-like"):
            R.encode("string", order=0)  # type: ignore[arg-type]

    def test_encode_accepts_bytearray(self) -> None:
        out = R.encode(bytearray(b"hello"), order=0)
        assert R.decode(out) == b"hello"

    def test_encode_accepts_memoryview(self) -> None:
        mv = memoryview(b"hello")
        out = R.encode(mv, order=0)
        assert R.decode(out) == b"hello"

    def test_decode_rejects_non_bytes(self) -> None:
        with pytest.raises(TypeError, match="bytes-like"):
            R.decode(12345)  # type: ignore[arg-type]

    def test_decode_rejects_unknown_order_byte(self) -> None:
        with pytest.raises(ValueError, match="unsupported order byte"):
            R.decode(b"\x07" + b"\x00" * 8)

    def test_decode_too_short_for_header(self) -> None:
        with pytest.raises(ValueError, match="shorter than header"):
            R.decode(b"\x00\x01")

    def test_python_roundtrip_order0_with_extension_disabled(self) -> None:
        # Forces the non-Cython branches at lines 522 and 577.
        data = b"the quick brown fox jumps over the lazy dog" * 10
        recovered = _force_python_roundtrip(data, 0)
        assert recovered == data

    def test_python_roundtrip_order1_with_extension_disabled(self) -> None:
        # Forces the non-Cython branches at lines 528 and 581.
        data = b"abracadabra " * 30
        recovered = _force_python_roundtrip(data, 1)
        assert recovered == data
