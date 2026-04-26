"""BASE_PACK genomic-sequence codec — 2-bit ACGT + sidecar mask.

Clean-room implementation. The 2-bit-per-base packing convention is
decades-old prior art, fundamental and ungatewayed by IP. **No
htslib, no jbzip, no CRAM tools-Java source consulted.** The
sidecar mask layout (sparse position+byte list) is a TTI-O-specific
design choice — see HANDOFF.md M84 §3, binding decision §80.

Cross-language equivalents:
    Objective-C: TTIOBasePack (objc/Source/Codecs/TTIOBasePack.{h,m})
    Java:        global.thalion.ttio.codecs.BasePack

Wire format (big-endian throughout, self-contained):

    Offset      Size  Field
    ──────      ────  ──────────────────────────────────────────
    0           1     version            (0x00)
    1           4     original_length    (uint32 BE)
    5           4     packed_length      (uint32 BE — = ceil(orig/4))
    9           4     mask_count         (uint32 BE)
    13          var   packed_body        (packed_length bytes)
    13+pl       var   mask               (mask_count × 5 bytes:
                                           uint32 BE position,
                                           uint8 original_byte)

Total length = ``13 + packed_length + 5 * mask_count`` bytes.

Pack mapping (case-sensitive; binding decision §81):

    'A' (0x41) → 0b00
    'C' (0x43) → 0b01
    'G' (0x47) → 0b10
    'T' (0x54) → 0b11
    anything else → mask entry (placeholder 0b00 written to body)

Bit order within byte is **big-endian** (binding decision §82) —
the first base in the input occupies the two highest-order bits.
The padding bits in the final body byte (when ``len(input) % 4 !=
0``) are zero (binding decision §83); the decoder uses
``original_length`` to know how many slots to consume.

Mask entries are sorted ascending by position (binding decision
§84); the encoder emits them in input order, the decoder validates
strict ascending order. The first byte is ``version = 0x00``
(binding decision §85), distinct from the M79 codec id ``0x06``.
"""
from __future__ import annotations

import operator
import struct

# ── Wire-format constants ──────────────────────────────────────────

#: Version byte — first byte of every BASE_PACK stream.
VERSION: int = 0x00

#: Header bytes: 1 (version) + 4 (orig_len) + 4 (packed_len) +
#: 4 (mask_count) = 13.
HEADER_LEN: int = 13

#: Mask entry size: uint32 BE position + uint8 original byte.
MASK_ENTRY_LEN: int = 5

# ── Pack lookup tables ─────────────────────────────────────────────

#: 256-entry ``bytes.translate`` table mapping every input byte to a
#: 2-bit slot value: A→0, C→1, G→2, T→3, every other byte → 0
#: (the placeholder written into the body for non-ACGT slots).
def _build_translate_table() -> bytes:
    tbl = bytearray(256)  # default 0 — placeholder for non-ACGT
    tbl[ord("A")] = 0b00
    tbl[ord("C")] = 0b01
    tbl[ord("G")] = 0b10
    tbl[ord("T")] = 0b11
    return bytes(tbl)


#: Companion table for non-ACGT detection: ACGT bytes map to 0x00,
#: every other byte to 0x01. A single ``b"\x01" in marks`` check
#: tells us whether any mask entries are needed.
def _build_mark_table() -> bytes:
    tbl = bytearray(b"\x01" * 256)
    tbl[ord("A")] = 0x00
    tbl[ord("C")] = 0x00
    tbl[ord("G")] = 0x00
    tbl[ord("T")] = 0x00
    return bytes(tbl)


_PACK_TRANSLATE: bytes = _build_translate_table()
_MARK_TRANSLATE: bytes = _build_mark_table()

#: 4-entry table mapping 2-bit slot values back to ASCII bytes.
_UNPACK_TABLE: bytes = b"ACGT"

#: 256-entry decode lookup: each body byte maps to its 4-byte ACGT
#: expansion (high two bits → first base, low two bits → fourth).
#: Used by :func:`decode` to unpack the body in a single C-driven
#: ``b"".join(...)`` over a list comprehension, which is several
#: times faster than a per-slot Python shift-and-mask loop.
_UNPACK_BYTE_TABLE: tuple[bytes, ...] = tuple(
    bytes(
        (
            _UNPACK_TABLE[(i >> 6) & 0b11],
            _UNPACK_TABLE[(i >> 4) & 0b11],
            _UNPACK_TABLE[(i >> 2) & 0b11],
            _UNPACK_TABLE[i & 0b11],
        )
    )
    for i in range(256)
)


# ── Public API ─────────────────────────────────────────────────────


def encode(data: bytes) -> bytes:
    """Encode ``data`` using BASE_PACK + sidecar mask.

    Returns a self-contained byte string per the wire format
    described in this module's docstring (HANDOFF.md M84 §2). Pure
    ACGT input compresses to ~25% of original size plus a 13-byte
    header; non-ACGT bytes round-trip losslessly via the mask.

    Parameters
    ----------
    data:
        Input bytes. Any byte value is accepted; ``A``/``C``/``G``/``T``
        (uppercase only — see binding decision §81) are packed into
        2-bit slots, anything else gets a mask entry.

    Returns
    -------
    bytes
        Encoded stream of length
        ``13 + ceil(len(data) / 4) + 5 * mask_count``.
    """
    orig_len = len(data)
    packed_len = (orig_len + 3) // 4

    # Step 1: translate every input byte to its 2-bit slot value
    # (non-ACGT bytes map to placeholder 0b00 here; the mask scan
    # below recovers their true bytes). ``bytes.translate`` runs in
    # C and is ~2 orders of magnitude faster than a Python loop.
    slots = data.translate(_PACK_TRANSLATE)

    # Step 2: pack four slot bytes into one body byte (big-endian
    # within byte: first base in the highest two bits). Pad the
    # slot stream to a multiple of 4 with placeholder zeros so the
    # packing loop need not special-case the tail (binding decision
    # §83 — padding bits in the final body byte are zero).
    pad = (-orig_len) & 3
    if pad:
        slots = slots + bytes(pad)
    it = iter(slots)
    body = bytes(
        (a << 6) | (b << 4) | (c << 2) | d for a, b, c, d in zip(it, it, it, it)
    )
    # Sanity: the zip(...) idiom generated exactly ``packed_len`` bytes.
    assert len(body) == packed_len

    # Step 3: collect mask entries. Most realistic genomic input is
    # >99 % ACGT, so we first do a single ``bytes.translate``-based
    # mark + ``in`` membership probe to short-circuit the no-mask
    # case (the dominant fast path).
    marks = data.translate(_MARK_TRANSLATE)
    if b"\x01" in marks:
        # bytearray.find loop is faster than a per-byte enumerate.
        mask_parts: list[bytes] = []
        start = 0
        while True:
            pos = marks.find(b"\x01", start)
            if pos < 0:
                break
            mask_parts.append(struct.pack(">IB", pos, data[pos]))
            start = pos + 1
        mask_count = len(mask_parts)
        header = struct.pack(">BIII", VERSION, orig_len, packed_len, mask_count)
        return header + body + b"".join(mask_parts)

    header = struct.pack(">BIII", VERSION, orig_len, packed_len, 0)
    return header + body


def decode(encoded: bytes) -> bytes:
    """Decode a stream produced by :func:`encode`.

    Reads the header, unpacks the 2-bit body, applies the sidecar
    mask. Validates strictly: the version byte, the
    ``packed_length`` invariant, the total stream length, and that
    every mask position is in ``[0, original_length)`` and strictly
    ascending.

    Raises
    ------
    ValueError
        If the stream is shorter than the header, has a bad version
        byte, has a wrong ``packed_length`` for the declared
        ``original_length``, has a body or mask section of the
        wrong length, has a mask position out of range, or has
        unsorted / duplicate mask positions.
    """
    if len(encoded) < HEADER_LEN:
        raise ValueError(
            f"BASE_PACK stream too short for header: {len(encoded)} < {HEADER_LEN}"
        )

    version, orig_len, packed_len, mask_count = struct.unpack(
        ">BIII", encoded[:HEADER_LEN]
    )

    if version != VERSION:
        raise ValueError(
            f"BASE_PACK bad version byte: 0x{version:02x} (expected 0x{VERSION:02x})"
        )

    expected_packed = (orig_len + 3) // 4
    if packed_len != expected_packed:
        raise ValueError(
            f"BASE_PACK packed_length mismatch: {packed_len} != "
            f"ceil({orig_len}/4) = {expected_packed}"
        )

    expected_total = HEADER_LEN + packed_len + MASK_ENTRY_LEN * mask_count
    if len(encoded) != expected_total:
        raise ValueError(
            f"BASE_PACK stream length mismatch: {len(encoded)} != "
            f"{expected_total} (header {HEADER_LEN} + body {packed_len} + "
            f"mask {MASK_ENTRY_LEN}*{mask_count})"
        )

    body = encoded[HEADER_LEN : HEADER_LEN + packed_len]

    # Unpack body via 256-entry table → list of 4-byte chunks →
    # ``b"".join``. ``operator.itemgetter(*body)(table)`` runs the
    # entire mapping in C; it returns a single bytes object when
    # body has length 1, so we special-case that.
    table = _UNPACK_BYTE_TABLE
    if orig_len == 0:
        out = bytearray(0)
    else:
        full_bytes = orig_len >> 2
        tail = orig_len - (full_bytes << 2)
        if tail == 0:
            if full_bytes == 1:
                out = bytearray(table[body[0]])
            else:
                out = bytearray(b"".join(operator.itemgetter(*body)(table)))
        else:
            # Decode the full bytes via the fast path, then append a
            # truncated expansion of the final padded byte.
            if full_bytes == 0:
                decoded = b""
            elif full_bytes == 1:
                decoded = table[body[0]]
            else:
                decoded = b"".join(
                    operator.itemgetter(*body[:full_bytes])(table)
                )
            tail_full = table[body[full_bytes]]
            out = bytearray(decoded + tail_full[:tail])

    # Apply mask. Validate ascending positions and 0 <= pos < orig_len
    # in a single scan.
    mask_offset = HEADER_LEN + packed_len
    prev_pos = -1
    for k in range(mask_count):
        entry = encoded[mask_offset + k * MASK_ENTRY_LEN : mask_offset + (k + 1) * MASK_ENTRY_LEN]
        pos, byte = struct.unpack(">IB", entry)
        if pos >= orig_len:
            raise ValueError(
                f"BASE_PACK mask position {pos} out of range "
                f"[0, {orig_len})"
            )
        if pos <= prev_pos:
            raise ValueError(
                f"BASE_PACK mask positions not strictly ascending: "
                f"{pos} after {prev_pos}"
            )
        prev_pos = pos
        out[pos] = byte

    return bytes(out)
