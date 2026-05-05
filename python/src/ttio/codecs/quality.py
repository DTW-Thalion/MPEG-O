"""QUALITY_BINNED genomic quality-score codec — Illumina-8 bin table.

Clean-room implementation. The 8-bin Phred quantisation table used
here ("Illumina-8 / CRUMBLE-style") is documented in many published
sources — Illumina's reduced-representation guidance, James
Bonfield's CRUMBLE paper (Bioinformatics 2019), HTSlib's
``qual_quants`` field, NCBI SRA's ``lossy.sra`` quality binning.
**No htslib, no CRUMBLE, no SRA toolkit source consulted at any
point.** The 4-bit packing geometry is the natural choice for an
8-bin index alphabet and is not derived from any reference.

Cross-language equivalents:
    Objective-C: TTIOQuality (objc/Source/Codecs/TTIOQuality.{h,m})
    Java:        global.thalion.ttio.codecs.Quality

Wire format (big-endian throughout, self-contained):

    Offset      Size  Field
    ──────      ────  ──────────────────────────────────────────
    0           1     version            (0x00)
    1           1     scheme_id          (0x00 = "illumina-8")
    2           4     original_length    (uint32 BE)
    6           var   packed_indices     (ceil(original_length / 2) bytes)

Total length = ``6 + ((original_length + 1) >> 1)`` bytes.

Bin table (Illumina-8; binding decisions §91, §92):

    Bin  Phred range   Centre
    ───  ───────────   ──────
     0       0..1         0
     1       2..9         5
     2      10..19       15
     3      20..24       22
     4      25..29       27
     5      30..34       32
     6      35..39       37
     7     40..255       40    (saturates; binding decision §93)

Bit order within byte is **big-endian** (binding decision §95) — the
first input quality occupies the high nibble of its body byte. The
padding bits in the final body byte (when ``len(input) % 2 != 0``)
are zero (binding decision §96); the decoder uses
``original_length`` to know how many indices to consume.

Lossy round-trip (binding decision §97):
``decode(encode(x)) == bin_centre[bin_of[x]]``, NOT ``x``. For an
input byte that's already a bin centre (0/5/15/22/27/32/37/40),
round-trip is byte-exact. For other Phred values, round-trip
produces the bin centre for that value's bin.
"""
from __future__ import annotations

import struct

# ── Wire-format constants ──────────────────────────────────────────

# Version byte — first byte of every QUALITY_BINNED stream.
VERSION: int = 0x00

# Scheme id for Illumina-8 — second byte of every stream. v0 of
# this codec defines this single scheme; future schemes (NCBI 4-bin,
# Bonfield variable-width, etc.) would get distinct scheme_ids.
SCHEME_ILLUMINA_8: int = 0x00

# Header bytes: 1 (version) + 1 (scheme_id) + 4 (orig_len) = 6.
HEADER_LEN: int = 6


# ── Lookup tables (Illumina-8 scheme) ──────────────────────────────


def _build_bin_index_table() -> bytes:
    """Build a 256-entry table mapping each input byte → bin index 0..7.

    Used with :meth:`bytes.translate` for the byte→bin-index pass —
    runs in C and is several orders of magnitude faster than a
    Python per-byte loop.
    """
    tbl = bytearray(256)
    for p in range(256):
        if p <= 1:
            tbl[p] = 0
        elif p <= 9:
            tbl[p] = 1
        elif p <= 19:
            tbl[p] = 2
        elif p <= 24:
            tbl[p] = 3
        elif p <= 29:
            tbl[p] = 4
        elif p <= 34:
            tbl[p] = 5
        elif p <= 39:
            tbl[p] = 6
        else:
            tbl[p] = 7
    return bytes(tbl)


def _build_centre_table() -> bytes:
    """Build a 256-entry table mapping bin index 0..7 → bin centre.

    Indices 0..7 hold the Illumina-8 centres; positions 8..255 are
    unreachable (the unpacker only emits values 0..15 high-nibble,
    but body bytes only ever encode bin indices 0..7 because the
    encoder is the only producer). Filling 8..255 with 0x00 keeps the
    table 256-entry so :meth:`bytes.translate` works directly.
    """
    tbl = bytearray(256)
    centres = (0, 5, 15, 22, 27, 32, 37, 40)
    for i, c in enumerate(centres):
        tbl[i] = c
    return bytes(tbl)


_BIN_INDEX_TABLE: bytes = _build_bin_index_table()
_CENTRE_TABLE: bytes = _build_centre_table()

# Two 256-entry ``bytes.translate`` tables for fast decode:
# ``_HI_TO_CENTRE[b]`` = bin centre for the high nibble of byte b;
# ``_LO_TO_CENTRE[b]`` = bin centre for the low nibble of byte b.
# The decoder runs ``body.translate`` twice (once per table — both
# in C, both O(len(body))) then interleaves the two output streams
# via ``bytearray[0::2] = hi; bytearray[1::2] = lo`` slice
# assignment, which is also C-driven. This combination is roughly
# an order of magnitude faster than a per-byte Python loop on
# multi-MiB inputs. Nibbles 8..15 are unreachable from a
# well-formed stream (the encoder only produces 0..7); we map them
# to centre 0, mirroring the encoder's "trust the producer"
# policy from binding decision §92.
def _build_nibble_tables() -> tuple[bytes, bytes]:
    centres = (0, 5, 15, 22, 27, 32, 37, 40)
    hi = bytearray(256)
    lo = bytearray(256)
    for i in range(256):
        hi_nib = (i >> 4) & 0x0F
        lo_nib = i & 0x0F
        hi[i] = centres[hi_nib] if hi_nib < 8 else 0
        lo[i] = centres[lo_nib] if lo_nib < 8 else 0
    return bytes(hi), bytes(lo)


_HI_TO_CENTRE, _LO_TO_CENTRE = _build_nibble_tables()


# ── Public API ─────────────────────────────────────────────────────


def encode(data: bytes) -> bytes:
    """Encode ``data`` (Phred score bytes) using QUALITY_BINNED.

    Maps each input byte through the Illumina-8 bin table, packs
    bin indices 4-bits-per-index (big-endian within byte: first
    input quality in the high nibble). Returns a self-contained byte
    string per the wire format in this module's docstring
    (HANDOFF.md M85 §3).

    Lossy: round-trip via bin centres.
    ``decode(encode(x)) == bin_centre[bin_of[x]]`` for each byte x.

    Parameters
    ----------
    data:
        Input bytes — Phred quality scores. Any byte value 0..255
        is accepted; values > 40 saturate to bin 7 (centre 40).

    Returns
    -------
    bytes
        Encoded stream of length ``6 + ((len(data) + 1) >> 1)``.
    """
    orig_len = len(data)

    # Step 1: translate each input byte to its bin index 0..7.
    # ``bytes.translate`` runs in C and is ~2 orders of magnitude
    # faster than a Python loop.
    indices = data.translate(_BIN_INDEX_TABLE)

    # Step 2: pack two indices per body byte, big-endian within byte
    # (first index in the high nibble — binding decision §95). For
    # odd-length input, pad the index stream with a single zero so
    # the final body byte's low nibble is zero (binding decision
    # §96).
    if orig_len & 1:
        indices = indices + b"\x00"

    # Pack: iterate two bytes at a time. ``zip(it, it)`` walks the
    # iterator twice per step — same idiom used by base_pack.py.
    it = iter(indices)
    body = bytes((a << 4) | b for a, b in zip(it, it))

    header = struct.pack(">BBI", VERSION, SCHEME_ILLUMINA_8, orig_len)
    return header + body


def decode(encoded: bytes) -> bytes:
    """Decode a stream produced by :func:`encode`.

    Reads the header, unpacks the 4-bit bin indices from the body,
    maps each through the bin-centre table to produce output Phred
    bytes. Validates strictly: the version byte, the scheme_id, and
    the total stream length against ``original_length``.

    Parameters
    ----------
    encoded:
        Encoded stream as produced by :func:`encode`.

    Returns
    -------
    bytes
        Output Phred bytes of length ``original_length``. Each byte
        is the bin centre for the corresponding input byte's bin
        (lossy by construction — binding decision §97).

    Raises
    ------
    ValueError
        If the stream is shorter than the 6-byte header, has a bad
        version byte, has a bad scheme_id, or has a body length
        that doesn't match ``ceil(original_length / 2)``.
    """
    if len(encoded) < HEADER_LEN:
        raise ValueError(
            f"QUALITY_BINNED stream too short for header: "
            f"{len(encoded)} < {HEADER_LEN}"
        )

    version, scheme_id, orig_len = struct.unpack(">BBI", encoded[:HEADER_LEN])

    if version != VERSION:
        raise ValueError(
            f"QUALITY_BINNED bad version byte: 0x{version:02x} "
            f"(expected 0x{VERSION:02x})"
        )

    if scheme_id != SCHEME_ILLUMINA_8:
        raise ValueError(
            f"QUALITY_BINNED unknown scheme_id: 0x{scheme_id:02x} "
            f"(only 0x{SCHEME_ILLUMINA_8:02x} = 'illumina-8' is defined)"
        )

    expected_body_len = (orig_len + 1) >> 1
    expected_total = HEADER_LEN + expected_body_len
    if len(encoded) != expected_total:
        raise ValueError(
            f"QUALITY_BINNED stream length mismatch: {len(encoded)} != "
            f"{expected_total} (header {HEADER_LEN} + body "
            f"ceil({orig_len}/2) = {expected_body_len})"
        )

    if orig_len == 0:
        return b""

    body = encoded[HEADER_LEN:]

    # Unpack via two C-driven ``bytes.translate`` passes (one per
    # nibble) plus C-driven slice-assignment for interleaving. High
    # nibble of each body byte → output position 2k; low nibble →
    # output position 2k+1 (binding decision §95). For odd-length
    # input the final low nibble is the zero padding (binding
    # decision §96) which we drop by trimming the lo stream.
    hi = body.translate(_HI_TO_CENTRE)
    lo = body.translate(_LO_TO_CENTRE)
    out = bytearray(orig_len)
    out[0::2] = hi
    if orig_len & 1:
        # Drop the trailing padding centre from lo before assigning.
        out[1::2] = lo[: orig_len // 2]
    else:
        out[1::2] = lo
    return bytes(out)
