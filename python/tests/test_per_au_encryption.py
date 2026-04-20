"""v1.0 per-AU encryption primitive tests.

Covers the encryption_per_au module's AAD binding, channel-segment
round-trip, header-segment round-trip, and tamper detection. HDF5
integration + transport wire tests land in subsequent commits.
"""
from __future__ import annotations

import os

import numpy as np
import pytest

pytest.importorskip("cryptography")

from mpeg_o.encryption_per_au import (
    ChannelSegment,
    HeaderSegment,
    aad_for_channel,
    aad_for_header,
    aad_for_pixel,
    decrypt_channel_from_segments,
    decrypt_header_segments,
    decrypt_with_aad,
    encrypt_channel_to_segments,
    encrypt_header_segments,
    encrypt_with_aad,
    pack_au_header_plaintext,
    unpack_au_header_plaintext,
)


KEY = b"0123456789abcdef0123456789abcdef"  # 32 bytes


# ---------------------------------------------------------- AAD


class TestAAD:

    def test_channel_aad_layout(self):
        # dataset_id=1 au_sequence=42 channel="intensity"
        # Expected: 01 00 2a 00 00 00 69 6e 74 65 6e 73 69 74 79
        aad = aad_for_channel(1, 42, "intensity")
        assert aad == b"\x01\x00\x2a\x00\x00\x00intensity"

    def test_header_aad_layout(self):
        aad = aad_for_header(0x42, 0x1234)
        # 0x42 0x00 | 0x34 0x12 0x00 0x00 | "header"
        assert aad == b"\x42\x00\x34\x12\x00\x00header"

    def test_pixel_aad_layout(self):
        aad = aad_for_pixel(1, 0)
        assert aad == b"\x01\x00\x00\x00\x00\x00pixel"


# ---------------------------------------------------------- primitives


class TestPrimitives:

    def test_encrypt_decrypt_roundtrip(self):
        aad = b"test-aad"
        iv, tag, ciphertext = encrypt_with_aad(b"hello world", KEY, aad)
        assert len(iv) == 12
        assert len(tag) == 16
        plain = decrypt_with_aad(iv, tag, ciphertext, KEY, aad)
        assert plain == b"hello world"

    def test_fixed_iv_is_deterministic(self):
        fixed_iv = b"\x00" * 12
        a = encrypt_with_aad(b"identical", KEY, b"aad", iv=fixed_iv)
        b = encrypt_with_aad(b"identical", KEY, b"aad", iv=fixed_iv)
        assert a == b  # same IV + same plaintext + same key = same ciphertext

    def test_tamper_tag_fails(self):
        iv, tag, ciphertext = encrypt_with_aad(b"payload", KEY, b"aad")
        bad_tag = bytes([tag[0] ^ 1]) + tag[1:]
        with pytest.raises(Exception):
            decrypt_with_aad(iv, bad_tag, ciphertext, KEY, b"aad")

    def test_tamper_ciphertext_fails(self):
        iv, tag, ciphertext = encrypt_with_aad(b"payload", KEY, b"aad")
        bad_ct = bytes([ciphertext[0] ^ 1]) + ciphertext[1:]
        with pytest.raises(Exception):
            decrypt_with_aad(iv, tag, bad_ct, KEY, b"aad")

    def test_wrong_aad_fails(self):
        iv, tag, ciphertext = encrypt_with_aad(b"payload", KEY, b"aad-a")
        with pytest.raises(Exception):
            decrypt_with_aad(iv, tag, ciphertext, KEY, b"aad-b")


# ---------------------------------------------------------- channel segments


class TestChannelSegments:

    def test_roundtrip_three_spectra(self):
        # 3 spectra × 4 points each = 12 float64 values.
        plain = np.arange(12, dtype="<f8") * 10.0
        offsets = np.array([0, 4, 8], dtype="<u8")
        lengths = np.array([4, 4, 4], dtype="<u4")
        segments = encrypt_channel_to_segments(
            plain, offsets, lengths,
            dataset_id=1, channel_name="intensity", key=KEY,
        )
        assert len(segments) == 3
        assert all(len(s.iv) == 12 and len(s.tag) == 16 for s in segments)
        # Each segment is 4 × 8 = 32 bytes ciphertext.
        assert all(len(s.ciphertext) == 32 for s in segments)

        recovered = decrypt_channel_from_segments(
            segments,
            dataset_id=1, channel_name="intensity", key=KEY,
        )
        np.testing.assert_array_equal(plain, recovered)

    def test_varying_lengths(self):
        # Ragged: 2, 5, 1 points.
        plain = np.array([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0], dtype="<f8")
        offsets = np.array([0, 2, 7], dtype="<u8")
        lengths = np.array([2, 5, 1], dtype="<u4")
        segments = encrypt_channel_to_segments(
            plain, offsets, lengths,
            dataset_id=7, channel_name="mz", key=KEY,
        )
        recovered = decrypt_channel_from_segments(
            segments, dataset_id=7, channel_name="mz", key=KEY,
        )
        np.testing.assert_array_equal(plain, recovered)

    def test_wrong_dataset_id_rejected(self):
        plain = np.arange(4, dtype="<f8")
        offsets = np.array([0], dtype="<u8")
        lengths = np.array([4], dtype="<u4")
        segments = encrypt_channel_to_segments(
            plain, offsets, lengths,
            dataset_id=1, channel_name="mz", key=KEY,
        )
        with pytest.raises(Exception):
            decrypt_channel_from_segments(
                segments, dataset_id=99, channel_name="mz", key=KEY,
            )

    def test_wrong_channel_name_rejected(self):
        plain = np.arange(4, dtype="<f8")
        segments = encrypt_channel_to_segments(
            plain,
            np.array([0], dtype="<u8"), np.array([4], dtype="<u4"),
            dataset_id=1, channel_name="mz", key=KEY,
        )
        with pytest.raises(Exception):
            decrypt_channel_from_segments(
                segments, dataset_id=1, channel_name="intensity", key=KEY,
            )

    def test_wrong_key_rejected(self):
        plain = np.arange(4, dtype="<f8")
        segments = encrypt_channel_to_segments(
            plain,
            np.array([0], dtype="<u8"), np.array([4], dtype="<u4"),
            dataset_id=1, channel_name="mz", key=KEY,
        )
        other_key = os.urandom(32)
        with pytest.raises(Exception):
            decrypt_channel_from_segments(
                segments, dataset_id=1, channel_name="mz", key=other_key,
            )

    def test_replay_between_au_rejected(self):
        """A segment from au_sequence=0 cannot be decrypted as if it
        were au_sequence=1. Verifies the AAD binds ciphertext to
        position."""
        plain = np.arange(8, dtype="<f8")
        segments = encrypt_channel_to_segments(
            plain,
            np.array([0, 4], dtype="<u8"),
            np.array([4, 4], dtype="<u4"),
            dataset_id=1, channel_name="mz", key=KEY,
        )
        # Swap rows 0 and 1; decrypt MUST fail.
        swapped = [segments[1], segments[0]]
        with pytest.raises(Exception):
            decrypt_channel_from_segments(
                swapped, dataset_id=1, channel_name="mz", key=KEY,
            )


# ---------------------------------------------------------- header segments


class TestHeaderSegments:

    def test_pack_unpack_36_bytes(self):
        plain = pack_au_header_plaintext(
            acquisition_mode=1, ms_level=2, polarity=1,
            retention_time=123.456, precursor_mz=500.25,
            precursor_charge=2, ion_mobility=0.987,
            base_peak_intensity=1.0e6,
        )
        # 1+1+1+8+8+1+8+8 = 36 bytes. Matches format-spec §9.1 and
        # transport-spec §4.3.3.
        assert len(plain) == 36
        fields = unpack_au_header_plaintext(plain)
        assert fields["acquisition_mode"] == 1
        assert fields["ms_level"] == 2
        assert fields["polarity"] == 1
        assert fields["retention_time"] == 123.456
        assert fields["precursor_mz"] == 500.25
        assert fields["precursor_charge"] == 2
        assert fields["ion_mobility"] == 0.987
        assert fields["base_peak_intensity"] == 1.0e6

    def test_encrypt_decrypt_header_segments(self):
        rows = [
            {"acquisition_mode": 0, "ms_level": 1, "polarity": 1,
             "retention_time": 1.0, "precursor_mz": 0.0,
             "precursor_charge": 0, "ion_mobility": 0.0,
             "base_peak_intensity": 100.0},
            {"acquisition_mode": 0, "ms_level": 2, "polarity": 1,
             "retention_time": 2.0, "precursor_mz": 500.25,
             "precursor_charge": 2, "ion_mobility": 0.0,
             "base_peak_intensity": 200.0},
        ]
        segs = encrypt_header_segments(rows, dataset_id=1, key=KEY)
        assert len(segs) == 2
        assert all(len(s.iv) == 12 and len(s.tag) == 16
                    and len(s.ciphertext) == 36 for s in segs)

        decoded = decrypt_header_segments(segs, dataset_id=1, key=KEY)
        assert decoded == rows

    def test_header_segments_are_position_bound(self):
        rows = [
            {"acquisition_mode": 0, "ms_level": 1, "polarity": 1,
             "retention_time": 1.0, "precursor_mz": 0.0,
             "precursor_charge": 0, "ion_mobility": 0.0,
             "base_peak_intensity": 100.0},
            {"acquisition_mode": 0, "ms_level": 2, "polarity": 1,
             "retention_time": 2.0, "precursor_mz": 500.25,
             "precursor_charge": 2, "ion_mobility": 0.0,
             "base_peak_intensity": 200.0},
        ]
        segs = encrypt_header_segments(rows, dataset_id=1, key=KEY)
        swapped = [segs[1], segs[0]]
        with pytest.raises(Exception):
            decrypt_header_segments(swapped, dataset_id=1, key=KEY)
