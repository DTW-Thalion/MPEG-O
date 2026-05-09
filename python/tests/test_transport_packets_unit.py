"""Targeted error-branch / edge-case tests for ``ttio.transport.packets``.

Companion to ``tests/test_transport_packets.py`` — that file covers
the happy-path round-trips. This file focuses on the malformed-input
and rare-path branches the default suite doesn't reach (error
branches in :class:`AccessUnit.from_bytes`, ``pack_string`` /
``unpack_string`` width validation, and the
``pack_blob_*`` / ``unpack_blob_*`` payload helpers).
"""
from __future__ import annotations

import struct

import pytest

from ttio.transport.packets import (
    CODEC_ID_MATE_INLINE_V2,
    CODEC_ID_NAME_TOKENIZED_V2,
    CODEC_ID_REF_DIFF_V2,
    AccessUnit,
    ChannelData,
    pack_blob_mate_info,
    pack_blob_name_tok,
    pack_blob_ref_diff,
    pack_string,
    unpack_blob_mate_info,
    unpack_blob_name_tok,
    unpack_blob_ref_diff,
    unpack_string,
)


# ---------------------------------------------------------- AccessUnit errors


class TestAccessUnitMalformedInput:

    def test_payload_below_prefix_size_rejected(self):
        # The AU prefix is 38 bytes; anything shorter cannot decode.
        with pytest.raises(ValueError, match="too short"):
            AccessUnit.from_bytes(b"\x00" * 37)

    def test_pixel_au_missing_pixel_coordinates(self):
        # spectrum_class=4 (MSImagePixel) requires a 12-byte pixel
        # tuple after the channels; a 38-byte payload (prefix only,
        # 0 channels, 0 pixel bytes) must raise.
        prefix = struct.pack(
            "<BBBBddBddB",
            4,    # spectrum_class = MSImagePixel
            0, 1, 0,
            0.0, 0.0,
            0,
            0.0, 0.0,
            0,    # n_channels = 0
        )
        assert len(prefix) == 38
        with pytest.raises(ValueError, match="pixel coordinates"):
            AccessUnit.from_bytes(prefix)

    def test_genomic_au_missing_chromosome_prefix(self):
        # spectrum_class=5 with no bytes after the prefix — the
        # chromosome length prefix can't be unpacked.
        prefix = struct.pack(
            "<BBBBddBddB",
            5,    # spectrum_class = GenomicRead
            0, 0, 2,
            0.0, 0.0,
            0,
            0.0, 0.0,
            0,    # n_channels = 0
        )
        with pytest.raises(ValueError, match="chromosome length prefix"):
            AccessUnit.from_bytes(prefix)


# ---------------------------------------------------------- pack/unpack_string


class TestStringPrefixWidth:

    def test_pack_string_unsupported_width_rejected(self):
        with pytest.raises(ValueError, match="unsupported prefix width"):
            pack_string("x", width=3)

    def test_pack_string_width_8_rejected(self):
        with pytest.raises(ValueError, match="unsupported prefix width"):
            pack_string("y", width=8)

    def test_unpack_string_unsupported_width_rejected(self):
        # Construct a buffer that *would* decode with width=2; just
        # check unpack rejects unknown widths.
        buf = pack_string("hi", width=2)
        with pytest.raises(ValueError, match="unsupported prefix width"):
            unpack_string(buf, 0, width=3)

    def test_pack_string_width4_round_trip_empty(self):
        buf = pack_string("", width=4)
        # 4-byte length prefix + 0 string bytes
        assert len(buf) == 4
        value, offset = unpack_string(buf, 0, width=4)
        assert value == ""
        assert offset == 4


# ---------------------------------------------------------- BlobV2 mate_info


class TestBlobMateInfo:

    def test_round_trip_with_chrom_table(self):
        chrom_names = ["chr1", "chrX", "chrM"]
        blob = b"\x00\x01\x02\x03\x04"
        payload = pack_blob_mate_info(
            dataset_id=42, chrom_names=chrom_names, blob=blob,
        )
        ds, names, decoded = unpack_blob_mate_info(payload)
        assert ds == 42
        assert names == chrom_names
        assert decoded == blob

    def test_round_trip_empty_chrom_table(self):
        # Empty chrom_names is permitted (matches the "len(mate_chromosomes)
        # == 0 at write time" path).
        payload = pack_blob_mate_info(
            dataset_id=7, chrom_names=[], blob=b"abc",
        )
        ds, names, decoded = unpack_blob_mate_info(payload)
        assert ds == 7
        assert names == []
        assert decoded == b"abc"

    def test_round_trip_empty_blob(self):
        payload = pack_blob_mate_info(
            dataset_id=1, chrom_names=["chr1"], blob=b"",
        )
        ds, names, blob = unpack_blob_mate_info(payload)
        assert (ds, names, blob) == (1, ["chr1"], b"")

    def test_unpack_too_short_rejected(self):
        with pytest.raises(ValueError, match="too short"):
            unpack_blob_mate_info(b"\x00\x00")

    def test_unpack_wrong_codec_id_rejected(self):
        # Build a header with codec_id = REF_DIFF instead of MATE_INLINE.
        bad = struct.pack("<HBH", 1, CODEC_ID_REF_DIFF_V2, 0)
        bad += struct.pack("<I", 0)
        with pytest.raises(ValueError, match=f"codec_id {CODEC_ID_REF_DIFF_V2}"):
            unpack_blob_mate_info(bad)

    def test_unpack_missing_blob_length_rejected(self):
        # 5-byte header (dataset_id, codec_id, n_names=0) but no
        # blob_length uint32 → trips the "missing blob_length" branch.
        truncated = struct.pack("<HBH", 1, CODEC_ID_MATE_INLINE_V2, 0)
        # add 1 byte of garbage so we're past the "too short" check
        # but still under the 4-byte uint32 needed for blob_length.
        truncated += b"\x00"
        with pytest.raises(ValueError, match="missing blob_length"):
            unpack_blob_mate_info(truncated)

    def test_unpack_trailing_bytes_mismatch_rejected(self):
        # Encode blob_length=10 but only ship 3 trailing bytes.
        bad = struct.pack("<HBH", 1, CODEC_ID_MATE_INLINE_V2, 0)
        bad += struct.pack("<I", 10)
        bad += b"abc"
        with pytest.raises(ValueError, match="trailing bytes mismatch"):
            unpack_blob_mate_info(bad)


# ---------------------------------------------------------- BlobV2 ref_diff


class TestBlobRefDiff:

    def test_round_trip(self):
        payload = pack_blob_ref_diff(
            dataset_id=3, reference_uri="GRCh38.p14", blob=b"\xde\xad\xbe\xef",
        )
        ds, uri, blob = unpack_blob_ref_diff(payload)
        assert ds == 3
        assert uri == "GRCh38.p14"
        assert blob == b"\xde\xad\xbe\xef"

    def test_round_trip_empty_uri_and_blob(self):
        payload = pack_blob_ref_diff(
            dataset_id=0, reference_uri="", blob=b"",
        )
        ds, uri, blob = unpack_blob_ref_diff(payload)
        assert (ds, uri, blob) == (0, "", b"")

    def test_unpack_too_short_rejected(self):
        with pytest.raises(ValueError, match="too short"):
            unpack_blob_ref_diff(b"\x00\x00")

    def test_unpack_wrong_codec_id_rejected(self):
        bad = struct.pack("<HB", 1, CODEC_ID_MATE_INLINE_V2)  # wrong id
        bad += pack_string("u", width=2)
        bad += struct.pack("<I", 0)
        with pytest.raises(ValueError, match=f"codec_id {CODEC_ID_MATE_INLINE_V2}"):
            unpack_blob_ref_diff(bad)

    def test_unpack_missing_blob_length_rejected(self):
        # Header (3 bytes) + URI + 0 trailing bytes for blob_length
        # uint32 → trips "missing blob_length".
        truncated = struct.pack("<HB", 1, CODEC_ID_REF_DIFF_V2)
        truncated += pack_string("ref", width=2)
        # no blob_length
        with pytest.raises(ValueError, match="missing blob_length"):
            unpack_blob_ref_diff(truncated)

    def test_unpack_trailing_bytes_mismatch_rejected(self):
        bad = struct.pack("<HB", 1, CODEC_ID_REF_DIFF_V2)
        bad += pack_string("ref", width=2)
        bad += struct.pack("<I", 50)  # claim 50 bytes...
        bad += b"only-a-few"           # ...but only ship 10
        with pytest.raises(ValueError, match="trailing bytes mismatch"):
            unpack_blob_ref_diff(bad)


# ---------------------------------------------------------- BlobV2 name_tok


class TestBlobNameTok:

    def test_round_trip(self):
        payload = pack_blob_name_tok(dataset_id=99, blob=b"hello-tokens")
        ds, blob = unpack_blob_name_tok(payload)
        assert ds == 99
        assert blob == b"hello-tokens"

    def test_round_trip_empty_blob_too_short(self):
        # The name_tok payload is HB + I + blob; with an empty blob
        # the payload is 7 bytes — exactly the lower-bound check.
        payload = pack_blob_name_tok(dataset_id=1, blob=b"")
        assert len(payload) == 7
        ds, blob = unpack_blob_name_tok(payload)
        assert (ds, blob) == (1, b"")

    def test_unpack_too_short_rejected(self):
        # Anything < 7 bytes can't carry header + blob_length.
        with pytest.raises(ValueError, match="too short"):
            unpack_blob_name_tok(b"\x00" * 6)

    def test_unpack_wrong_codec_id_rejected(self):
        bad = struct.pack("<HB", 1, CODEC_ID_REF_DIFF_V2)  # wrong
        bad += struct.pack("<I", 0)
        with pytest.raises(ValueError, match=f"codec_id {CODEC_ID_REF_DIFF_V2}"):
            unpack_blob_name_tok(bad)

    def test_unpack_trailing_bytes_mismatch_rejected(self):
        # Claim blob_length=20 but ship only a few bytes after it.
        bad = struct.pack("<HB", 1, CODEC_ID_NAME_TOKENIZED_V2)
        bad += struct.pack("<I", 20)
        bad += b"short"
        with pytest.raises(ValueError, match="trailing bytes mismatch"):
            unpack_blob_name_tok(bad)


# ---------------------------------------------------------- ChannelData edge


class TestChannelDataAdditional:

    def test_zero_byte_data_with_nonzero_n_elements(self):
        # n_elements is independent of data length — the spec
        # allows zero-byte payloads even when n_elements > 0
        # (e.g. an empty packed-bases representation). Round-trip
        # must preserve both fields.
        ch = ChannelData(name="x", precision=1, compression=0,
                         n_elements=12, data=b"")
        decoded, offset = ChannelData.from_buffer(ch.to_bytes(), 0)
        assert decoded.n_elements == 12
        assert decoded.data == b""
        assert offset == len(ch.to_bytes())
