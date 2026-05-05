"""rANS entropy codec — order-0 and order-1.

Clean-room implementation from Jarek Duda, "Asymmetric numeral
systems: entropy coding combining speed of Huffman coding with
compression rate of arithmetic coding", arXiv:1311.2540, 2014.
Public domain algorithm. No htslib (or other third-party rANS)
source code consulted.

Cross-language equivalents:
    Objective-C: TTIORans (objc/Source/Codecs/TTIORans.{h,m})
    Java:        global.thalion.ttio.codecs.Rans

Wire format (big-endian, self-contained):

    Offset  Size   Field
    ──────  ─────  ─────────────────────────────
    0       1      order (0x00 or 0x01)
    1       4      original_length      (uint32 BE)
    5       4      payload_length       (uint32 BE)
    9       var    frequency_table
                     order-0: 256 × uint32 BE = 1024 bytes
                     order-1: for each context 0..255:
                                uint16 BE  n_nonzero
                                n_nonzero × (uint8 sym, uint16 BE freq)
    9+ft    var    payload (rANS encoded bytes)

The payload itself is laid out as

    [4 bytes: final encoder state, big-endian uint32]
    [renormalisation byte stream — read forward by the decoder]

Algorithm parameters (Binding Decisions §75-§78):

    state width:   64-bit unsigned  (Python int — unbounded but used
                   as if 64-bit for the C/Java ports)
    L            = 2**23
    b            = 2**8 (one byte renormalisation)
    M            = 2**12 = 4096
    initial x    = L
    encode order = reverse (last input byte first)
    initial ctx  = 0  (order-1 first symbol uses null-byte context)

Frequency table normalisation is fully deterministic across all
three languages (see ``_normalise_freqs``).
"""
from __future__ import annotations

from typing import List, Tuple

# ── Optional Cython acceleration ────────────────────────────────────
# Loaded lazily; absence is silently fine — the pure-Python reference
# below is byte-exact and acts as the fallback. See setup.py for the
# extension declaration.
try:
    from ._rans import _rans as _crans  # type: ignore[import-not-found]
    _HAVE_C_EXTENSION = True
except ImportError:  # pragma: no cover — Cython optional
    _crans = None
    _HAVE_C_EXTENSION = False

# ── Algorithm constants ─────────────────────────────────────────────

# Total of normalised frequency table.  Power of two so that ``x % M``
# reduces to ``x & (M - 1)`` and the encoder can use a single shift.
M: int = 1 << 12  # 4096

# Number of bits to shift for the modulo / divide by M operations.
M_BITS: int = 12

# Lower bound of the encoder state range.
L: int = 1 << 23

# I/O width — encoder emits 8 bits at a time (one byte).
B_BITS: int = 8
B: int = 1 << B_BITS  # 256

# Upper bound of the encoder state range — exclusive.
# ``state_max == b * L``; while ``x >= x_max(s)`` the encoder must
# renormalise (emit a byte) before encoding symbol s.
STATE_MAX: int = B * L  # 2**31

# Mask for ``x % M`` (M is a power of two).
M_MASK: int = M - 1

# Header bytes: 1 (order) + 4 (orig_len) + 4 (payload_len) = 9.
HEADER_LEN: int = 9


# ── Frequency normalisation ─────────────────────────────────────────


def _normalise_freqs(cnt: List[int]) -> List[int]:
    """Normalise a 256-element count vector to sum exactly to ``M``.

    Deterministic across languages ():

      1. Proportional scale: ``f[s] = max(1, cnt[s] * M // total)``
         when ``cnt[s] > 0``, else 0.
      2. ``delta = M - sum(f)``.
      3. If ``delta > 0``: distribute +1 to symbols sorted by
         **descending original count**, with **ascending symbol
         value** as the tiebreaker.  Repeat until ``delta == 0``.
      4. If ``delta < 0``: subtract 1 from symbols sorted by
         **ascending original count**, ascending symbol value
         tiebreaker, but never reduce any frequency below 1.

    Postcondition: ``sum(f) == M`` and ``f[s] >= 1`` iff
    ``cnt[s] > 0``.
    """
    if len(cnt) != 256:
        raise ValueError("count vector must have length 256")
    total = sum(cnt)
    if total <= 0:
        raise ValueError("cannot normalise empty count vector")

    freq = [0] * 256
    for s in range(256):
        c = cnt[s]
        if c > 0:
            scaled = (c * M) // total
            freq[s] = scaled if scaled >= 1 else 1

    delta = M - sum(freq)

    if delta > 0:
        # Distribute +1 to most-frequent first, ties broken by symbol value.
        # Only symbols with cnt > 0 are eligible (others must remain 0).
        order = sorted(
            (s for s in range(256) if cnt[s] > 0),
            key=lambda s: (-cnt[s], s),
        )
        if not order:  # cannot happen because total > 0
            raise AssertionError("normalise: no eligible symbols")
        i = 0
        while delta > 0:
            freq[order[i % len(order)]] += 1
            i += 1
            delta -= 1
    elif delta < 0:
        # Subtract 1 from least-frequent first, ties by symbol value.
        # Repeatedly walk the eligible list, skipping any that have
        # already reached freq == 1.
        order = sorted(
            (s for s in range(256) if cnt[s] > 0),
            key=lambda s: (cnt[s], s),
        )
        # Use a round-robin walk because a single pass may not be
        # enough if many symbols are pinned at 1.
        idx = 0
        guard = 0
        n = len(order)
        while delta < 0:
            s = order[idx % n]
            if freq[s] > 1:
                freq[s] -= 1
                delta += 1
                guard = 0
            else:
                guard += 1
                if guard > n:
                    # All remaining frequencies are 1; cannot reduce.
                    raise ValueError(
                        "normalise: cannot reduce freq table below M; "
                        "input alphabet too large for M=4096"
                    )
            idx += 1

    return freq


def _cumulative(freq: List[int]) -> List[int]:
    """Return cumulative frequencies ``c[s] = sum(freq[0:s])``."""
    cum = [0] * 257
    s = 0
    for i in range(256):
        cum[i] = s
        s += freq[i]
    cum[256] = s
    return cum


def _slot_to_symbol(freq: List[int]) -> List[int]:
    """Build a M-element lookup mapping ``slot`` to the decoded symbol.

    Used only by the decoder; constructed once per context.
    """
    table = bytearray(M)
    pos = 0
    for s in range(256):
        f = freq[s]
        if f:
            for j in range(f):
                table[pos + j] = s
            pos += f
    return list(table)


# ── Order-0 core ────────────────────────────────────────────────────


def _encode_order0(data: bytes) -> Tuple[bytes, List[int]]:
    """Encode ``data`` with a single (order-0) frequency table.

    Returns ``(payload, freq)`` where ``payload`` is the byte
    sequence ``[final_state_be32 || renorm_bytes_forward]`` and
    ``freq`` is the 256-element normalised frequency table.
    """
    if not data:
        # Empty input: no symbols to encode.  Use a flat default
        # frequency table just so the (always-encoded) header still
        # carries one; the payload is just the initial state.
        freq = [M // 256] * 256
        # M=4096, 4096/256 = 16 — sums to exactly 4096, so no fix-up.
        payload = L.to_bytes(4, "big")
        return payload, freq

    cnt = [0] * 256
    for byte in data:
        cnt[byte] += 1
    freq = _normalise_freqs(cnt)
    cum = _cumulative(freq)

    # Pre-compute per-symbol renormalisation thresholds:
    # the canonical rANS rule "while x >= (L/M) * b * f_s" simplifies
    # (with our parameters) to  x >= (1<<19) * f_s.
    x_max = [((L >> M_BITS) << B_BITS) * f for f in freq]
    # i.e. (2**23 >> 12) << 8 == 2**19 == 524288

    out = bytearray()
    x = L
    # Encode in REVERSE: last byte of input is consumed first.
    for s in reversed(data):
        f = freq[s]
        c = cum[s]
        xm = x_max[s]
        # Renormalise BEFORE encoding (canonical rANS).
        while x >= xm:
            out.append(x & 0xFF)
            x >>= 8
        # Encode the symbol.
        x = (x // f) * M + (x % f) + c

    # The decoder needs the final state to bootstrap.  Prepend it as
    # 4 big-endian bytes.  After encoding (in reverse) the renorm
    # byte stream is in ``out`` in reverse-of-emission order; the
    # decoder reads bytes in the order they were emitted by the
    # encoder, which is LIFO, so we reverse ``out`` here.
    payload = bytearray()
    payload += x.to_bytes(4, "big")
    out.reverse()
    payload += out
    return bytes(payload), freq


def _decode_order0(payload: bytes, orig_len: int, freq: List[int]) -> bytes:
    """Inverse of :func:`_encode_order0`."""
    if orig_len == 0:
        return b""

    if len(payload) < 4:
        raise ValueError("rANS: payload too short to contain bootstrap state")

    cum = _cumulative(freq)
    sym_for_slot = _slot_to_symbol(freq)

    x = int.from_bytes(payload[:4], "big")
    pos = 4
    n = len(payload)

    out = bytearray(orig_len)
    for i in range(orig_len):
        slot = x & M_MASK
        s = sym_for_slot[slot]
        out[i] = s
        f = freq[s]
        c = cum[s]
        x = f * (x >> M_BITS) + slot - c
        # Renormalise — pull bytes in until x is back in [L, b*L).
        while x < L:
            if pos >= n:
                raise ValueError("rANS: unexpected end of payload")
            x = (x << 8) | payload[pos]
            pos += 1

    return bytes(out)


# ── Order-1 core ────────────────────────────────────────────────────


def _build_order1_counts(data: bytes) -> List[List[int]]:
    """Count transition frequencies into 256 context tables.

    For each i in 0..len(data)-1, increment
    ``tables[prev][data[i]]`` where ``prev = data[i-1]`` (or 0 if
    i == 0).
    """
    tables = [[0] * 256 for _ in range(256)]
    if not data:
        return tables
    prev = 0
    for byte in data:
        tables[prev][byte] += 1
        prev = byte
    return tables


def _normalise_order1(counts: List[List[int]]) -> List[List[int]]:
    """Normalise each non-empty context row independently."""
    out: List[List[int]] = []
    for row in counts:
        if sum(row) == 0:
            out.append([0] * 256)
        else:
            out.append(_normalise_freqs(row))
    return out


def _encode_order1(data: bytes) -> Tuple[bytes, List[List[int]]]:
    if not data:
        # No transitions seen — every row is empty.
        return L.to_bytes(4, "big"), [[0] * 256 for _ in range(256)]

    counts = _build_order1_counts(data)
    freqs = _normalise_order1(counts)

    # Pre-compute cumulative tables and renorm thresholds for every
    # context row that has any nonzero entry.
    cums: List[List[int] | None] = [None] * 256
    x_maxes: List[List[int] | None] = [None] * 256
    base = L >> M_BITS  # 2**11
    for ctx in range(256):
        row = freqs[ctx]
        if sum(row) == 0:
            continue
        cums[ctx] = _cumulative(row)
        x_maxes[ctx] = [(base << B_BITS) * f for f in row]

    out = bytearray()
    x = L
    n = len(data)

    # Encode in REVERSE.  When encoding data[i] in reverse order,
    # its predecessor context is data[i-1] (or 0 if i == 0).
    for i in range(n - 1, -1, -1):
        s = data[i]
        ctx = data[i - 1] if i > 0 else 0
        row = freqs[ctx]
        f = row[s]
        if f == 0:
            # Cannot happen if counts are correct: any (ctx, s)
            # transition that occurs has non-zero count by
            # construction, hence non-zero normalised frequency.
            raise AssertionError(
                f"order-1 encode: zero freq for ctx={ctx} sym={s}"
            )
        c = cums[ctx][s]  # type: ignore[index]
        xm = x_maxes[ctx][s]  # type: ignore[index]
        while x >= xm:
            out.append(x & 0xFF)
            x >>= 8
        x = (x // f) * M + (x % f) + c

    payload = bytearray()
    payload += x.to_bytes(4, "big")
    out.reverse()
    payload += out
    return bytes(payload), freqs


def _decode_order1(
    payload: bytes, orig_len: int, freqs: List[List[int]]
) -> bytes:
    if orig_len == 0:
        return b""

    if len(payload) < 4:
        raise ValueError("rANS: payload too short to contain bootstrap state")

    # Build per-context cumulative + slot tables lazily — only for
    # contexts actually referenced during decode.  We don't know
    # which contexts will be used in advance, so just build them
    # all up-front for any row with non-zero sum (cheap on 256 rows).
    cums: List[List[int] | None] = [None] * 256
    slot_tables: List[List[int] | None] = [None] * 256
    for ctx in range(256):
        row = freqs[ctx]
        if sum(row) > 0:
            cums[ctx] = _cumulative(row)
            slot_tables[ctx] = _slot_to_symbol(row)

    x = int.from_bytes(payload[:4], "big")
    pos = 4
    n = len(payload)

    out = bytearray(orig_len)
    prev = 0
    for i in range(orig_len):
        slot_table = slot_tables[prev]
        cum = cums[prev]
        if slot_table is None or cum is None:
            raise ValueError(
                f"rANS: order-1 context {prev} has empty frequency table"
            )
        slot = x & M_MASK
        s = slot_table[slot]
        out[i] = s
        f = freqs[prev][s]
        c = cum[s]
        x = f * (x >> M_BITS) + slot - c
        while x < L:
            if pos >= n:
                raise ValueError("rANS: unexpected end of payload")
            x = (x << 8) | payload[pos]
            pos += 1
        prev = s

    return bytes(out)


# ── Frequency table (de)serialisation ───────────────────────────────


def _serialise_freqs_o0(freq: List[int]) -> bytes:
    out = bytearray(1024)
    for s in range(256):
        out[s * 4 : s * 4 + 4] = freq[s].to_bytes(4, "big")
    return bytes(out)


def _deserialise_freqs_o0(buf: bytes, off: int) -> Tuple[List[int], int]:
    if off + 1024 > len(buf):
        raise ValueError("rANS: order-0 freq table truncated")
    freq = [0] * 256
    for s in range(256):
        freq[s] = int.from_bytes(buf[off + s * 4 : off + s * 4 + 4], "big")
    if sum(freq) != M:
        raise ValueError(
            f"rANS: order-0 freq table sum {sum(freq)} != M={M}"
        )
    return freq, off + 1024


def _serialise_freqs_o1(freqs: List[List[int]]) -> bytes:
    out = bytearray()
    for ctx in range(256):
        row = freqs[ctx]
        nonzero = [(s, row[s]) for s in range(256) if row[s] > 0]
        out += len(nonzero).to_bytes(2, "big")
        for s, f in nonzero:
            out.append(s)
            out += f.to_bytes(2, "big")
    return bytes(out)


def _deserialise_freqs_o1(
    buf: bytes, off: int
) -> Tuple[List[List[int]], int]:
    freqs = [[0] * 256 for _ in range(256)]
    n = len(buf)
    for ctx in range(256):
        if off + 2 > n:
            raise ValueError("rANS: order-1 freq table truncated (count)")
        n_nonzero = int.from_bytes(buf[off : off + 2], "big")
        off += 2
        if n_nonzero == 0:
            continue
        row_sum = 0
        for _ in range(n_nonzero):
            if off + 3 > n:
                raise ValueError(
                    "rANS: order-1 freq table truncated (entry)"
                )
            s = buf[off]
            f = int.from_bytes(buf[off + 1 : off + 3], "big")
            if f == 0:
                raise ValueError(
                    "rANS: order-1 nonzero entry has freq 0"
                )
            freqs[ctx][s] = f
            row_sum += f
            off += 3
        if row_sum != M:
            raise ValueError(
                f"rANS: order-1 row {ctx} sums to {row_sum} != M={M}"
            )
    return freqs, off


# ── Public API ──────────────────────────────────────────────────────


def encode(data: bytes, order: int = 0) -> bytes:
    """Encode ``data`` using rANS with the given context order.

    Parameters
    ----------
    data : bytes
        Input byte string.  May be empty.
    order : int
        ``0`` (marginal frequencies) or ``1`` (frequencies conditioned
        on the previous byte).

    Returns
    -------
    bytes
        Self-contained encoded stream — see module docstring for the
        wire format.
    """
    if order not in (0, 1):
        raise ValueError(f"rANS: unsupported order {order!r}")
    if not isinstance(data, (bytes, bytearray, memoryview)):
        raise TypeError("rANS encode: data must be bytes-like")
    data = bytes(data)
    if len(data) > 0xFFFFFFFF:
        raise ValueError("rANS encode: input exceeds 4 GiB header limit")

    if order == 0:
        if _HAVE_C_EXTENSION:
            payload, freq = _crans.encode_order0_c(data)
        else:
            payload, freq = _encode_order0(data)
        ft = _serialise_freqs_o0(freq)
    else:
        if _HAVE_C_EXTENSION:
            payload, freqs = _crans.encode_order1_c(data)
        else:
            payload, freqs = _encode_order1(data)
        ft = _serialise_freqs_o1(freqs)

    header = bytearray(HEADER_LEN)
    header[0] = order
    header[1:5] = len(data).to_bytes(4, "big")
    header[5:9] = len(payload).to_bytes(4, "big")
    return bytes(header) + ft + payload


def decode(encoded: bytes) -> bytes:
    """Decode a stream produced by :func:`encode`.

    Raises
    ------
    ValueError
        If the input is too short, has an unknown order byte, has a
        truncated frequency table, or the declared payload length
        does not match the bytes that follow.
    """
    if not isinstance(encoded, (bytes, bytearray, memoryview)):
        raise TypeError("rANS decode: input must be bytes-like")
    encoded = bytes(encoded)

    if len(encoded) < HEADER_LEN:
        raise ValueError("rANS: stream shorter than header")

    order = encoded[0]
    if order not in (0, 1):
        raise ValueError(f"rANS: unsupported order byte {order!r}")
    orig_len = int.from_bytes(encoded[1:5], "big")
    payload_len = int.from_bytes(encoded[5:9], "big")

    off = HEADER_LEN
    if order == 0:
        freq, off = _deserialise_freqs_o0(encoded, off)
    else:
        freqs, off = _deserialise_freqs_o1(encoded, off)

    if off + payload_len != len(encoded):
        raise ValueError(
            f"rANS: declared total length {off + payload_len} "
            f"!= actual {len(encoded)}"
        )
    payload = encoded[off : off + payload_len]

    if order == 0:
        if _HAVE_C_EXTENSION:
            return _crans.decode_order0_c(payload, orig_len, freq)
        return _decode_order0(payload, orig_len, freq)
    else:
        if _HAVE_C_EXTENSION:
            return _crans.decode_order1_c(payload, orig_len, freqs)
        return _decode_order1(payload, orig_len, freqs)


__all__ = ["encode", "decode", "M", "L"]
