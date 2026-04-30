"""TTI-O M93 — REF_DIFF reference-based sequence-diff codec.

Wire format and algorithm documented in
``docs/superpowers/specs/2026-04-28-m93-m94-m95-codec-design.md`` §3 (M93)
and ``docs/codecs/ref_diff.md``. Codec id is :class:`Compression.REF_DIFF`
= 9.

REF_DIFF is **context-aware**: encode/decode receives ``positions``,
``cigars``, and a reference sequence alongside the ``sequences`` byte
stream. The pipeline plumbing is the responsibility of the M86 layer
in :mod:`ttio.spectral_dataset`; this module exposes pure functions.

This is the Python reference implementation. ObjC
(``TTIORefDiff.{h,m}``) and Java (``codecs.RefDiff``) decode the bytes
this module produces byte-for-byte; the four canonical conformance
fixtures under ``python/tests/fixtures/codecs/ref_diff_{a,b,c,d}.bin``
are the contract.

Cross-language: ObjC ``TTIORefDiff`` · Java ``codecs.RefDiff``.
"""
from __future__ import annotations

import re
import struct
from dataclasses import dataclass


# Matches one CIGAR operation: digits followed by op letter.
_CIGAR_OP_RE = re.compile(r"(\d+)([MIDNSHPX=])")


# ─── Optional Cython acceleration ──────────────────────────────────────
#
# When the compiled extension at ``ttio.codecs._ref_diff._ref_diff`` is
# available, the four hot functions (named in the chr22 profile)
# transparently route through it. Output is byte-identical either way —
# the Python implementations below remain the spec contract.

try:  # pragma: no cover — extension may be absent in source-only installs
    from ttio.codecs._ref_diff import _ref_diff as _ext  # type: ignore[import-not-found]
    _HAVE_C_EXTENSION = True
except ImportError:  # pragma: no cover
    _HAVE_C_EXTENSION = False
    _ext = None  # type: ignore[assignment]


MAGIC = b"RDIF"
VERSION = 1

# Header fixed prefix (everything before the variable-length URI):
#   magic(4) + version(1) + reserved(3) + num_slices(4) + total_reads(8)
#   + reference_md5(16) + reference_uri_len(2) = 38 bytes
HEADER_FIXED_SIZE = 38

# Slice index entry: body_offset(8) + body_length(4) + first_position(8)
#   + last_position(8) + num_reads(4) = 32 bytes
SLICE_INDEX_ENTRY_SIZE = 32


@dataclass(frozen=True)
class CodecHeader:
    """REF_DIFF wire-format header (38 + len(reference_uri) bytes)."""

    num_slices: int
    total_reads: int
    reference_md5: bytes  # exactly 16 bytes
    reference_uri: str    # UTF-8

    def __post_init__(self):
        if len(self.reference_md5) != 16:
            raise ValueError(
                f"reference_md5 must be 16 bytes, got {len(self.reference_md5)}"
            )
        uri_bytes = self.reference_uri.encode("utf-8")
        if len(uri_bytes) > 0xFFFF:
            raise ValueError(
                f"reference_uri too long ({len(uri_bytes)} bytes UTF-8 > 65535)"
            )


@dataclass(frozen=True)
class SliceIndexEntry:
    """Per-slice index entry (32 bytes)."""

    body_offset: int        # uint64 — offset relative to the slice-bodies block
    body_length: int        # uint32 — length of this slice's encoded body
    first_position: int     # int64  — first read's 1-based reference position
    last_position: int      # int64  — last read's 1-based reference position
    num_reads: int          # uint32 — read count in this slice


def pack_codec_header(h: CodecHeader) -> bytes:
    """Serialize ``h`` to the on-wire byte sequence (38 + N bytes)."""
    uri_bytes = h.reference_uri.encode("utf-8")
    # Layout: 4 magic | 1 ver | 3 reserved | 4 num_slices | 8 total_reads
    #       | 16 md5 | 2 uri_len | N uri  (everything LE except the byte fields).
    return (
        MAGIC
        + struct.pack("<B3xIQ", VERSION, h.num_slices, h.total_reads)
        + h.reference_md5
        + struct.pack("<H", len(uri_bytes))
        + uri_bytes
    )


def unpack_codec_header(blob: bytes) -> tuple[CodecHeader, int]:
    """Inverse of :func:`pack_codec_header`. Returns (header, bytes_consumed)."""
    if len(blob) < HEADER_FIXED_SIZE:
        raise ValueError(f"header too short: {len(blob)} bytes")
    if blob[:4] != MAGIC:
        raise ValueError(f"bad magic: {blob[:4]!r}, expected {MAGIC!r}")
    version = blob[4]
    if version != VERSION:
        raise ValueError(f"unsupported REF_DIFF version: {version}")
    num_slices, total_reads = struct.unpack_from("<IQ", blob, 8)
    md5 = blob[20:36]
    (uri_len,) = struct.unpack_from("<H", blob, 36)
    end = HEADER_FIXED_SIZE + uri_len
    if len(blob) < end:
        raise ValueError("header truncated in reference_uri")
    uri = blob[HEADER_FIXED_SIZE:end].decode("utf-8")
    return CodecHeader(num_slices, total_reads, md5, uri), end


def pack_slice_index_entry(e: SliceIndexEntry) -> bytes:
    """Serialize a slice-index entry (32 bytes)."""
    return struct.pack(
        "<QIqqI",
        e.body_offset,
        e.body_length,
        e.first_position,
        e.last_position,
        e.num_reads,
    )


def unpack_slice_index_entry(blob: bytes) -> SliceIndexEntry:
    """Inverse of :func:`pack_slice_index_entry`."""
    if len(blob) != SLICE_INDEX_ENTRY_SIZE:
        raise ValueError(
            f"slice index entry must be {SLICE_INDEX_ENTRY_SIZE} bytes, "
            f"got {len(blob)}"
        )
    return SliceIndexEntry(*struct.unpack("<QIqqI", blob))


# ─── CIGAR walker ──────────────────────────────────────────────────────


@dataclass(frozen=True)
class ReadWalkResult:
    """Output of walking one read's CIGAR against the reference.

    Attributes:
        m_op_flag_bits: list of 0/1, one per ``M``/``=``/``X``-op base.
            ``0`` = read base matches the reference at this position;
            ``1`` = substitution (the actual base is in
            :attr:`substitution_bases` at the corresponding index).
        substitution_bases: concatenated substitution bytes, one per
            ``m_op_flag_bits == 1`` entry, in CIGAR-walk order.
        insertion_bases: concatenated ``I``-op bases, in CIGAR-walk
            order.
        softclip_bases: concatenated ``S``-op bases, in CIGAR-walk
            order.

    ``D`` / ``N`` / ``H`` / ``P`` ops carry no payload — their lengths
    come from the cigar channel at decode time.
    """

    m_op_flag_bits: list[int]
    substitution_bases: bytes
    insertion_bases: bytes
    softclip_bases: bytes


def walk_read_against_reference(
    sequence: bytes,
    cigar: str,
    position: int,
    reference_chrom_seq: bytes,
) -> ReadWalkResult:
    """Walk one read's CIGAR against the reference and emit a diff record.

    See spec §3 M93 algorithm.

    Args:
        sequence: read's full sequence (uppercase ACGT… bytes).
        cigar: CIGAR string ("100M", "2S98M", "3M2D5M", etc.). ``"*"``
            (unmapped) and ``""`` are rejected — REF_DIFF cannot encode
            unmapped reads; route through BASE_PACK on a separate
            sub-channel.
        position: 1-based reference position where the M-walk starts.
        reference_chrom_seq: full chromosome sequence (uppercase ACGTN…).

    Returns:
        :class:`ReadWalkResult`.

    Raises:
        ValueError: on unmapped CIGAR or unsupported op.
    """
    if _HAVE_C_EXTENSION:
        flag_list, sub, ins, soft = _ext.walk_read_against_reference_c(
            sequence, cigar, position, reference_chrom_seq,
        )
        return ReadWalkResult(
            m_op_flag_bits=flag_list,
            substitution_bases=sub,
            insertion_bases=ins,
            softclip_bases=soft,
        )
    return _walk_read_against_reference_py(
        sequence, cigar, position, reference_chrom_seq,
    )


def _walk_read_against_reference_py(
    sequence: bytes,
    cigar: str,
    position: int,
    reference_chrom_seq: bytes,
) -> ReadWalkResult:
    """Pure-Python reference implementation of :func:`walk_read_against_reference`.

    Kept as the byte-exact spec contract; called as a fallback when the
    C extension is absent.
    """
    if cigar == "*" or cigar == "":
        raise ValueError(
            "REF_DIFF cannot encode unmapped reads (cigar='*' or empty); "
            "route through BASE_PACK on a separate sub-channel"
        )

    m_op_flag_bits: list[int] = []
    sub_buf = bytearray()
    ins_buf = bytearray()
    soft_buf = bytearray()

    seq_i = 0
    ref_i = position - 1  # convert 1-based to 0-based

    for length_str, op in _CIGAR_OP_RE.findall(cigar):
        length = int(length_str)
        if op in ("M", "=", "X"):
            for k in range(length):
                read_base = sequence[seq_i + k]
                ref_base = reference_chrom_seq[ref_i + k]
                if read_base == ref_base:
                    m_op_flag_bits.append(0)
                else:
                    m_op_flag_bits.append(1)
                    sub_buf.append(read_base)
            seq_i += length
            ref_i += length
        elif op == "I":
            ins_buf.extend(sequence[seq_i:seq_i + length])
            seq_i += length
            # ref_i unchanged
        elif op == "S":
            soft_buf.extend(sequence[seq_i:seq_i + length])
            seq_i += length
            # ref_i unchanged
        elif op in ("D", "N"):
            ref_i += length
            # seq_i unchanged
        elif op in ("H", "P"):
            pass  # neither advances; no payload
        else:
            raise ValueError(f"unsupported CIGAR op: {op!r}")

    return ReadWalkResult(
        m_op_flag_bits=m_op_flag_bits,
        substitution_bases=bytes(sub_buf),
        insertion_bases=bytes(ins_buf),
        softclip_bases=bytes(soft_buf),
    )


def reconstruct_read_from_walk(
    walk: ReadWalkResult,
    cigar: str,
    position: int,
    reference_chrom_seq: bytes,
) -> bytes:
    """Reconstruct a read sequence from its diff record + CIGAR + reference.

    Inverse of :func:`walk_read_against_reference`. The decode hot path
    in :func:`decode_slice` bypasses this function entirely (it routes
    directly through ``_ext.unpack_and_reconstruct_c``); this Python-
    level entry point is preserved for the public API and unit tests.
    """
    if cigar == "*" or cigar == "":
        raise ValueError("cannot reconstruct unmapped read")

    out = bytearray()
    flag_i = 0
    sub_i = 0
    ins_i = 0
    soft_i = 0
    ref_i = position - 1

    for length_str, op in _CIGAR_OP_RE.findall(cigar):
        length = int(length_str)
        if op in ("M", "=", "X"):
            for k in range(length):
                if walk.m_op_flag_bits[flag_i] == 0:
                    out.append(reference_chrom_seq[ref_i + k])
                else:
                    out.append(walk.substitution_bases[sub_i])
                    sub_i += 1
                flag_i += 1
            ref_i += length
        elif op == "I":
            out.extend(walk.insertion_bases[ins_i:ins_i + length])
            ins_i += length
        elif op == "S":
            out.extend(walk.softclip_bases[soft_i:soft_i + length])
            soft_i += length
        elif op in ("D", "N"):
            ref_i += length
        elif op in ("H", "P"):
            pass
        else:
            raise ValueError(f"unsupported CIGAR op: {op!r}")

    # Sanity asserts catch off-by-ones during development.
    assert flag_i == len(walk.m_op_flag_bits), (
        f"M-op flag count mismatch: consumed {flag_i}, walk has {len(walk.m_op_flag_bits)}"
    )
    assert sub_i == len(walk.substitution_bases)
    assert ins_i == len(walk.insertion_bases)
    assert soft_i == len(walk.softclip_bases)
    return bytes(out)


# ─── Bit-packed read-diff bitstream ───────────────────────────────────


def pack_read_diff_bitstream(walk: ReadWalkResult) -> bytes:
    """Pack one read's diff record into the wire bitstream.

    Layout per spec §3 M93:
      1. Bit-packed sequence: for each M-op flag bit, append the bit
         (MSB-first within each byte). After a ``1`` flag, append the
         corresponding substitution byte's 8 bits MSB-first.
      2. Pad bits to byte boundary with zeros.
      3. Then I-op bases verbatim (whole bytes).
      4. Then S-op bases verbatim.
    """
    if _HAVE_C_EXTENSION:
        return _ext.pack_read_diff_bitstream_c(
            walk.m_op_flag_bits,
            walk.substitution_bases,
            walk.insertion_bases,
            walk.softclip_bases,
        )
    return _pack_read_diff_bitstream_py(walk)


def _pack_read_diff_bitstream_py(walk: ReadWalkResult) -> bytes:
    """Pure-Python reference implementation of :func:`pack_read_diff_bitstream`."""
    bits: list[int] = []
    sub_iter = iter(walk.substitution_bases)
    for flag in walk.m_op_flag_bits:
        bits.append(flag)
        if flag == 1:
            sub_byte = next(sub_iter)
            for shift in range(7, -1, -1):
                bits.append((sub_byte >> shift) & 1)

    # Pad to byte boundary.
    while len(bits) % 8:
        bits.append(0)

    # Pack bits MSB-first into bytes.
    out = bytearray()
    for i in range(0, len(bits), 8):
        byte = 0
        for j in range(8):
            byte = (byte << 1) | bits[i + j]
        out.append(byte)

    out.extend(walk.insertion_bases)
    out.extend(walk.softclip_bases)
    return bytes(out)


def unpack_read_diff_bitstream(
    blob: bytes,
    num_m_ops: int,
    ins_length: int,
    softclip_length: int,
) -> ReadWalkResult:
    """Inverse of :func:`pack_read_diff_bitstream`.

    Caller supplies the M-op count + I/S-op lengths (recovered from the
    cigar channel at decode time).
    """
    walk, _ = _unpack_read_diff_with_consumed(
        blob, num_m_ops, ins_length, softclip_length
    )
    return walk


def _unpack_read_diff_with_consumed(
    blob: bytes,
    num_m_ops: int,
    ins_length: int,
    softclip_length: int,
) -> tuple[ReadWalkResult, int]:
    """Like :func:`unpack_read_diff_bitstream` but also returns total bytes consumed."""
    flag_bits: list[int] = []
    sub_buf = bytearray()
    bit_cursor = 0
    for _ in range(num_m_ops):
        byte_idx, bit_off = divmod(bit_cursor, 8)
        flag = (blob[byte_idx] >> (7 - bit_off)) & 1
        flag_bits.append(flag)
        bit_cursor += 1
        if flag == 1:
            sub_byte = 0
            for _ in range(8):
                bi, bo = divmod(bit_cursor, 8)
                sub_byte = (sub_byte << 1) | ((blob[bi] >> (7 - bo)) & 1)
                bit_cursor += 1
            sub_buf.append(sub_byte)
    bytes_consumed = (bit_cursor + 7) // 8
    ins = blob[bytes_consumed:bytes_consumed + ins_length]
    soft = blob[bytes_consumed + ins_length:bytes_consumed + ins_length + softclip_length]
    walk = ReadWalkResult(flag_bits, bytes(sub_buf), bytes(ins), bytes(soft))
    return walk, bytes_consumed + ins_length + softclip_length


# ─── Per-slice encoder/decoder ────────────────────────────────────────


def _cigar_op_lengths(cigar: str) -> tuple[int, int, int]:
    """Return (m_op_count, i_op_total, s_op_total) for a CIGAR string.

    Used at decode time to know how many bits + bytes to consume per read.
    """
    m_count = i_total = s_total = 0
    for length_str, op in _CIGAR_OP_RE.findall(cigar):
        n = int(length_str)
        if op in ("M", "=", "X"):
            m_count += n
        elif op == "I":
            i_total += n
        elif op == "S":
            s_total += n
    return m_count, i_total, s_total


def encode_slice(
    sequences: list[bytes],
    cigars: list[str],
    positions: list[int],
    reference_chrom_seq: bytes,
) -> bytes:
    """Encode a slice of up to 10K reads into a rANS-compressed byte blob.

    The slice body layout, per spec §3 M93:
      For each read in slice (in order):
        - bit-packed M-op flags interleaved with substitution bytes
        - I-op bases verbatim
        - S-op bases verbatim
      The concatenated raw bitstream is then rANS_ORDER0-encoded.

    Hot path: when the C extension is available, walks + packs in one
    fused C kernel per read (skipping the intermediate Python list).
    """
    from ttio.codecs.rans import encode as rans_encode

    raw = bytearray()
    if _HAVE_C_EXTENSION:
        walk_and_pack = _ext.walk_and_pack_c
        for seq, cigar, pos in zip(sequences, cigars, positions):
            raw.extend(walk_and_pack(seq, cigar, pos, reference_chrom_seq))
    else:
        for seq, cigar, pos in zip(sequences, cigars, positions):
            walk = walk_read_against_reference(seq, cigar, pos, reference_chrom_seq)
            raw.extend(pack_read_diff_bitstream(walk))
    return rans_encode(bytes(raw), order=0)


def decode_slice(
    encoded: bytes,
    cigars: list[str],
    positions: list[int],
    reference_chrom_seq: bytes,
    num_reads: int,
) -> list[bytes]:
    """Inverse of :func:`encode_slice`.

    Hot path: when the C extension is available, unpacks + reconstructs
    in one fused C kernel per read (skipping the intermediate Python
    list and the per-read ``bytes`` slice copy).
    """
    from ttio.codecs.rans import decode as rans_decode

    if num_reads != len(cigars) or num_reads != len(positions):
        raise ValueError("cigars/positions count must equal num_reads")

    raw = rans_decode(encoded)
    sequences: list[bytes] = []
    cursor = 0
    if _HAVE_C_EXTENSION:
        unpack_and_reconstruct = _ext.unpack_and_reconstruct_c
        # Bind once to avoid per-iteration attribute lookups.
        for cigar, pos in zip(cigars, positions):
            m_count, i_total, s_total = _cigar_op_lengths(cigar)
            seq, consumed = unpack_and_reconstruct(
                raw, cursor, m_count, i_total, s_total,
                cigar, pos, reference_chrom_seq,
            )
            sequences.append(seq)
            cursor += consumed
    else:
        for cigar, pos in zip(cigars, positions):
            m_count, i_total, s_total = _cigar_op_lengths(cigar)
            walk, consumed = _unpack_read_diff_with_consumed(
                raw[cursor:], m_count, i_total, s_total
            )
            cursor += consumed
            sequences.append(
                reconstruct_read_from_walk(walk, cigar, pos, reference_chrom_seq)
            )
    return sequences


# ─── Top-level encode/decode ──────────────────────────────────────────


SLICE_SIZE_DEFAULT = 10_000


def encode(
    sequences: list[bytes],
    cigars: list[str],
    positions: list[int],
    reference_chrom_seq: bytes,
    reference_md5: bytes,
    reference_uri: str,
    slice_size: int = SLICE_SIZE_DEFAULT,
) -> bytes:
    """Top-level REF_DIFF encoder.

    Args:
        sequences: list of read sequences (uppercase ACGT… bytes).
        cigars: parallel list of CIGAR strings.
        positions: parallel list of 1-based reference positions.
        reference_chrom_seq: full chromosome sequence (or covering span).
        reference_md5: 16-byte md5 of the canonical reference.
        reference_uri: URI matching the BAM header's @SQ M5 lookup key.
        slice_size: reads per slice; default 10_000 (CRAM-aligned).

    Returns:
        Encoded byte stream: codec header + slice index + slice bodies.
    """
    if not (len(sequences) == len(cigars) == len(positions)):
        raise ValueError("sequences/cigars/positions length mismatch")

    n_reads = len(sequences)
    n_slices = (n_reads + slice_size - 1) // slice_size if n_reads else 0
    slice_blobs: list[bytes] = []
    slice_index: list[SliceIndexEntry] = []
    body_offset = 0
    for s in range(n_slices):
        lo = s * slice_size
        hi = min(lo + slice_size, n_reads)
        body = encode_slice(
            sequences[lo:hi], cigars[lo:hi], positions[lo:hi], reference_chrom_seq
        )
        slice_index.append(
            SliceIndexEntry(
                body_offset=body_offset,
                body_length=len(body),
                first_position=positions[lo],
                last_position=positions[hi - 1],
                num_reads=hi - lo,
            )
        )
        slice_blobs.append(body)
        body_offset += len(body)

    header = pack_codec_header(
        CodecHeader(
            num_slices=n_slices,
            total_reads=n_reads,
            reference_md5=reference_md5,
            reference_uri=reference_uri,
        )
    )
    index_blob = b"".join(pack_slice_index_entry(e) for e in slice_index)
    return header + index_blob + b"".join(slice_blobs)


def decode(
    encoded: bytes,
    cigars: list[str],
    positions: list[int],
    reference_chrom_seq: bytes,
) -> list[bytes]:
    """Top-level REF_DIFF decoder."""
    h, header_size = unpack_codec_header(encoded)
    cursor = header_size
    slice_entries: list[SliceIndexEntry] = []
    for _ in range(h.num_slices):
        slice_entries.append(
            unpack_slice_index_entry(encoded[cursor:cursor + SLICE_INDEX_ENTRY_SIZE])
        )
        cursor += SLICE_INDEX_ENTRY_SIZE
    bodies_start = cursor

    out: list[bytes] = []
    read_cursor = 0
    for entry in slice_entries:
        body = encoded[bodies_start + entry.body_offset:
                       bodies_start + entry.body_offset + entry.body_length]
        slice_seqs = decode_slice(
            body,
            cigars[read_cursor:read_cursor + entry.num_reads],
            positions[read_cursor:read_cursor + entry.num_reads],
            reference_chrom_seq,
            num_reads=entry.num_reads,
        )
        out.extend(slice_seqs)
        read_cursor += entry.num_reads
    return out
