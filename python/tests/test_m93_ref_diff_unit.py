"""Unit tests for the M93 REF_DIFF codec."""
from __future__ import annotations

import pytest

from ttio.enums import Compression

# Imports below are tested for existence in later tasks; gating with
# `pytest.importorskip` so Task 1 can pass without ref_diff.py existing yet.


def test_ref_diff_enum_value_is_9():
    assert int(Compression.REF_DIFF) == 9
    assert Compression.REF_DIFF.name == "REF_DIFF"


def test_ref_diff_is_registered_as_context_aware():
    from ttio.codecs._codec_meta import is_context_aware
    assert is_context_aware(Compression.REF_DIFF) is True
    # All previously-shipped codecs are NOT context-aware.
    for codec in (
        Compression.RANS_ORDER0,
        Compression.RANS_ORDER1,
        Compression.BASE_PACK,
        Compression.QUALITY_BINNED,
        Compression.NAME_TOKENIZED,
    ):
        assert is_context_aware(codec) is False, (
            f"{codec.name} should not be context-aware"
        )


# ─── Task 2: wire-format header + slice index ──────────────────────────


def test_codec_header_round_trip():
    from ttio.codecs.ref_diff import (
        CodecHeader,
        pack_codec_header,
        unpack_codec_header,
    )

    h = CodecHeader(
        num_slices=3,
        total_reads=12345,
        reference_md5=bytes.fromhex("a718acaa6135fdca8357d5bfe94211dd"),
        reference_uri="GRCh37.hs37d5",
    )
    blob = pack_codec_header(h)
    # Header size = 4 magic + 1 ver + 3 reserved + 4 num_slices + 8 total_reads
    #   + 16 md5 + 2 uri_len + N uri = 38 + N
    assert len(blob) == 38 + len(h.reference_uri.encode("utf-8"))
    assert blob[:4] == b"RDIF"
    assert blob[4] == 1  # version
    h2, consumed = unpack_codec_header(blob)
    assert consumed == len(blob)
    assert h2 == h


def test_codec_header_with_empty_uri():
    from ttio.codecs.ref_diff import (
        CodecHeader,
        pack_codec_header,
        unpack_codec_header,
    )

    h = CodecHeader(num_slices=0, total_reads=0, reference_md5=b"\x00" * 16, reference_uri="")
    blob = pack_codec_header(h)
    assert len(blob) == 38
    h2, consumed = unpack_codec_header(blob)
    assert consumed == 38
    assert h2 == h


def test_slice_index_entry_is_32_bytes():
    from ttio.codecs.ref_diff import (
        SliceIndexEntry,
        pack_slice_index_entry,
        unpack_slice_index_entry,
    )

    e = SliceIndexEntry(
        body_offset=1000,
        body_length=500,
        first_position=16050000,
        last_position=16060000,
        num_reads=10000,
    )
    blob = pack_slice_index_entry(e)
    assert len(blob) == 32
    e2 = unpack_slice_index_entry(blob)
    assert e2 == e


def test_codec_header_rejects_bad_magic():
    from ttio.codecs.ref_diff import (
        CodecHeader,
        pack_codec_header,
        unpack_codec_header,
    )

    blob = bytearray(
        pack_codec_header(CodecHeader(0, 0, b"\x00" * 16, ""))
    )
    blob[0] = ord("X")
    with pytest.raises(ValueError, match="bad magic"):
        unpack_codec_header(bytes(blob))


def test_codec_header_rejects_unsupported_version():
    from ttio.codecs.ref_diff import (
        CodecHeader,
        pack_codec_header,
        unpack_codec_header,
    )

    blob = bytearray(
        pack_codec_header(CodecHeader(0, 0, b"\x00" * 16, ""))
    )
    blob[4] = 99
    with pytest.raises(ValueError, match="unsupported.*version"):
        unpack_codec_header(bytes(blob))


def test_codec_header_rejects_bad_md5_length():
    from ttio.codecs.ref_diff import CodecHeader

    with pytest.raises(ValueError, match="reference_md5 must be 16 bytes"):
        CodecHeader(num_slices=0, total_reads=0, reference_md5=b"too-short", reference_uri="")


# ─── Task 3: CIGAR walker ──────────────────────────────────────────────


def test_walk_all_match_no_subs():
    from ttio.codecs.ref_diff import walk_read_against_reference

    ref = b"AAAAAAAAAA"
    seq = b"AAAAA"
    r = walk_read_against_reference(seq, "5M", 1, ref)
    assert r.m_op_flag_bits == [0, 0, 0, 0, 0]
    assert r.substitution_bases == b""
    assert r.insertion_bases == b""
    assert r.softclip_bases == b""


def test_walk_with_substitution():
    from ttio.codecs.ref_diff import walk_read_against_reference

    ref = b"ACGTACGTAC"
    seq = b"ACCTACGTAC"  # G→C at index 2
    r = walk_read_against_reference(seq, "10M", 1, ref)
    assert r.m_op_flag_bits == [0, 0, 1, 0, 0, 0, 0, 0, 0, 0]
    assert r.substitution_bases == b"C"


def test_walk_with_insertion_and_softclip():
    from ttio.codecs.ref_diff import walk_read_against_reference

    # 2S2M2I2M: 2 soft-clips, 2 matches, 2 insertions, 2 matches
    ref = b"ACGT"
    seq = b"NNACTTGT"
    r = walk_read_against_reference(seq, "2S2M2I2M", 1, ref)
    # M-op walks: ref[0..1]=AC vs seq[2..3]=AC → [0,0]
    #             ref[2..3]=GT vs seq[6..7]=GT → [0,0]
    assert r.m_op_flag_bits == [0, 0, 0, 0]
    assert r.softclip_bases == b"NN"
    assert r.insertion_bases == b"TT"
    assert r.substitution_bases == b""


def test_walk_with_deletion():
    from ttio.codecs.ref_diff import walk_read_against_reference

    # 3M2D3M — read has 6 bases, ref-traversal is 8
    ref = b"ACGTACGTAC"
    seq = b"ACGCGT"
    r = walk_read_against_reference(seq, "3M2D3M", 1, ref)
    # M-op walks: ref[0..2]=ACG vs seq[0..2]=ACG → [0,0,0]
    #             ref[5..7]=CGT vs seq[3..5]=CGT → [0,0,0]
    assert r.m_op_flag_bits == [0, 0, 0, 0, 0, 0]
    assert r.substitution_bases == b""
    assert r.insertion_bases == b""


def test_walk_with_hard_and_pad_clip():
    from ttio.codecs.ref_diff import walk_read_against_reference

    # 2H3M — hard-clip carries no payload (bases not in seq)
    ref = b"ACGTACGT"
    seq = b"ACG"
    r = walk_read_against_reference(seq, "2H3M", 1, ref)
    assert r.m_op_flag_bits == [0, 0, 0]
    assert r.softclip_bases == b""
    assert r.insertion_bases == b""


def test_walk_rejects_unmapped_cigar_star():
    from ttio.codecs.ref_diff import walk_read_against_reference

    with pytest.raises(ValueError, match="unmapped"):
        walk_read_against_reference(b"NNNN", "*", 0, b"AAAA")


def test_walk_rejects_empty_cigar():
    from ttio.codecs.ref_diff import walk_read_against_reference

    with pytest.raises(ValueError, match="unmapped"):
        walk_read_against_reference(b"NNNN", "", 0, b"AAAA")


# ─── Task 4: reverse walker ────────────────────────────────────────────


@pytest.mark.parametrize(
    "ref,seq,cigar,pos",
    [
        (b"AAAAAAAAAA", b"AAAAA", "5M", 1),
        (b"ACGTACGTAC", b"ACCTACGTAC", "10M", 1),
        (b"ACGT", b"NNACTTGT", "2S2M2I2M", 1),
        (b"ACGTACGTAC", b"ACGCGT", "3M2D3M", 1),
        (b"ACGTACGT", b"ACG", "2H3M", 1),
    ],
)
def test_walk_then_reconstruct_round_trip(ref, seq, cigar, pos):
    from ttio.codecs.ref_diff import (
        walk_read_against_reference,
        reconstruct_read_from_walk,
    )

    walk = walk_read_against_reference(seq, cigar, pos, ref)
    rebuilt = reconstruct_read_from_walk(walk, cigar, pos, ref)
    assert rebuilt == seq


# ─── Task 5: bit-pack/unpack ──────────────────────────────────────────


def test_pack_simple_all_match():
    from ttio.codecs.ref_diff import (
        ReadWalkResult,
        pack_read_diff_bitstream,
    )

    walk = ReadWalkResult(
        m_op_flag_bits=[0, 0, 0, 0, 0],
        substitution_bases=b"",
        insertion_bases=b"",
        softclip_bases=b"",
    )
    blob = pack_read_diff_bitstream(walk)
    # 5 zero bits + 3 padding zero bits = 1 byte 0x00
    assert blob == b"\x00"


def test_pack_one_substitution():
    from ttio.codecs.ref_diff import (
        ReadWalkResult,
        pack_read_diff_bitstream,
    )

    walk = ReadWalkResult(
        m_op_flag_bits=[0, 0, 1, 0, 0],
        substitution_bases=b"C",
        insertion_bases=b"",
        softclip_bases=b"",
    )
    blob = pack_read_diff_bitstream(walk)
    # Bits MSB-first:
    #   0 0 [flag=1] [C=0x43=01000011] 0 0 [pad=000]
    #   = 0 0 1 [0 1 0 0 0 0 1 1] 0 0 0 0 0
    # Packed:
    #   byte 0 = 0010_1000 = 0x28
    #   byte 1 = 0110_0000 = 0x60
    assert blob == bytes([0x28, 0x60])


def test_pack_unpack_round_trip_with_ins_softclip():
    from ttio.codecs.ref_diff import (
        ReadWalkResult,
        pack_read_diff_bitstream,
        unpack_read_diff_bitstream,
    )

    walk = ReadWalkResult(
        m_op_flag_bits=[0, 1, 0],
        substitution_bases=b"T",
        insertion_bases=b"AA",
        softclip_bases=b"NN",
    )
    blob = pack_read_diff_bitstream(walk)
    walk2 = unpack_read_diff_bitstream(
        blob, num_m_ops=3, ins_length=2, softclip_length=2
    )
    assert walk2 == walk


# ─── Task 6: slice encode/decode ──────────────────────────────────────


def test_slice_round_trip_5_reads():
    from ttio.codecs.ref_diff import encode_slice, decode_slice

    ref = b"ACGTACGTAC" * 100
    sequences = [
        b"ACGTACGTAC",      # all matches
        b"AAGTACGTAC",      # one substitution at index 1
        b"ACGTAACGTAC",     # 5M1I5M (1bp insertion 'A' at index 5)
        b"GTACGTACGT",      # offset position
        b"NNACGTACGT",      # 2S8M soft-clip start
    ]
    cigars = ["10M", "10M", "5M1I5M", "10M", "2S8M"]
    positions = [1, 1, 1, 3, 1]

    encoded = encode_slice(sequences, cigars, positions, ref)
    out = decode_slice(encoded, cigars, positions, ref, num_reads=5)
    assert out == sequences


# ─── Task 7: top-level encode/decode ──────────────────────────────────


def test_top_level_round_trip_three_slices():
    import hashlib

    from ttio.codecs.ref_diff import encode, decode, unpack_codec_header

    n_reads = 25_000
    ref = b"ACGT" * 50_000
    sequences = [b"ACGTACGTAC"] * n_reads
    cigars = ["10M"] * n_reads
    positions = [1 + (i % 100) for i in range(n_reads)]
    md5 = hashlib.md5(ref).digest()
    uri = "synthetic-test-ref"

    encoded = encode(sequences, cigars, positions, ref, md5, uri)
    decoded = decode(encoded, cigars, positions, ref)
    assert decoded == sequences

    header, _ = unpack_codec_header(encoded)
    assert header.num_slices == 3  # 25K / 10K = 2.5 → 3 slices
    assert header.total_reads == n_reads
    assert header.reference_md5 == md5
    assert header.reference_uri == uri
