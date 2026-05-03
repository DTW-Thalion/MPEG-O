"""TTI-O M94.Z — CRAM-mimic FQZCOMP_NX16 (rANS-Nx16) reference codec.

This is a NEW codec module, parallel to (and independent from) the M94
v1 implementation in :mod:`ttio.codecs.fqzcomp_nx16`. M94.Z follows the
CRAM 3.1 ``rANS-Nx16`` discipline:

* **Static-per-block** frequency tables (built in a forward pre-pass
  over the input, normalised once to ``T = 4096``, held constant for
  the entire block).
* **L = 2^15**, **B = 16** (16-bit renormalisation chunks),
  ``b·L = 2^31``.
* **N = 4** interleaved rANS states.
* **Bit-pack context** (CRAM-style) — no SplitMix64 hash. Layout:
  12 bits ``prev_q`` | 2 bits position bucket | 1 bit revcomp.

The wire-format magic is ``M94Z`` (replaces M94 v1's ``FQZN``).

This is the **pure-Python prototype** for byte-exact algorithm
validation. Cython acceleration is a follow-on phase (M94.Z.2).

Spec: ``docs/superpowers/specs/2026-04-29-m94z-cram-mimic-design.md``.

Public API:
    encode(qualities, read_lengths, revcomp_flags, *, params=None) -> bytes
    decode_with_metadata(blob, revcomp_flags=None) -> (qualities, read_lengths, revcomp_flags_used)
"""
from __future__ import annotations

import struct
import zlib
from bisect import bisect_right
from dataclasses import dataclass

import numpy as np


# ── rANS-Nx16 algorithm constants (per spec §1) ─────────────────────────

L: int = 1 << 15            # 32 768 — state lower bound
B_BITS: int = 16            # renormalisation chunk size in bits
B: int = 1 << B_BITS        # 65 536
B_MASK: int = B - 1         # 0xFFFF
STATE_MAX: int = B * L      # 2^31 — exclusive upper bound on state
T: int = 1 << 12            # 4096 — fixed total per block
T_BITS: int = 12
T_MASK: int = T - 1
NUM_STREAMS: int = 4

# x_max premultiplier:  ((L >> T_BITS) << B_BITS) = (2^15 / 2^12) * 2^16
#                                                  = 2^3 * 2^16
#                                                  = 2^19 = 524 288
X_MAX_PREFACTOR: int = (L >> T_BITS) << B_BITS  # 524288

# ── Wire-format constants ───────────────────────────────────────────────

MAGIC = b"M94Z"
VERSION = 1
VERSION_V2_NATIVE = 2  # M94.Z V2: body produced by libttio_rans (Task 21 wiring)
VERSION_V3_ADAPTIVE = 3  # M94.Z V3: adaptive Range Coder (L2 / Task #82 Phase B.2)
VERSION_V4_FQZCOMP = 4  # M94.Z V4: CRAM 3.1 fqzcomp_qual port (L2.X Stage 2)

# V3 adaptive RC params (mirror native ttio_rans.h)
ADAPTIVE_STEP: int = 16
ADAPTIVE_T_MAX: int = 65519


# ── Default context parameters (per spec §4.3) ──────────────────────────

DEFAULT_QBITS: int = 12   # 12 bits prev_q history
DEFAULT_PBITS: int = 2    # 2 bits position bucket
DEFAULT_DBITS: int = 0    # delta channel — disabled in v1
DEFAULT_SLOC: int = 14    # 1 << 14 = 16384 contexts


@dataclass(frozen=True)
class ContextParams:
    """Bit-pack context parameters.

    Default: qbits=12, pbits=2, dbits=0, sloc=14 → 16384-entry table.

    Wire layout (8 bytes):
        qbits   : uint8
        pbits   : uint8
        dbits   : uint8
        sloc    : uint8
        reserved: uint8[4] (must be 0)
    """
    qbits: int = DEFAULT_QBITS
    pbits: int = DEFAULT_PBITS
    dbits: int = DEFAULT_DBITS
    sloc: int = DEFAULT_SLOC


CONTEXT_PARAMS_SIZE: int = 8


def pack_context_params(p: ContextParams) -> bytes:
    return struct.pack(
        "<BBBB4x",
        p.qbits & 0xFF, p.pbits & 0xFF, p.dbits & 0xFF, p.sloc & 0xFF,
    )


def unpack_context_params(blob: bytes, off: int = 0) -> ContextParams:
    if len(blob) - off < CONTEXT_PARAMS_SIZE:
        raise ValueError("M94Z: context_params truncated")
    qbits, pbits, dbits, sloc = struct.unpack_from("<BBBB4x", blob, off)
    return ContextParams(qbits=qbits, pbits=pbits, dbits=dbits, sloc=sloc)


# ── Context bit-pack (per spec §4.2) ────────────────────────────────────

def position_bucket_pbits(position: int, read_length: int, pbits: int) -> int:
    """Coarse position-in-read bucket, 0..(2^pbits - 1).

    Spec §4.2: ``min(2^pbits - 1, (pos * 2^pbits) // read_length)``.
    """
    if pbits <= 0:
        return 0
    n_buckets = 1 << pbits
    if read_length <= 0 or position <= 0:
        return 0
    if position >= read_length:
        return n_buckets - 1
    return min(n_buckets - 1, (position * n_buckets) // read_length)


def m94z_context(
    prev_q: int,
    pos_bucket: int,
    revcomp: int,
    qbits: int = DEFAULT_QBITS,
    pbits: int = DEFAULT_PBITS,
    sloc: int = DEFAULT_SLOC,
) -> int:
    """Bit-pack context vector to ``[0, 1<<sloc)``.

    Per spec §4.2:
        ctx = (prev_q & ((1<<qbits)-1))
            | ((pos_bucket & ((1<<pbits)-1)) << qbits)
            | ((revcomp & 1) << (qbits + pbits))
        return ctx & ((1<<sloc) - 1)

    With qbits=12, pbits=2, sloc=14: 12+2+1 = 15 bits, masked to 14.
    """
    qmask = (1 << qbits) - 1
    pmask = (1 << pbits) - 1
    smask = (1 << sloc) - 1
    ctx = (prev_q & qmask)
    ctx |= (pos_bucket & pmask) << qbits
    ctx |= (revcomp & 1) << (qbits + pbits)
    return ctx & smask


# ── Frequency-table normalisation (per spec §3.3) ───────────────────────

def normalise_to_total(raw_count: list[int], total: int = T) -> list[int]:
    """Normalise ``raw_count[256]`` to a freq[256] summing exactly to ``total``.

    Standard "scale-and-fix" algorithm:
      1. If sum is 0, set freq[0] = total (degenerate convention).
      2. Otherwise scale each non-zero count proportionally with rounding,
         floor at 1 (so any present symbol stays encodable).
      3. Adjust by walking the largest entries up/down until sum == total.

    All deterministic integer math — no floats, no order ambiguity (we
    pick the largest freq with the smallest symbol index for ties).
    """
    s = sum(raw_count)
    freq = [0] * 256
    if s == 0:
        freq[0] = total
        return freq

    # Scaled rounding: freq[i] = max(1, round(c * total / s)) for c > 0.
    fsum = 0
    for i in range(256):
        c = raw_count[i]
        if c == 0:
            continue
        # Use integer rounding: (c * total + s // 2) // s.
        scaled = (c * total + s // 2) // s
        if scaled < 1:
            scaled = 1
        freq[i] = scaled
        fsum += scaled

    delta = total - fsum
    if delta == 0:
        return freq

    if delta > 0:
        # Need to add `delta` total counts. Add 1-by-1 to the entries
        # ordered by largest current freq, ascending sym tie-break, but
        # only to symbols that already had count > 0 (preserve zero-ness).
        order = sorted(
            (i for i in range(256) if raw_count[i] > 0),
            key=lambda i: (-freq[i], i),
        )
        if not order:
            # Pathological: should not happen since s > 0 implies at least
            # one nonzero. But guard anyway.
            freq[0] = total
            return freq
        k = 0
        n = len(order)
        while delta > 0:
            freq[order[k % n]] += 1
            k += 1
            delta -= 1
        return freq

    # delta < 0: need to remove (-delta) total counts. Walk largest entries,
    # decrementing but never below 1.
    deficit = -delta
    while deficit > 0:
        # Find the largest freq among those still > 1, breaking ties by
        # smallest sym (consistent with delta>0 path).
        best_i = -1
        best_v = -1
        for i in range(256):
            if freq[i] > 1 and freq[i] > best_v:
                best_v = freq[i]
                best_i = i
        if best_i < 0:
            # Cannot reduce further — every present freq is at the floor.
            # This should be vanishingly rare since total >= number of
            # distinct symbols. Bail with the current (over-target) sum;
            # the caller has set total = T = 4096 which is far above 256.
            raise ValueError(
                "normalise_to_total: cannot reduce below floor=1; "
                "raw_count has too many distinct symbols vs total"
            )
        freq[best_i] -= 1
        deficit -= 1
    return freq


def cumulative(freq: list[int]) -> list[int]:
    """Return cum[0..256] where cum[s] = sum(freq[0:s])."""
    cum = [0] * 257
    s = 0
    for i in range(256):
        cum[i] = s
        s += freq[i]
    cum[256] = s
    return cum


# ── Per-symbol context evolution ────────────────────────────────────────

def _build_context_seq(
    qualities: bytes,
    read_lengths: list[int],
    revcomp_flags: list[int],
    n_padded: int,
    qbits: int,
    pbits: int,
    sloc: int,
) -> list[int]:
    """Compute the per-symbol context sequence (length n_padded).

    Encoder and decoder must produce IDENTICAL context sequences. The
    decoder reconstructs this via the same prev_q ring carried forward
    over already-decoded symbols.

    For positions i >= len(qualities) (padding), use the "all zero"
    context. The padding bytes are themselves zero, so freq[0] must be
    > 0 in the all-zero context's freq table — guaranteed by the build
    pass which counts those padding symbols.
    """
    n = len(qualities)
    contexts = [0] * n_padded
    pad_ctx = m94z_context(0, 0, 0, qbits, pbits, sloc)

    if n_padded == 0:
        return contexts

    read_idx = 0
    pos_in_read = 0
    cur_read_len = read_lengths[0] if read_lengths else 0
    cur_revcomp = revcomp_flags[0] if revcomp_flags else 0
    cumulative_read_end = cur_read_len
    prev_q = 0

    for i in range(n_padded):
        if i < n:
            if (i >= cumulative_read_end
                    and read_idx < len(read_lengths) - 1):
                read_idx += 1
                pos_in_read = 0
                cur_read_len = read_lengths[read_idx]
                cur_revcomp = revcomp_flags[read_idx]
                cumulative_read_end += cur_read_len
                prev_q = 0
            pb = position_bucket_pbits(pos_in_read, cur_read_len, pbits)
            contexts[i] = m94z_context(
                prev_q, pb, cur_revcomp & 1, qbits, pbits, sloc,
            )
            sym = qualities[i]
            # Update prev_q ring: shift in the new symbol. For qbits=12,
            # we keep the low 12 bits of (prev_q << 4) | (sym & 0xF).
            # Quality bytes are 7-bit Phred+33 (33..126), so 4-bit quant
            # discards info but only for hash purposes; the actual
            # symbol byte is encoded losslessly via rANS.
            # Use shift width that fits qbits exactly, i.e. spread the
            # last (qbits / 4) symbols across qbits.
            # For qbits=12 we want a 3-symbol window of 4-bit quantised
            # qualities: prev_q = ((prev_q << 4) | (sym & 0xF)) & 0xFFF.
            shift = max(1, qbits // 3)  # for qbits=12, shift=4 → 3-sym window
            qmask_local = (1 << qbits) - 1
            prev_q = ((prev_q << shift) | (sym & ((1 << shift) - 1))) & qmask_local
            pos_in_read += 1
        else:
            contexts[i] = pad_ctx
    return contexts


def _build_context_seq_arr_vec(
    qualities: bytes,
    read_lengths: list[int],
    revcomp_flags: list[int],
    n_padded: int,
    qbits: int,
    pbits: int,
    sloc: int,
) -> np.ndarray:
    """Numpy-vectorized variant of :func:`_build_context_seq`, returning
    ``ndarray[uint16]`` of length ``n_padded``.

    Fast-path preconditions (caller is expected to enforce or fall back):
      * ``len(qualities) == sum(read_lengths)``
      * ``len(revcomp_flags) == len(read_lengths)``

    The ring update for ``prev_q`` is sequential within a read but
    independent across reads. We iterate ``p = 0..max_len-1`` and update
    ``n_reads`` per-read states in parallel via numpy.
    """
    n = len(qualities)
    pad_ctx = m94z_context(0, 0, 0, qbits, pbits, sloc)
    if n_padded == 0:
        return np.zeros(0, dtype=np.uint16)
    n_reads = len(read_lengths)
    if n_reads == 0 or n == 0:
        return np.full(n_padded, pad_ctx, dtype=np.uint16)

    qmask = (1 << qbits) - 1
    pmask = (1 << pbits) - 1
    smask = (1 << sloc) - 1
    n_buckets = 1 << pbits
    shift = max(1, qbits // 3)
    shift_mask = (1 << shift) - 1

    read_lens = np.asarray(read_lengths, dtype=np.int64)
    revcomps = (np.asarray(revcomp_flags, dtype=np.int64) & 1)
    qual_arr = np.frombuffer(qualities, dtype=np.uint8)

    starts = np.empty(n_reads, dtype=np.int64)
    starts[0] = 0
    if n_reads > 1:
        np.cumsum(read_lens[:-1], out=starts[1:])

    contexts = np.full(n_padded, pad_ctx, dtype=np.uint16)
    revcomp_term = (revcomps & 1) << (qbits + pbits)
    prev_q = np.zeros(n_reads, dtype=np.int64)

    max_len = int(read_lens.max())
    denom = np.maximum(read_lens, 1)
    for p in range(max_len):
        active = read_lens > p
        if not active.any():
            break
        flat_pos = starts + p
        if p == 0:
            pb = np.zeros(n_reads, dtype=np.int64)
        else:
            pb = np.minimum(n_buckets - 1, (p * n_buckets) // denom)
        ctx_p = ((prev_q & qmask) | ((pb & pmask) << qbits) | revcomp_term) & smask
        active_flat = flat_pos[active]
        contexts[active_flat] = ctx_p[active].astype(np.uint16)
        sym_p = qual_arr[active_flat].astype(np.int64)
        prev_q[active] = ((prev_q[active] << shift) | (sym_p & shift_mask)) & qmask

    return contexts


def _vectorize_first_encounter(
    sparse_seq: np.ndarray,
    sloc: int,
) -> tuple[np.ndarray, list[int], int]:
    """Build (dense_seq, sparse_ids, n_active) from ``sparse_seq`` in
    encounter order — vectorized equivalent of the dict-based scalar pass
    in :func:`_encode_v3_native`.

    ``sparse_seq`` values are bounded by ``1 << sloc`` (the ``smask`` in
    :func:`m94z_context`); we exploit that to do a bounded scatter-min
    rather than a full ``np.unique``.
    """
    n_padded = int(sparse_seq.shape[0])
    if n_padded == 0:
        return np.zeros(0, dtype=np.uint16), [], 0

    n_buckets_total = 1 << sloc
    arr = sparse_seq.astype(np.int64, copy=False)

    first_idx_full = np.full(n_buckets_total, n_padded, dtype=np.int64)
    np.minimum.at(first_idx_full, arr, np.arange(n_padded, dtype=np.int64))
    seen_mask = first_idx_full < n_padded
    seen_vals = np.flatnonzero(seen_mask)
    first_idx = first_idx_full[seen_vals]
    order = np.argsort(first_idx, kind="stable")
    n_active = int(order.shape[0])
    if n_active > 0xFFFF:
        raise ValueError(
            f"M94Z V3: more than 65535 distinct contexts in input ({n_active})"
        )
    sparse_ids_arr = seen_vals[order]

    value_to_dense = np.full(n_buckets_total, 0xFFFF, dtype=np.uint16)
    value_to_dense[sparse_ids_arr] = np.arange(n_active, dtype=np.uint16)
    dense_seq = value_to_dense[arr]

    return dense_seq, sparse_ids_arr.tolist(), n_active


# ── Encoder / decoder core ──────────────────────────────────────────────

def _encode_one_step(x: int, f: int, c: int, out: bytearray) -> int:
    """Encode one symbol given pre-state x, frequency f, cum c.

    Pre-renormalises by emitting low-16-bit chunks, then applies the
    rANS encode formula. Returns the new state.

    Pre-conditions: ``L <= x < b*L``, ``1 <= f <= T-1``, ``0 <= c <= T-f``.
    Post-condition: ``L <= x_new < b*L``.
    """
    x_max = X_MAX_PREFACTOR * f  # exact, since T | b*L
    # Spec §2.1 says "while x_in >= x_max" emit; equivalent forms differ
    # by the strictness of comparison. Here `>=` is the canonical form —
    # at most one iteration since a single >>16 brings x below x_max for
    # our parameter range (proven §2.4).
    while x >= x_max:
        out.append(x & B_MASK)         # low 16 bits as one chunk
        x >>= B_BITS
    return (x // f) * T + (x % f) + c


def _decode_one_step(x: int, freq: list[int], cum: list[int],
                     stream: bytes, pos: int) -> tuple[int, int, int]:
    """Decode one symbol. Returns (sym, new_x, new_pos).

    Pre-condition: state ``x`` is the encoder's post-encode state for this
    symbol position. Post-condition: ``L <= new_x < b*L``.
    """
    slot = x & T_MASK  # x mod T (T is power of 2)
    # Find smallest s such that cum[s+1] > slot, i.e. cum[s] <= slot < cum[s+1].
    # `bisect_right(cum, slot, 1, 257)` gives the smallest index k where
    # cum[k] > slot; then sym = k - 1. We want bisect on cum[1:257] which
    # are the *upper boundaries*. Use bisect_right on cum[1:] is awkward;
    # instead use bisect_right(cum, slot) - 1.
    sym = bisect_right(cum, slot) - 1
    # Edge case: bisect_right on a 257-element list with slot in [0, T) and
    # cum[0]=0, cum[256]=T returns at least 1 (since slot >= 0 == cum[0]
    # only when slot == 0; bisect_right finds position AFTER equal elements).
    # If slot == 0 and freq[0] > 0: cum = [0, f0, ...], bisect_right finds
    # index 1 → sym = 0. ✓
    f = freq[sym]
    c = cum[sym]
    x = (x >> T_BITS) * f + slot - c
    while x < L:
        if pos + 1 >= len(stream):
            raise ValueError(
                f"M94Z: substream exhausted (pos={pos}, len={len(stream)})"
            )
        chunk = stream[pos] | (stream[pos + 1] << 8)
        pos += 2
        x = (x << B_BITS) | chunk
    return sym, x, pos


def _encode_body(
    qualities: bytes,
    contexts: list[int],
    n_padded: int,
    freq_per_ctx: dict[int, list[int]],
    cum_per_ctx: dict[int, list[int]],
) -> tuple[list[bytes], tuple[int, int, int, int], tuple[int, int, int, int]]:
    """Reverse-pass rANS encode of all symbols.

    Returns ``(stream_bytes_per_lane, state_init, state_final)``. Each
    stream's bytes are emit-order (encoder appended in reverse, then
    reversed here). Each pair of bytes is one 16-bit chunk in LE order.
    """
    state = [L, L, L, L]  # state_init = L
    state_init = (L, L, L, L)
    out = [bytearray() for _ in range(NUM_STREAMS)]

    symbols = bytearray(n_padded)
    symbols[:len(qualities)] = qualities  # padding symbols stay 0

    for i in range(n_padded - 1, -1, -1):
        s_idx = i & 3
        ctx = contexts[i]
        sym = symbols[i]
        f = freq_per_ctx[ctx][sym]
        c = cum_per_ctx[ctx][sym]
        if f == 0:
            # Should never happen — pass 1 counted this symbol so freq>0.
            raise AssertionError(
                f"M94Z encoder: ctx={ctx} sym={sym} has freq=0"
            )
        x = state[s_idx]
        x_max = X_MAX_PREFACTOR * f
        while x >= x_max:
            out[s_idx].append(x & 0xFF)
            out[s_idx].append((x >> 8) & 0xFF)
            x >>= B_BITS
        x = (x // f) * T + (x % f) + c
        state[s_idx] = x

    state_final = tuple(state)
    # Each lane was appended LIFO (LSB-of-chunk first, then MSB) in
    # reverse symbol order. Reverse the byte stream — but we must
    # reverse in 2-byte chunk units to keep each LE-pair intact.
    out_bytes: list[bytes] = []
    for s_idx in range(NUM_STREAMS):
        buf = out[s_idx]
        if len(buf) & 1:
            raise AssertionError("M94Z encoder produced odd-byte stream")
        # Convert appended (lo, hi) pairs back into chunks, reverse the
        # chunk list, then re-emit as (lo, hi) pairs.
        n_chunks = len(buf) // 2
        rebuilt = bytearray(len(buf))
        for k in range(n_chunks):
            lo = buf[2 * k]
            hi = buf[2 * k + 1]
            # Place chunk k from the end at chunk position (n_chunks-1-k).
            j = (n_chunks - 1 - k)
            rebuilt[2 * j] = lo
            rebuilt[2 * j + 1] = hi
        out_bytes.append(bytes(rebuilt))

    return out_bytes, state_init, state_final


def _decode_body(
    streams: list[bytes],
    state_final: tuple[int, int, int, int],
    state_init: tuple[int, int, int, int],
    n_padded: int,
    contexts: list[int],
    freq_per_ctx: dict[int, list[int]],
    cum_per_ctx: dict[int, list[int]],
) -> bytearray:
    """Forward-pass rANS decode."""
    state = list(state_final)
    pos = [0, 0, 0, 0]
    out = bytearray(n_padded)

    for i in range(n_padded):
        s_idx = i & 3
        ctx = contexts[i]
        freq = freq_per_ctx[ctx]
        cum = cum_per_ctx[ctx]
        sym, new_x, new_pos = _decode_one_step(
            state[s_idx], freq, cum, streams[s_idx], pos[s_idx],
        )
        out[i] = sym
        state[s_idx] = new_x
        pos[s_idx] = new_pos

    if tuple(state) != state_init:
        raise ValueError(
            f"M94Z: post-decode state {tuple(state)} != "
            f"state_init {state_init}; stream is corrupt"
        )
    return out


# ── Read-length sidecar ────────────────────────────────────────────────

def _encode_read_lengths(read_lengths: list[int]) -> bytes:
    """Encode read lengths as little-endian uint32s, deflate-compressed."""
    if not read_lengths:
        return zlib.compress(b"")
    buf = bytearray(4 * len(read_lengths))
    for i, ln in enumerate(read_lengths):
        struct.pack_into("<I", buf, 4 * i, ln & 0xFFFFFFFF)
    return zlib.compress(bytes(buf), level=6)


def _decode_read_lengths(encoded: bytes, num_reads: int) -> list[int]:
    raw = zlib.decompress(encoded)
    if num_reads == 0:
        if raw:
            raise ValueError("M94Z: read_length_table non-empty but num_reads=0")
        return []
    if len(raw) != 4 * num_reads:
        raise ValueError(
            f"M94Z: read_length_table raw length {len(raw)} != "
            f"{4 * num_reads}"
        )
    return [struct.unpack_from("<I", raw, 4 * i)[0] for i in range(num_reads)]


# ── Freq-table block (per-context) sidecar ──────────────────────────────

def _serialize_freq_tables(
    freq_per_ctx: dict[int, list[int]],
    sloc: int,
) -> bytes:
    """Serialize the (sparse) per-context freq tables.

    Layout:
        uint32 LE  num_contexts (active context count)
        for each active context (sorted ascending by ctx id):
            uint32 LE  ctx_id   (< 1<<sloc)
            uint16 LE * 256     freq[s] for s in 0..255
        --> the whole thing is then deflate-compressed by the caller.

    256 uint16 = 512 bytes per context. Compression should bring this
    down meaningfully since most contexts have near-zero freqs for most
    symbols.
    """
    buf = bytearray()
    active = sorted(freq_per_ctx.keys())
    buf += struct.pack("<I", len(active))
    smask = (1 << sloc) - 1
    for ctx in active:
        if ctx & ~smask != 0:
            raise AssertionError(f"M94Z: ctx {ctx} out of range for sloc={sloc}")
        buf += struct.pack("<I", ctx)
        freq = freq_per_ctx[ctx]
        # Pack 256 freqs as little-endian uint16.
        buf += struct.pack("<256H", *freq)
    return zlib.compress(bytes(buf), level=6)


def _deserialize_freq_tables(blob: bytes) -> dict[int, list[int]]:
    raw = zlib.decompress(blob)
    if len(raw) < 4:
        raise ValueError("M94Z: freq_tables blob too short")
    (n_active,) = struct.unpack_from("<I", raw, 0)
    cursor = 4
    expected = 4 + n_active * (4 + 256 * 2)
    if len(raw) != expected:
        raise ValueError(
            f"M94Z: freq_tables blob length {len(raw)} != expected {expected}"
        )
    out: dict[int, list[int]] = {}
    for _ in range(n_active):
        (ctx,) = struct.unpack_from("<I", raw, cursor)
        cursor += 4
        freq = list(struct.unpack_from("<256H", raw, cursor))
        cursor += 256 * 2
        out[ctx] = freq
    return out


# ── Top-level encode / decode ──────────────────────────────────────────

@dataclass(frozen=True)
class CodecHeader:
    """M94.Z header (fields packed by ``pack_codec_header``)."""
    flags: int
    num_qualities: int
    num_reads: int
    rlt_compressed_len: int
    read_length_table: bytes
    context_params: ContextParams
    freq_tables_compressed: bytes
    state_init: tuple[int, int, int, int]


HEADER_FIXED_PREFIX = 4 + 1 + 1 + 8 + 4 + 4 + CONTEXT_PARAMS_SIZE + 4
# magic(4) + version(1) + flags(1) + num_qualities(8) + num_reads(4)
# + rlt_compressed_len(4) + context_params(8) + freq_tables_len(4)
# = 34 bytes


def _pack_codec_header(h: CodecHeader) -> bytes:
    if len(h.read_length_table) != h.rlt_compressed_len:
        raise ValueError("rlt_compressed_len mismatch")
    out = bytearray()
    out += MAGIC
    out += struct.pack(
        "<BBQII",
        VERSION,
        h.flags & 0xFF,
        h.num_qualities,
        h.num_reads,
        h.rlt_compressed_len,
    )
    out += pack_context_params(h.context_params)
    out += struct.pack("<I", len(h.freq_tables_compressed))
    out += h.read_length_table
    out += h.freq_tables_compressed
    out += struct.pack(
        "<IIII",
        h.state_init[0] & 0xFFFFFFFF,
        h.state_init[1] & 0xFFFFFFFF,
        h.state_init[2] & 0xFFFFFFFF,
        h.state_init[3] & 0xFFFFFFFF,
    )
    return bytes(out)


def _pack_codec_header_v2(h: CodecHeader) -> bytes:
    """Pack a V2 (native-body) header.

    Same layout as V1 EXCEPT:
      * version byte = ``VERSION_V2_NATIVE`` (=2)
      * no 16-byte state_init suffix (V2 body embeds final states at its
        own offset 0..15).

    The ``state_init`` field on the input :class:`CodecHeader` is ignored
    for V2 (caller may pass any tuple).
    """
    if len(h.read_length_table) != h.rlt_compressed_len:
        raise ValueError("rlt_compressed_len mismatch")
    out = bytearray()
    out += MAGIC
    out += struct.pack(
        "<BBQII",
        VERSION_V2_NATIVE,
        h.flags & 0xFF,
        h.num_qualities,
        h.num_reads,
        h.rlt_compressed_len,
    )
    out += pack_context_params(h.context_params)
    out += struct.pack("<I", len(h.freq_tables_compressed))
    out += h.read_length_table
    out += h.freq_tables_compressed
    return bytes(out)


def _unpack_codec_header(blob: bytes) -> tuple[CodecHeader, int]:
    """Parse a V1 M94.Z header.

    Raises ``ValueError`` if the version byte is not 1. V2 streams must
    be parsed via :func:`_unpack_codec_header_v2`. Callers that don't
    know the version up front can peek ``blob[4]`` and dispatch.
    """
    if len(blob) < HEADER_FIXED_PREFIX:
        raise ValueError(f"M94Z header too short: {len(blob)} bytes")
    if blob[:4] != MAGIC:
        raise ValueError(f"M94Z bad magic: {blob[:4]!r}, expected {MAGIC!r}")
    version = blob[4]
    if version == VERSION_V2_NATIVE:
        raise ValueError(
            "M94Z V2 stream — call _unpack_codec_header_v2 instead"
        )
    if version != VERSION:
        raise ValueError(f"M94Z unsupported version: {version}")
    flags = blob[5]
    num_qualities, num_reads, rlt_len = struct.unpack_from("<QII", blob, 6)
    cursor = 22  # after magic+ver+flags+num_q+num_r+rlt_len
    ctx_params = unpack_context_params(blob, cursor)
    cursor += CONTEXT_PARAMS_SIZE
    (ft_len,) = struct.unpack_from("<I", blob, cursor)
    cursor += 4
    if len(blob) < cursor + rlt_len + ft_len + 16:
        raise ValueError("M94Z header truncated")
    rlt = blob[cursor:cursor + rlt_len]
    cursor += rlt_len
    freq_tables_blob = blob[cursor:cursor + ft_len]
    cursor += ft_len
    state_init = struct.unpack_from("<IIII", blob, cursor)
    cursor += 16
    header = CodecHeader(
        flags=flags,
        num_qualities=num_qualities,
        num_reads=num_reads,
        rlt_compressed_len=rlt_len,
        read_length_table=rlt,
        context_params=ctx_params,
        freq_tables_compressed=freq_tables_blob,
        state_init=state_init,
    )
    return header, cursor


def _unpack_codec_header_v2(blob: bytes) -> tuple[CodecHeader, int]:
    """Parse a V2 (native-body) M94.Z header.

    Returns ``(header, body_offset)`` where ``body_offset`` is the byte
    offset at which the native rANS payload begins. The returned
    :class:`CodecHeader` has ``state_init`` set to all-zero (V2 stores
    states inside the body itself).
    """
    if len(blob) < HEADER_FIXED_PREFIX:
        raise ValueError(f"M94Z header too short: {len(blob)} bytes")
    if blob[:4] != MAGIC:
        raise ValueError(f"M94Z bad magic: {blob[:4]!r}, expected {MAGIC!r}")
    version = blob[4]
    if version != VERSION_V2_NATIVE:
        raise ValueError(
            f"_unpack_codec_header_v2: expected version {VERSION_V2_NATIVE}, "
            f"got {version}"
        )
    flags = blob[5]
    num_qualities, num_reads, rlt_len = struct.unpack_from("<QII", blob, 6)
    cursor = 22
    ctx_params = unpack_context_params(blob, cursor)
    cursor += CONTEXT_PARAMS_SIZE
    (ft_len,) = struct.unpack_from("<I", blob, cursor)
    cursor += 4
    # V2: no 16-byte state_init suffix on the header itself.
    if len(blob) < cursor + rlt_len + ft_len:
        raise ValueError("M94Z V2 header truncated")
    rlt = blob[cursor:cursor + rlt_len]
    cursor += rlt_len
    freq_tables_blob = blob[cursor:cursor + ft_len]
    cursor += ft_len
    header = CodecHeader(
        flags=flags,
        num_qualities=num_qualities,
        num_reads=num_reads,
        rlt_compressed_len=rlt_len,
        read_length_table=rlt,
        context_params=ctx_params,
        freq_tables_compressed=freq_tables_blob,
        state_init=(0, 0, 0, 0),  # not used for V2
    )
    return header, cursor


# ── V3 (adaptive Range Coder) header — L2 / Task #82 Phase B.2 ──────────
#
# V3 wire format (spec 2026-05-01-l2-m94z-adaptive-design.md §5.1):
#   0   4    magic = "M94Z"
#   4   1    version = 3
#   5   1    flags (bits 4-5 = pad_count)
#   6   8    num_qualities (uint64 LE)
#   14  8    num_reads (uint64 LE)
#   22  4    rlt_compressed_len (uint32 LE)
#   26  8    context_params (qbits, pbits, dbits, sloc, 4 reserved)
#   34  2    max_sym (uint16 LE)
#   36  var  read_length_table (deflated)
#
# Body prelude (after header):
#   +0   4    n_active (uint32 LE)
#   +4   2*n  sparse_ids[n_active] (uint16 LE × n_active)
#
# Then RC body (from C kernel):
#   +0   16   lane_lengths (uint32 LE × 4)
#   +16  var  4 lane byte streams concatenated.

V3_HEADER_FIXED_PREFIX: int = 4 + 1 + 1 + 8 + 8 + 4 + CONTEXT_PARAMS_SIZE + 2
# magic(4) + version(1) + flags(1) + num_qualities(8) + num_reads(8)
# + rlt_compressed_len(4) + context_params(8) + max_sym(2) = 36 bytes


def _pack_codec_header_v3(
    flags: int,
    num_qualities: int,
    num_reads: int,
    rlt_compressed: bytes,
    context_params: ContextParams,
    max_sym: int,
) -> bytes:
    """Pack a V3 (adaptive RC) header.

    Differs from V1/V2:
      - version byte = 3 (``VERSION_V3_ADAPTIVE``)
      - num_reads is uint64 LE (was uint32 in V1/V2)
      - 2-byte ``max_sym`` field at offset 34 (no freq_tables_compressed_len)
      - no freq_tables blob (decoder rebuilds via adaptive update rules)
      - no state_init/state_final trailer (RC has none)
    """
    if not (1 <= max_sym <= 256):
        raise ValueError(
            f"M94Z V3: max_sym {max_sym} out of valid range [1, 256]"
        )
    out = bytearray()
    out += MAGIC
    out += struct.pack(
        "<BBQQI",
        VERSION_V3_ADAPTIVE,
        flags & 0xFF,
        num_qualities,
        num_reads,
        len(rlt_compressed),
    )
    out += pack_context_params(context_params)
    out += struct.pack("<H", max_sym & 0xFFFF)
    out += rlt_compressed
    return bytes(out)


def _unpack_codec_header_v3(
    blob: bytes,
) -> tuple[int, int, int, bytes, ContextParams, int, int]:
    """Parse a V3 header.

    Returns ``(flags, num_qualities, num_reads, read_length_table,
    context_params, max_sym, body_offset)``.
    """
    if len(blob) < V3_HEADER_FIXED_PREFIX:
        raise ValueError(
            f"M94Z V3 header too short: {len(blob)} bytes "
            f"(need {V3_HEADER_FIXED_PREFIX})"
        )
    if blob[:4] != MAGIC:
        raise ValueError(f"M94Z bad magic: {blob[:4]!r}, expected {MAGIC!r}")
    version = blob[4]
    if version != VERSION_V3_ADAPTIVE:
        raise ValueError(
            f"_unpack_codec_header_v3: expected version "
            f"{VERSION_V3_ADAPTIVE}, got {version}"
        )
    flags = blob[5]
    num_qualities, num_reads, rlt_len = struct.unpack_from("<QQI", blob, 6)
    cursor = 6 + 8 + 8 + 4  # = 26
    ctx_params = unpack_context_params(blob, cursor)
    cursor += CONTEXT_PARAMS_SIZE
    (max_sym,) = struct.unpack_from("<H", blob, cursor)
    cursor += 2
    if len(blob) < cursor + rlt_len:
        raise ValueError("M94Z V3 header truncated (rlt)")
    rlt = bytes(blob[cursor:cursor + rlt_len])
    cursor += rlt_len
    return flags, num_qualities, num_reads, rlt, ctx_params, max_sym, cursor


try:  # pragma: no cover — extension may be absent
    from ttio.codecs._fqzcomp_nx16_z import _fqzcomp_nx16_z as _ext
    _HAVE_C_EXTENSION = True
except ImportError:  # pragma: no cover
    _HAVE_C_EXTENSION = False
    _ext = None  # type: ignore[assignment]


# ── libttio_rans native library loader (Task 15) ────────────────────────
#
# Three-tier acceleration: native (libttio_rans via ctypes) → Cython
# (_fqzcomp_nx16_z) → pure Python. The native library implements the
# inner rANS hot loop with cpuid-dispatched scalar/SSE4.1/AVX2 kernels.
#
# IMPORTANT scope limits:
#   * The native library produces a SELF-CONTAINED V2 byte format with
#     embedded lane sizes that DOES NOT match the V1 wire format used by
#     the Cython / pure-Python paths. So we cannot simply swap the native
#     entrypoints into the V1 encode/decode dispatch — V1 streams remain
#     canonical and continue to flow through Cython/pure-Python.
#   * What this module currently exposes from the native lib:
#       - the loader (_HAVE_NATIVE_LIB flag, _native_lib handle)
#       - ctypes argtype/restype configuration for the public C API
#       - thin _encode_via_native / _decode_via_native helpers for callers
#         that want to use the V2 native path explicitly
#       - get_backend_name() introspection
#   * Wiring native acceleration into a V2-aware top-level dispatch is a
#     follow-on task once Task 14's V2 encoder/decoder is plumbed through
#     the Python wire layer.

import array  # noqa: E402
import ctypes  # noqa: E402  (kept here so lib loader stays close to flag)
import ctypes.util  # noqa: E402
import os  # noqa: E402

_native_lib = None


def _load_native_lib():
    """Locate and dlopen libttio_rans (.so/.dylib/.dll).

    Search order:
      1. $TTIO_RANS_LIB_PATH (full path or directory containing the lib)
      2. Bare names — letting the dynamic loader use LD_LIBRARY_PATH /
         DYLD_LIBRARY_PATH / PATH (Windows) / RPATH.
      3. ctypes.util.find_library("ttio_rans") as a last resort.

    Returns the CDLL handle on success, ``None`` on failure (caller
    treats absence as "no native acceleration available").
    """
    global _native_lib
    if _native_lib is not None:
        return _native_lib

    candidates: list[str] = []

    env_path = os.environ.get("TTIO_RANS_LIB_PATH")
    if env_path:
        if os.path.isdir(env_path):
            for name in (
                "libttio_rans.so",
                "libttio_rans.dylib",
                "ttio_rans.dll",
                "libttio_rans.dll",
            ):
                candidates.append(os.path.join(env_path, name))
        else:
            candidates.append(env_path)

    candidates.extend([
        "libttio_rans.so",
        "libttio_rans.dylib",
        "ttio_rans.dll",
        "libttio_rans.dll",
    ])

    for name in candidates:
        try:
            _native_lib = ctypes.CDLL(name)
            return _native_lib
        except OSError:
            continue

    path = ctypes.util.find_library("ttio_rans")
    if path:
        try:
            _native_lib = ctypes.CDLL(path)
            return _native_lib
        except OSError:
            pass
    return None


_HAVE_NATIVE_LIB = _load_native_lib() is not None

if _HAVE_NATIVE_LIB:
    _lib = _native_lib

    # int ttio_rans_encode_block(
    #     const uint8_t  *symbols,
    #     const uint16_t *contexts,
    #     size_t          n_symbols,
    #     uint16_t        n_contexts,
    #     const uint32_t (*freq)[256],
    #     uint8_t        *out,
    #     size_t         *out_len);
    _lib.ttio_rans_encode_block.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.POINTER(ctypes.c_uint16),
        ctypes.c_size_t,
        ctypes.c_uint16,
        ctypes.POINTER(ctypes.c_uint32),
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.POINTER(ctypes.c_size_t),
    ]
    _lib.ttio_rans_encode_block.restype = ctypes.c_int

    # int ttio_rans_decode_block(
    #     const uint8_t  *compressed,
    #     size_t          comp_len,
    #     const uint16_t *contexts,
    #     uint16_t        n_contexts,
    #     const uint32_t (*freq)[256],
    #     const uint32_t (*cum)[256],
    #     const uint8_t  (*dtab)[TTIO_RANS_T],
    #     uint8_t        *symbols,
    #     size_t          n_symbols);
    _lib.ttio_rans_decode_block.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_uint16),
        ctypes.c_uint16,
        ctypes.POINTER(ctypes.c_uint32),
        ctypes.POINTER(ctypes.c_uint32),
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
    ]
    _lib.ttio_rans_decode_block.restype = ctypes.c_int

    # int ttio_rans_build_decode_table(
    #     uint16_t        n_contexts,
    #     const uint32_t (*freq)[256],
    #     const uint32_t (*cum)[256],
    #     uint8_t        (*dtab)[TTIO_RANS_T]);
    _lib.ttio_rans_build_decode_table.argtypes = [
        ctypes.c_uint16,
        ctypes.POINTER(ctypes.c_uint32),
        ctypes.POINTER(ctypes.c_uint32),
        ctypes.POINTER(ctypes.c_uint8),
    ]
    _lib.ttio_rans_build_decode_table.restype = ctypes.c_int

    # ttio_rans_pool *ttio_rans_pool_create(int n_threads);
    _lib.ttio_rans_pool_create.argtypes = [ctypes.c_int]
    _lib.ttio_rans_pool_create.restype = ctypes.c_void_p

    # void ttio_rans_pool_destroy(ttio_rans_pool *pool);
    _lib.ttio_rans_pool_destroy.argtypes = [ctypes.c_void_p]
    _lib.ttio_rans_pool_destroy.restype = None

    # int ttio_rans_encode_mt(
    #     ttio_rans_pool *pool,
    #     const uint8_t  *symbols,
    #     const uint16_t *contexts,
    #     size_t          n_symbols,
    #     uint16_t        n_contexts,
    #     size_t          reads_per_block,
    #     const size_t   *read_lengths,
    #     size_t          n_reads,
    #     uint8_t        *out,
    #     size_t         *out_len);
    _lib.ttio_rans_encode_mt.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.POINTER(ctypes.c_uint16),
        ctypes.c_size_t,
        ctypes.c_uint16,
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_size_t),
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.POINTER(ctypes.c_size_t),
    ]
    _lib.ttio_rans_encode_mt.restype = ctypes.c_int

    # int ttio_rans_decode_mt(
    #     ttio_rans_pool *pool,
    #     const uint8_t  *compressed,
    #     size_t          comp_len,
    #     uint8_t        *symbols,
    #     size_t         *n_symbols);
    _lib.ttio_rans_decode_mt.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.POINTER(ctypes.c_size_t),
    ]
    _lib.ttio_rans_decode_mt.restype = ctypes.c_int

    # const char *ttio_rans_kernel_name(void);
    _lib.ttio_rans_kernel_name.argtypes = []
    _lib.ttio_rans_kernel_name.restype = ctypes.c_char_p

    # ttio_rans_context_resolver: uint16_t (*)(void *user_data, size_t i, uint8_t prev_sym)
    _TTIORansContextResolver = ctypes.CFUNCTYPE(
        ctypes.c_uint16,        # return: context
        ctypes.c_void_p,        # user_data
        ctypes.c_size_t,        # i
        ctypes.c_uint8,         # prev_sym
    )

    # int ttio_rans_decode_block_streaming(
    #     const uint8_t              *compressed,
    #     size_t                      comp_len,
    #     uint16_t                    n_contexts,
    #     const uint32_t            (*freq)[256],
    #     const uint32_t            (*cum)[256],
    #     const uint8_t             (*dtab)[TTIO_RANS_T],
    #     uint8_t                    *symbols,
    #     size_t                      n_symbols,
    #     ttio_rans_context_resolver  resolver,
    #     void                       *user_data);
    _lib.ttio_rans_decode_block_streaming.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),     # compressed
        ctypes.c_size_t,                     # comp_len
        ctypes.c_uint16,                     # n_contexts
        ctypes.POINTER(ctypes.c_uint32),    # freq[n_contexts][256] flat
        ctypes.POINTER(ctypes.c_uint32),    # cum[n_contexts][256] flat
        ctypes.POINTER(ctypes.c_uint8),     # dtab[n_contexts][T] flat
        ctypes.POINTER(ctypes.c_uint8),     # symbols
        ctypes.c_size_t,                     # n_symbols
        _TTIORansContextResolver,            # resolver
        ctypes.c_void_p,                     # user_data
    ]
    _lib.ttio_rans_decode_block_streaming.restype = ctypes.c_int

    class _TTIOM94ZParams(ctypes.Structure):
        _fields_ = [
            ("qbits", ctypes.c_uint32),
            ("pbits", ctypes.c_uint32),
            ("sloc",  ctypes.c_uint32),
        ]

    # int ttio_rans_decode_block_m94z(
    #     const uint8_t  *compressed, size_t comp_len,
    #     uint16_t n_contexts,
    #     const uint32_t (*freq)[256], const uint32_t (*cum)[256],
    #     const uint8_t (*dtab)[TTIO_RANS_T],
    #     const ttio_m94z_params *params, const uint16_t *ctx_remap,
    #     const uint32_t *read_lengths, size_t n_reads,
    #     const uint8_t *revcomp_flags,
    #     uint16_t pad_ctx_dense,
    #     uint8_t *symbols, size_t n_symbols);
    _lib.ttio_rans_decode_block_m94z.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),     # compressed
        ctypes.c_size_t,                     # comp_len
        ctypes.c_uint16,                     # n_contexts
        ctypes.POINTER(ctypes.c_uint32),    # freq[n_contexts][256] flat
        ctypes.POINTER(ctypes.c_uint32),    # cum[n_contexts][256] flat
        ctypes.POINTER(ctypes.c_uint8),     # dtab[n_contexts][T] flat
        ctypes.POINTER(_TTIOM94ZParams),    # params
        ctypes.POINTER(ctypes.c_uint16),    # ctx_remap (sparse->dense)
        ctypes.POINTER(ctypes.c_uint32),    # read_lengths
        ctypes.c_size_t,                     # n_reads
        ctypes.POINTER(ctypes.c_uint8),     # revcomp_flags
        ctypes.c_uint16,                     # pad_ctx_dense
        ctypes.POINTER(ctypes.c_uint8),     # symbols
        ctypes.c_size_t,                     # n_symbols
    ]
    _lib.ttio_rans_decode_block_m94z.restype = ctypes.c_int

    # ── L2 adaptive (V3) bindings — Task #82 Phase B.2 ──────────────────
    # int ttio_rans_encode_block_adaptive(
    #     const uint8_t *symbols, const uint16_t *contexts,
    #     size_t n_symbols, uint16_t n_contexts, uint16_t max_sym,
    #     uint8_t *out, size_t *out_len);
    _lib.ttio_rans_encode_block_adaptive.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.POINTER(ctypes.c_uint16),
        ctypes.c_size_t,
        ctypes.c_uint16,
        ctypes.c_uint16,
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.POINTER(ctypes.c_size_t),
    ]
    _lib.ttio_rans_encode_block_adaptive.restype = ctypes.c_int

    # int ttio_rans_decode_block_adaptive_m94z(
    #     const uint8_t *compressed, size_t comp_len,
    #     uint16_t n_contexts, uint16_t max_sym,
    #     const ttio_m94z_params *params, const uint16_t *ctx_remap,
    #     const uint32_t *read_lengths, size_t n_reads,
    #     const uint8_t *revcomp_flags, uint16_t pad_ctx_dense,
    #     uint8_t *symbols, size_t n_symbols);
    _lib.ttio_rans_decode_block_adaptive_m94z.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
        ctypes.c_uint16,
        ctypes.c_uint16,
        ctypes.POINTER(_TTIOM94ZParams),
        ctypes.POINTER(ctypes.c_uint16),
        ctypes.POINTER(ctypes.c_uint32),
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_uint16,
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
    ]
    _lib.ttio_rans_decode_block_adaptive_m94z.restype = ctypes.c_int

    # ── L2.X V4 (CRAM 3.1 fqzcomp_qual) bindings — Stage 2 Task 11 ──────
    # int ttio_m94z_v4_encode(
    #     const uint8_t  *qual_in, size_t n_qualities,
    #     const uint32_t *read_lengths, size_t n_reads,
    #     const uint8_t  *flags,
    #     int             strategy_hint,
    #     uint8_t         pad_count,
    #     uint8_t        *out, size_t *out_len);
    _lib.ttio_m94z_v4_encode.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),     # qual_in
        ctypes.c_size_t,                     # n_qualities
        ctypes.POINTER(ctypes.c_uint32),    # read_lengths
        ctypes.c_size_t,                     # n_reads
        ctypes.POINTER(ctypes.c_uint8),     # flags
        ctypes.c_int,                        # strategy_hint
        ctypes.c_uint8,                      # pad_count
        ctypes.POINTER(ctypes.c_uint8),     # out
        ctypes.POINTER(ctypes.c_size_t),    # out_len
    ]
    _lib.ttio_m94z_v4_encode.restype = ctypes.c_int

    # int ttio_m94z_v4_decode(
    #     const uint8_t  *in, size_t in_len,
    #     uint32_t       *read_lengths, size_t n_reads,
    #     const uint8_t  *flags,
    #     uint8_t        *out_qual, size_t n_qualities);
    _lib.ttio_m94z_v4_decode.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),     # in
        ctypes.c_size_t,                     # in_len
        ctypes.POINTER(ctypes.c_uint32),    # read_lengths (out)
        ctypes.c_size_t,                     # n_reads
        ctypes.POINTER(ctypes.c_uint8),     # flags
        ctypes.POINTER(ctypes.c_uint8),     # out_qual
        ctypes.c_size_t,                     # n_qualities
    ]
    _lib.ttio_m94z_v4_decode.restype = ctypes.c_int
else:
    _lib = None
    _TTIORansContextResolver = None
    _TTIOM94ZParams = None


def _native_kernel_name() -> str:
    """Return the native kernel name (``"scalar"``/``"sse4.1"``/``"avx2"``).

    Returns the empty string when the native library is not available.
    """
    if not _HAVE_NATIVE_LIB:
        return ""
    raw = _lib.ttio_rans_kernel_name()
    if raw is None:
        return ""
    return raw.decode("ascii", errors="replace")


def get_backend_name() -> str:
    """Return the active inner-loop backend.

    One of:
        ``"native-<kernel>"``  e.g. ``"native-avx2"``  (libttio_rans available)
        ``"cython"``           (Cython extension available)
        ``"pure-python"``      (fallback)

    Selection precedence is determined at module-import time. Note that
    the V1 M94.Z encode/decode top-level functions currently always
    dispatch via Cython/pure-Python regardless of native availability —
    this introspector just reports the *highest tier loaded*. A V2-aware
    encode/decode dispatch will use the native path in a follow-on task.
    """
    if _HAVE_NATIVE_LIB:
        kernel = _native_kernel_name() or "unknown"
        return f"native-{kernel}"
    if _HAVE_C_EXTENSION:
        return "cython"
    return "pure-python"


def _encode_via_native(
    symbols: bytes,
    contexts,  # iterable of uint16
    freq_table,  # 2D sequence shape (n_contexts, 256)
) -> bytes:
    """Encode a single block via libttio_rans (V2 byte format).

    ``freq_table`` rows must each sum to ``T = 4096`` (caller's
    responsibility — same invariant as V1).

    Returns the V2 self-contained byte stream produced by
    :c:func:`ttio_rans_encode_block`. Note: this byte stream is NOT
    interchangeable with V1 wire-format bodies; it is consumed only by
    :func:`_decode_via_native` (or the higher-level V2 container).

    Raises ``RuntimeError`` if the native library is unavailable or the
    C call returns a non-zero status code.
    """
    if not _HAVE_NATIVE_LIB:
        raise RuntimeError(
            "_encode_via_native called but libttio_rans is not available"
        )
    n_symbols = len(symbols)
    n_contexts = len(freq_table)
    if n_contexts == 0 or n_contexts > 0xFFFF:
        raise ValueError(
            f"n_contexts ({n_contexts}) must be in [1, 65535]"
        )

    sym_buf = (ctypes.c_uint8 * n_symbols).from_buffer_copy(bytes(symbols))
    # Bulk-marshal contexts via array.array (avoids per-element Python overhead)
    _ctx_arr = array.array('H', contexts)  # uint16
    ctx_buf = (ctypes.c_uint16 * n_symbols).from_buffer(_ctx_arr)

    # Bulk-marshal freq table: flatten all rows into one array.array, then
    # share its buffer with the ctypes array (single bulk copy, no per-element loop)
    _freq_arr = array.array('I')  # uint32
    for c in range(n_contexts):
        _freq_arr.extend(freq_table[c])
    freq_flat = (ctypes.c_uint32 * (n_contexts * 256)).from_buffer(_freq_arr)

    out_cap = max(64, n_symbols * 4 + 64)
    out_buf = (ctypes.c_uint8 * out_cap)()
    out_len = ctypes.c_size_t(out_cap)

    rc = _lib.ttio_rans_encode_block(
        sym_buf,
        ctx_buf,
        ctypes.c_size_t(n_symbols),
        ctypes.c_uint16(n_contexts),
        freq_flat,
        out_buf,
        ctypes.byref(out_len),
    )
    if rc != 0:
        raise RuntimeError(f"ttio_rans_encode_block failed: rc={rc}")
    return bytes(out_buf[:out_len.value])


def _decode_via_native(
    compressed: bytes,
    contexts,  # iterable of uint16, length == n_symbols
    freq_table,  # 2D sequence (n_contexts, 256)
    cum_table,  # 2D sequence (n_contexts, 256), or None to derive
    n_symbols: int,
) -> bytes:
    """Decode a native V2 block via libttio_rans.

    If ``cum_table`` is None, derives cumulative tables from
    ``freq_table``. Builds the dtab via
    :c:func:`ttio_rans_build_decode_table` and then calls
    :c:func:`ttio_rans_decode_block`.

    Raises ``RuntimeError`` if the native library is unavailable or any
    C call returns a non-zero status code.
    """
    if not _HAVE_NATIVE_LIB:
        raise RuntimeError(
            "_decode_via_native called but libttio_rans is not available"
        )
    n_contexts = len(freq_table)
    if n_contexts == 0 or n_contexts > 0xFFFF:
        raise ValueError(
            f"n_contexts ({n_contexts}) must be in [1, 65535]"
        )

    # Bulk-marshal freq and cum tables via array.array to avoid per-element Python overhead
    _freq_arr = array.array('I')  # uint32
    _cum_arr = array.array('I')   # uint32
    if cum_table is not None:
        for c in range(n_contexts):
            _freq_arr.extend(freq_table[c])
            _cum_arr.extend(cum_table[c])
    else:
        for c in range(n_contexts):
            frow = freq_table[c]
            _freq_arr.extend(frow)
            running = 0
            for val in frow:
                _cum_arr.append(running)
                running += val
    freq_flat = (ctypes.c_uint32 * (n_contexts * 256)).from_buffer(_freq_arr)
    cum_flat = (ctypes.c_uint32 * (n_contexts * 256)).from_buffer(_cum_arr)

    dtab = (ctypes.c_uint8 * (n_contexts * T))()
    rc = _lib.ttio_rans_build_decode_table(
        ctypes.c_uint16(n_contexts),
        freq_flat,
        cum_flat,
        dtab,
    )
    if rc != 0:
        raise RuntimeError(f"ttio_rans_build_decode_table failed: rc={rc}")

    comp_buf = (ctypes.c_uint8 * len(compressed)).from_buffer_copy(bytes(compressed))
    # Bulk-marshal contexts via array.array buffer protocol
    _ctx_arr = array.array('H', contexts)  # uint16
    ctx_buf = (ctypes.c_uint16 * n_symbols).from_buffer(_ctx_arr)
    sym_buf = (ctypes.c_uint8 * n_symbols)()

    rc = _lib.ttio_rans_decode_block(
        comp_buf,
        ctypes.c_size_t(len(compressed)),
        ctx_buf,
        ctypes.c_uint16(n_contexts),
        freq_flat,
        cum_flat,
        dtab,
        sym_buf,
        ctypes.c_size_t(n_symbols),
    )
    if rc != 0:
        raise RuntimeError(f"ttio_rans_decode_block failed: rc={rc}")
    return bytes(sym_buf)


def _pack_wire_format(
    qualities_len: int,
    read_lengths: list[int],
    pad_count: int,
    streams: list[bytes],
    state_init: tuple[int, int, int, int],
    state_final: tuple[int, int, int, int],
    freq_tables_compressed: bytes,
    context_params: ContextParams,
) -> bytes:
    rlt = _encode_read_lengths(read_lengths)
    flags = (pad_count & 0x3) << 4
    header_bytes = _pack_codec_header(CodecHeader(
        flags=flags,
        num_qualities=qualities_len,
        num_reads=len(read_lengths),
        rlt_compressed_len=len(rlt),
        read_length_table=rlt,
        context_params=context_params,
        freq_tables_compressed=freq_tables_compressed,
        state_init=state_init,
    ))
    body = bytearray()
    for s_idx in range(NUM_STREAMS):
        body += struct.pack("<I", len(streams[s_idx]))
    for s_idx in range(NUM_STREAMS):
        body += streams[s_idx]
    trailer = struct.pack(
        "<IIII",
        state_final[0] & 0xFFFFFFFF,
        state_final[1] & 0xFFFFFFFF,
        state_final[2] & 0xFFFFFFFF,
        state_final[3] & 0xFFFFFFFF,
    )
    return header_bytes + bytes(body) + trailer


def _serialize_freq_tables_from_arrays(
    active_ctxs: list[int],
    freq_arrays: list[bytes],
    sloc: int,
) -> bytes:
    """Serialize freq tables given pre-built active_ctxs + 512-byte arrays.

    Mirrors :func:`_serialize_freq_tables` but skips the dict round-trip
    when called from the Cython encode path (active_ctxs already sorted
    ascending, freq_arrays already in 256-LE-uint16 form).
    """
    smask = (1 << sloc) - 1
    buf = bytearray()
    buf += struct.pack("<I", len(active_ctxs))
    for ctx, farr in zip(active_ctxs, freq_arrays):
        if ctx & ~smask != 0:
            raise AssertionError(f"M94Z: ctx {ctx} out of range for sloc={sloc}")
        buf += struct.pack("<I", ctx)
        if len(farr) != 512:
            raise AssertionError(
                f"M94Z: freq_array length {len(farr)} != 512"
            )
        buf += farr
    return zlib.compress(bytes(buf), level=6)


def _deserialize_freq_tables_to_arrays(
    blob: bytes,
) -> tuple[list[int], list[bytes]]:
    """Parse freq_tables blob into (active_ctxs, freq_arrays) parallel lists.

    Mirrors :func:`_deserialize_freq_tables` but returns raw 512-byte
    arrays so the Cython decode path can ingest them directly.
    """
    raw = zlib.decompress(blob)
    if len(raw) < 4:
        raise ValueError("M94Z: freq_tables blob too short")
    (n_active,) = struct.unpack_from("<I", raw, 0)
    cursor = 4
    expected = 4 + n_active * (4 + 256 * 2)
    if len(raw) != expected:
        raise ValueError(
            f"M94Z: freq_tables blob length {len(raw)} != expected {expected}"
        )
    active: list[int] = []
    arrays: list[bytes] = []
    for _ in range(n_active):
        (ctx,) = struct.unpack_from("<I", raw, cursor)
        cursor += 4
        active.append(ctx)
        arrays.append(bytes(raw[cursor:cursor + 512]))
        cursor += 512
    return active, arrays


def _encode_v2_native(
    qualities: bytes,
    read_lengths: list[int],
    revcomp_flags: list[int],
    context_params: ContextParams,
    n: int,
    n_padded: int,
    pad_count: int,
) -> bytes:
    """V2 (libttio_rans-format) encode dispatch.

    Builds context sequence + per-context freq tables (same as V1),
    then remaps sparse context IDs to a dense [0, n_active) range so
    the native encoder's freq table is compact, calls
    :func:`_encode_via_native`, and packs a V2 wire-format header
    plus the native body. The freq_tables blob still uses ORIGINAL
    (sparse) context IDs so V2 decode can reconstruct contexts using
    the unchanged M94.Z context model.
    """
    # Pass 1: build per-context counts and the context sequence.
    contexts = _build_context_seq(
        qualities, read_lengths, revcomp_flags, n_padded,
        context_params.qbits, context_params.pbits, context_params.sloc,
    )

    raw_counts: dict[int, list[int]] = {}
    symbols = bytearray(n_padded)
    symbols[:n] = qualities  # padding stays 0
    for i in range(n_padded):
        ctx = contexts[i]
        sym = symbols[i]
        if ctx not in raw_counts:
            raw_counts[ctx] = [0] * 256
        raw_counts[ctx][sym] += 1

    # Normalise to T per context.
    freq_per_ctx: dict[int, list[int]] = {}
    for ctx, rc in raw_counts.items():
        freq_per_ctx[ctx] = normalise_to_total(rc, T)

    # Remap sparse ctx IDs → dense [0, n_active) for the native call.
    active_ctxs = sorted(freq_per_ctx.keys())
    ctx_remap = {old: new for new, old in enumerate(active_ctxs)}
    dense_contexts = [ctx_remap[c] for c in contexts]
    dense_freq = [freq_per_ctx[c] for c in active_ctxs]

    # Native encode (V2 byte format).
    native_body = _encode_via_native(bytes(symbols), dense_contexts, dense_freq)

    # Wire format.
    rlt = _encode_read_lengths(read_lengths)
    freq_tables_blob = _serialize_freq_tables(freq_per_ctx, context_params.sloc)
    flags = (pad_count & 0x3) << 4

    header_bytes = _pack_codec_header_v2(CodecHeader(
        flags=flags,
        num_qualities=n,
        num_reads=len(read_lengths),
        rlt_compressed_len=len(rlt),
        read_length_table=rlt,
        context_params=context_params,
        freq_tables_compressed=freq_tables_blob,
        state_init=(0, 0, 0, 0),  # not used in V2
    ))
    return header_bytes + native_body


# ── V3 adaptive RC encode / decode (L2, Task #82 Phase B.2) ─────────────


def _encode_v3_native(
    qualities: bytes,
    read_lengths: list[int],
    revcomp_flags: list[int],
    context_params: ContextParams,
    n: int,
    n_padded: int,
    pad_count: int,
) -> bytes:
    """V3 (adaptive RC) encode.

    Single-pass encoder:
      1. Build sparse context sequence via :func:`_build_context_seq`.
      2. Walk symbols once, assigning dense ids to sparse ctxs in
         first-encounter order (parallel to the C kernel's slab indexing).
      3. Compute ``max_sym`` from the actual symbol byte range.
      4. Call ``ttio_rans_encode_block_adaptive`` to produce the RC body.
      5. Pack header || body prelude || body.

    The body prelude carries ``n_active`` + ``sparse_ids[]`` so the
    decoder can rebuild the same dense-id mapping.
    """
    if not _HAVE_NATIVE_LIB:
        raise RuntimeError(
            "_encode_v3_native called but libttio_rans is not available"
        )

    fast_path = (
        len(qualities) == sum(read_lengths)
        and len(revcomp_flags) == len(read_lengths)
    )
    if fast_path:
        sparse_seq_arr = _build_context_seq_arr_vec(
            qualities, read_lengths, revcomp_flags, n_padded,
            context_params.qbits, context_params.pbits, context_params.sloc,
        )
    else:
        sparse_seq_list = _build_context_seq(
            qualities, read_lengths, revcomp_flags, n_padded,
            context_params.qbits, context_params.pbits, context_params.sloc,
        )
        sparse_seq_arr = np.asarray(sparse_seq_list, dtype=np.int64)

    # Symbol buffer: padding stays 0 (the C kernel encodes pad bytes in the
    # pad context; the decoder mirrors lockstep).
    sym_arr = np.zeros(n_padded, dtype=np.uint8)
    if n > 0:
        sym_arr[:n] = np.frombuffer(qualities, dtype=np.uint8)

    # First-encounter pass — vectorized.
    dense_seq_arr, sparse_ids, n_active = _vectorize_first_encounter(
        sparse_seq_arr, context_params.sloc,
    )
    if n_active == 0:
        # Empty input — n_padded == 0; treat as a degenerate encode with
        # n_contexts = 1, max_sym = 1 to keep the C entry happy.
        n_active = 1
        sparse_ids = [m94z_context(
            0, 0, 0,
            context_params.qbits, context_params.pbits, context_params.sloc,
        )]

    # max_sym = max byte in input + 1, clamped to [1, 256].
    if n_padded == 0:
        max_sym = 1
    else:
        max_sym = int(sym_arr.max()) + 1
        if max_sym < 1:
            max_sym = 1
        if max_sym > 256:
            max_sym = 256

    # Marshal symbols + dense contexts (zero-copy ctypes views over the
    # numpy buffers).
    sym_buf = (ctypes.c_uint8 * n_padded).from_buffer(sym_arr)
    ctx_buf = (ctypes.c_uint16 * n_padded).from_buffer(dense_seq_arr)

    # Output capacity: 16-byte lane header + ~ N bytes for RC body. RC is
    # bounded above by entropy plus a flush; budget 2 bytes per symbol +
    # 64 byte slack.
    out_cap = 16 + n_padded * 2 + 64
    out_buf = (ctypes.c_uint8 * out_cap)()
    out_len = ctypes.c_size_t(out_cap)

    rc = _lib.ttio_rans_encode_block_adaptive(
        sym_buf,
        ctx_buf,
        ctypes.c_size_t(n_padded),
        ctypes.c_uint16(n_active),
        ctypes.c_uint16(max_sym),
        out_buf,
        ctypes.byref(out_len),
    )
    if rc != 0:
        raise RuntimeError(
            f"ttio_rans_encode_block_adaptive failed: rc={rc}"
        )
    rc_body = bytes(out_buf[:out_len.value])

    # Pack wire format.
    rlt = _encode_read_lengths(read_lengths)
    flags = (pad_count & 0x3) << 4
    header_bytes = _pack_codec_header_v3(
        flags=flags,
        num_qualities=n,
        num_reads=len(read_lengths),
        rlt_compressed=rlt,
        context_params=context_params,
        max_sym=max_sym,
    )
    # Body prelude: n_active (u32 LE) + sparse_ids[] (u16 LE × n_active).
    prelude = bytearray(4 + 2 * n_active)
    struct.pack_into("<I", prelude, 0, n_active)
    sid_arr = array.array('H', sparse_ids)
    prelude[4:4 + 2 * n_active] = sid_arr.tobytes()
    return header_bytes + bytes(prelude) + rc_body


def _decode_v3_via_native(
    encoded: bytes,
    revcomp_flags: list[int] | None,
) -> tuple[bytes, list[int], list[int]]:
    """Decode a V3 (adaptive RC) M94.Z blob.

    Pipeline:
      1. Parse V3 header (read_lengths + max_sym + ContextParams).
      2. Parse body prelude (n_active + sparse_ids).
      3. Build ``ctx_remap[1 << sloc]`` of uint16 with 0xFFFF default
         and fill ``ctx_remap[sparse_ids[i]] = i``.
      4. Call ``ttio_rans_decode_block_adaptive_m94z`` with the RC
         body bytes (i.e. encoded[body_off + prelude_len :]).
    """
    if not _HAVE_NATIVE_LIB:
        raise RuntimeError(
            "_decode_v3_via_native called but libttio_rans is not available"
        )

    (flags, num_qualities, num_reads, rlt, ctx_params, max_sym,
     body_off) = _unpack_codec_header_v3(encoded)
    pad_count = (flags >> 4) & 0x3
    read_lengths = _decode_read_lengths(rlt, num_reads)

    if revcomp_flags is None:
        revcomp_flags = [0] * num_reads
    elif len(revcomp_flags) != num_reads:
        raise ValueError(
            f"revcomp_flags length {len(revcomp_flags)} != "
            f"num_reads {num_reads}"
        )

    n_padded = num_qualities + pad_count
    if (n_padded & 3) != 0:
        raise ValueError(
            f"M94Z V3: n_padded {n_padded} not a multiple of 4"
        )

    # Parse body prelude.
    if len(encoded) < body_off + 4:
        raise ValueError("M94Z V3: body prelude truncated (n_active)")
    (n_active,) = struct.unpack_from("<I", encoded, body_off)
    pre_off = body_off + 4
    if n_active > 0xFFFF:
        raise ValueError(f"M94Z V3: n_active {n_active} exceeds 65535")
    if len(encoded) < pre_off + 2 * n_active:
        raise ValueError("M94Z V3: body prelude truncated (sparse_ids)")
    sparse_ids = list(struct.unpack_from(f"<{n_active}H", encoded, pre_off))
    pre_off += 2 * n_active

    # Build ctx_remap (size 1 << sloc, uint16, 0xFFFF default).
    sloc = ctx_params.sloc
    ctx_cap = 1 << sloc
    remap = array.array('H', [0xFFFF] * ctx_cap)
    for dense, sparse in enumerate(sparse_ids):
        if sparse >= ctx_cap:
            raise ValueError(
                f"M94Z V3: sparse_id {sparse} >= {ctx_cap} (sloc={sloc})"
            )
        remap[sparse] = dense
    remap_buf = (ctypes.c_uint16 * ctx_cap).from_buffer(remap)

    pad_ctx_sparse = m94z_context(
        0, 0, 0, ctx_params.qbits, ctx_params.pbits, ctx_params.sloc,
    )
    pad_ctx_dense_val = remap[pad_ctx_sparse]
    if pad_ctx_dense_val == 0xFFFF:
        # Pad ctx not in active set — fall back to dense 0 (matches the
        # V2 streaming convention).
        pad_ctx_dense_val = 0

    # Read length / revcomp arrays.
    if num_reads:
        _rl = array.array('I', read_lengths)
        _rc = array.array('B', [v & 1 for v in revcomp_flags])
        rl_buf = (ctypes.c_uint32 * num_reads).from_buffer(_rl)
        rc_buf = (ctypes.c_uint8 * num_reads).from_buffer(_rc)
    else:
        rl_buf = None
        rc_buf = None

    params = _TTIOM94ZParams(
        qbits=ctx_params.qbits,
        pbits=ctx_params.pbits,
        sloc=ctx_params.sloc,
    )

    rc_body = encoded[pre_off:]
    body_buf = (ctypes.c_uint8 * len(rc_body)).from_buffer_copy(bytes(rc_body))

    # Output: n_qualities bytes (the C entry decodes symbols 0..n_padded
    # internally and writes the first n_qualities into the output buffer).
    out_buf = (ctypes.c_uint8 * num_qualities)()

    rc = _lib.ttio_rans_decode_block_adaptive_m94z(
        body_buf,
        ctypes.c_size_t(len(rc_body)),
        ctypes.c_uint16(n_active),
        ctypes.c_uint16(max_sym),
        ctypes.byref(params),
        remap_buf,
        rl_buf,
        ctypes.c_size_t(num_reads),
        rc_buf,
        ctypes.c_uint16(int(pad_ctx_dense_val)),
        out_buf,
        ctypes.c_size_t(num_qualities),
    )
    if rc != 0:
        raise RuntimeError(
            f"ttio_rans_decode_block_adaptive_m94z failed: rc={rc}"
        )

    return bytes(out_buf), read_lengths, list(revcomp_flags)


# ── V4 fqzcomp_qual (CRAM 3.1) encode / decode (L2.X Stage 2) ───────────


# SAM bit 4 = SAM_REVERSE; the V4 native API consumes SAM-compatible flag
# bytes. revcomp_flags inputs are 0/1 in this module — translate.
_SAM_REVERSE = 0x10


def _encode_v4_native(
    qualities: bytes,
    read_lengths: list[int],
    revcomp_flags: list[int],
    pad_count: int,
    strategy_hint: int = -1,
) -> bytes:
    """V4 (CRAM 3.1 fqzcomp_qual) encode via libttio_rans.

    Wraps :c:func:`ttio_m94z_v4_encode`. The native side handles header
    packing (magic, version, RLT deflate, cram_body_len) and body
    compression in one call.

    Args:
        qualities: concatenated Phred quality bytes (length must equal
            ``sum(read_lengths)``).
        read_lengths: per-read length list.
        revcomp_flags: parallel list of 0/1; translated to SAM_REVERSE
            (bit 4) for the native flags byte array.
        pad_count: 0..3 (V3 convention; carried in flags bits 4-5 of
            the V4 outer header).
        strategy_hint: -1 = auto-tune (default), 0..4 = preset.
    """
    if not _HAVE_NATIVE_LIB:
        raise RuntimeError(
            "_encode_v4_native called but libttio_rans is not available"
        )

    n_qualities = len(qualities)
    n_reads = len(read_lengths)
    if len(revcomp_flags) != n_reads:
        raise ValueError(
            f"revcomp_flags length {len(revcomp_flags)} != "
            f"read_lengths length {n_reads}"
        )

    # Marshal qual_in.
    if n_qualities:
        qual_buf = (ctypes.c_uint8 * n_qualities).from_buffer_copy(bytes(qualities))
    else:
        qual_buf = None

    # Marshal read_lengths as uint32.
    if n_reads:
        _rl = array.array('I', read_lengths)
        rl_buf = (ctypes.c_uint32 * n_reads).from_buffer(_rl)
        # SAM-style flag bytes: bit 4 = SAM_REVERSE.
        _flags = array.array('B', [
            (_SAM_REVERSE if (v & 1) else 0) for v in revcomp_flags
        ])
        flags_buf = (ctypes.c_uint8 * n_reads).from_buffer(_flags)
    else:
        rl_buf = None
        flags_buf = None

    # Output capacity: V4 outer header overhead (~30 bytes) + RLT (deflated,
    # bounded by 4*n_reads) + cram body (worst case ~ qualities + slack).
    out_cap = 64 + 4 * n_reads + n_qualities * 2 + 1024
    out_buf = (ctypes.c_uint8 * out_cap)()
    out_len = ctypes.c_size_t(out_cap)

    rc = _lib.ttio_m94z_v4_encode(
        qual_buf,
        ctypes.c_size_t(n_qualities),
        rl_buf,
        ctypes.c_size_t(n_reads),
        flags_buf,
        ctypes.c_int(strategy_hint),
        ctypes.c_uint8(pad_count & 0x3),
        out_buf,
        ctypes.byref(out_len),
    )
    if rc != 0:
        raise RuntimeError(f"ttio_m94z_v4_encode failed: rc={rc}")
    return bytes(out_buf[:out_len.value])


def _decode_v4_via_native(
    encoded: bytes,
    revcomp_flags: list[int] | None,
) -> tuple[bytes, list[int], list[int]]:
    """Decode a V4 (CRAM 3.1 fqzcomp_qual) M94.Z blob.

    Pipeline:
      1. Parse the V4 outer header inline (magic, version, num_qualities,
         num_reads, pad_count) — needed to size the output buffers.
      2. Allocate read_lengths[num_reads] (uint32) — the native call
         decompresses the RLT into this array.
      3. Translate revcomp_flags 0/1 → SAM_REVERSE bytes; default to
         all-zero if caller passed None.
      4. Allocate out_qual[num_qualities].
      5. Call :c:func:`ttio_m94z_v4_decode`.
    """
    if not _HAVE_NATIVE_LIB:
        raise RuntimeError(
            "_decode_v4_via_native called but libttio_rans is not available"
        )

    # Inline parse of the V4 outer header (fields per m94z_v4_wire.h):
    #   0..4   magic = "M94Z"
    #   4      version = 4
    #   5      flags  (bits 4-5 = pad_count)
    #   6..14  num_qualities (uint64 LE)
    #  14..22  num_reads     (uint64 LE)
    #  22..26  rlt_compressed_len (uint32 LE) — only needed by native
    if len(encoded) < 26:
        raise ValueError("M94Z V4: header truncated")
    if encoded[:4] != MAGIC:
        raise ValueError(
            f"M94Z V4 bad magic: {encoded[:4]!r}, expected {MAGIC!r}"
        )
    if encoded[4] != VERSION_V4_FQZCOMP:
        raise ValueError(
            f"M94Z V4: expected version {VERSION_V4_FQZCOMP}, got {encoded[4]}"
        )
    flags_byte = encoded[5]
    # pad_count occupies bits 4-5 of flags (matches V3 convention; see
    # m94z_v4_wire.h §header layout).
    _pad_count = (flags_byte >> 4) & 0x3  # noqa: F841 — informational only
    num_qualities = struct.unpack_from("<Q", encoded, 6)[0]
    num_reads = struct.unpack_from("<Q", encoded, 14)[0]

    if num_qualities > (1 << 40):
        raise ValueError(
            f"M94Z V4: implausible num_qualities {num_qualities}"
        )
    if num_reads > (1 << 32):
        raise ValueError(
            f"M94Z V4: implausible num_reads {num_reads}"
        )

    if revcomp_flags is None:
        revcomp_flags = [0] * num_reads
    elif len(revcomp_flags) != num_reads:
        raise ValueError(
            f"revcomp_flags length {len(revcomp_flags)} != "
            f"num_reads {num_reads}"
        )

    in_buf = (ctypes.c_uint8 * len(encoded)).from_buffer_copy(bytes(encoded))
    out_buf = (ctypes.c_uint8 * num_qualities)()

    if num_reads:
        _rl = array.array('I', [0] * num_reads)
        rl_buf = (ctypes.c_uint32 * num_reads).from_buffer(_rl)
        _flags = array.array('B', [
            (_SAM_REVERSE if (v & 1) else 0) for v in revcomp_flags
        ])
        flags_buf = (ctypes.c_uint8 * num_reads).from_buffer(_flags)
    else:
        _rl = array.array('I')
        rl_buf = None
        flags_buf = None

    rc = _lib.ttio_m94z_v4_decode(
        in_buf,
        ctypes.c_size_t(len(encoded)),
        rl_buf,
        ctypes.c_size_t(num_reads),
        flags_buf,
        out_buf,
        ctypes.c_size_t(num_qualities),
    )
    if rc != 0:
        raise RuntimeError(f"ttio_m94z_v4_decode failed: rc={rc}")

    read_lengths = list(_rl) if num_reads else []
    return bytes(out_buf), read_lengths, list(revcomp_flags)


def encode(
    qualities: bytes,
    read_lengths: list[int],
    revcomp_flags: list[int],
    *,
    context_params: ContextParams | None = None,
    prefer_native: bool | None = None,
    prefer_v3: bool | None = None,
    prefer_v4: bool | None = None,
    v4_strategy_hint: int = -1,
) -> bytes:
    """Top-level M94.Z encoder.

    Version dispatch (in priority order):
      1. ``prefer_v4 is True`` → V4 (CRAM 3.1 fqzcomp_qual port).
      2. ``prefer_v3 is True`` → V3 (adaptive Range Coder).
      3. Both False / fall-through → V1/V2 based on ``prefer_native``.
      4. ``prefer_v4`` / ``prefer_v3`` are ``None`` (default) → consult
         env var ``TTIO_M94Z_VERSION``: ``"4"`` → V4, ``"3"`` → V3,
         ``"2"`` → V2, ``"1"`` → V1. If unset, **V4 is the default**
         when libttio_rans is available; otherwise V1 (Cython /
         pure-Python).

    Args:
        qualities: concatenated Phred quality byte stream.
        read_lengths: per-read length list (sum must equal
            len(qualities)).
        revcomp_flags: parallel list of 0/1.
        context_params: optional :class:`ContextParams`; default is
            ``qbits=12, pbits=2, sloc=14``. Ignored for V4 (CRAM
            fqzcomp_qual uses its own internal context model).
        prefer_native: legacy V1↔V2 toggle. Ignored when V3 / V4 selected.
        prefer_v3: explicit override for V3 encode.
        prefer_v4: explicit override for V4 encode (takes priority).
        v4_strategy_hint: -1 = auto-tune (default), 0..4 = preset for
            the V4 fqzcomp_qual encoder.

    Returns:
        On-wire byte stream. Version byte is 1, 2, 3, or 4 depending on
        the active codec path.
    """
    if not isinstance(qualities, (bytes, bytearray, memoryview)):
        raise TypeError("qualities must be bytes-like")
    qualities = bytes(qualities)
    if len(read_lengths) != len(revcomp_flags):
        raise ValueError(
            f"read_lengths ({len(read_lengths)}) != revcomp_flags "
            f"({len(revcomp_flags)})"
        )
    total = sum(read_lengths)
    if total != len(qualities):
        raise ValueError(
            f"sum(read_lengths) ({total}) != len(qualities) "
            f"({len(qualities)})"
        )
    if context_params is None:
        context_params = ContextParams()

    n = len(qualities)
    pad_count = (-n) & 3
    n_padded = n + pad_count

    # ── Version-selection ladder ────────────────────────────────────────
    # Resolve prefer_v4 / prefer_v3 / prefer_native against env vars:
    #   TTIO_M94Z_VERSION:  "4" / "3" / "2" / "1" → force that version.
    #   TTIO_M94Z_USE_NATIVE (legacy): truthy → enable V2 (V1 v V2 toggle).
    env_ver = os.environ.get("TTIO_M94Z_VERSION", "").strip()

    if prefer_v4 is None:
        if env_ver == "4":
            prefer_v4 = True
        elif env_ver in ("1", "2", "3"):
            prefer_v4 = False
        else:
            # No explicit selection — V4 is the default when native is
            # available (CRAM 3.1 fqzcomp port; best ratio). Without the
            # native library V4 isn't possible, so the V3/V2/V1 ladder
            # takes over.
            prefer_v4 = _HAVE_NATIVE_LIB

    if prefer_v4 and _HAVE_NATIVE_LIB:
        return _encode_v4_native(
            qualities, list(read_lengths), list(revcomp_flags),
            pad_count, strategy_hint=v4_strategy_hint,
        )

    if prefer_v3 is None:
        if env_ver == "3":
            prefer_v3 = True
        elif env_ver in ("1", "2"):
            prefer_v3 = False
        else:
            # No explicit selection — V3 is the next-best default when
            # native is available (used when V4 is suppressed by caller).
            prefer_v3 = _HAVE_NATIVE_LIB

    if prefer_v3 and _HAVE_NATIVE_LIB:
        return _encode_v3_native(
            qualities, list(read_lengths), list(revcomp_flags),
            context_params, n, n_padded, pad_count,
        )

    if prefer_native is None:
        if env_ver == "2":
            prefer_native = True
        elif env_ver == "1":
            prefer_native = False
        else:
            env_val = os.environ.get(
                "TTIO_M94Z_USE_NATIVE", "",
            ).strip().lower()
            prefer_native = env_val in ("1", "true", "yes", "on")
    use_native_v2 = bool(prefer_native) and _HAVE_NATIVE_LIB

    if use_native_v2:
        return _encode_v2_native(
            qualities, list(read_lengths), list(revcomp_flags),
            context_params, n, n_padded, pad_count,
        )

    if _HAVE_C_EXTENSION:
        # Cython fast path: do passes 1+2 + lane reverse in C.
        streams_c, state_init_c, state_final_c, active_ctxs, freq_arrays = \
            _ext.encode_full_c(
                qualities,
                list(read_lengths),
                list(revcomp_flags),
                int(context_params.qbits),
                int(context_params.pbits),
                int(context_params.sloc),
            )
        freq_tables_blob = _serialize_freq_tables_from_arrays(
            active_ctxs, freq_arrays, context_params.sloc,
        )
        return _pack_wire_format(
            qualities_len=n,
            read_lengths=list(read_lengths),
            pad_count=pad_count,
            streams=streams_c,
            state_init=state_init_c,
            state_final=state_final_c,
            freq_tables_compressed=freq_tables_blob,
            context_params=context_params,
        )

    # Pass 1: build per-context counts and the context sequence.
    contexts = _build_context_seq(
        qualities, read_lengths, revcomp_flags, n_padded,
        context_params.qbits, context_params.pbits, context_params.sloc,
    )

    raw_counts: dict[int, list[int]] = {}
    symbols = bytearray(n_padded)
    symbols[:n] = qualities  # padding stays 0
    for i in range(n_padded):
        ctx = contexts[i]
        sym = symbols[i]
        if ctx not in raw_counts:
            raw_counts[ctx] = [0] * 256
        raw_counts[ctx][sym] += 1

    # Normalise to T per context.
    freq_per_ctx: dict[int, list[int]] = {}
    cum_per_ctx: dict[int, list[int]] = {}
    for ctx, rc in raw_counts.items():
        freq = normalise_to_total(rc, T)
        freq_per_ctx[ctx] = freq
        cum_per_ctx[ctx] = cumulative(freq)

    # Pass 2: rANS encode (reverse).
    streams, state_init, state_final = _encode_body(
        qualities, contexts, n_padded, freq_per_ctx, cum_per_ctx,
    )

    # Build wire format.
    rlt = _encode_read_lengths(read_lengths)
    freq_tables_blob = _serialize_freq_tables(freq_per_ctx, context_params.sloc)
    flags = (pad_count & 0x3) << 4

    header_bytes = _pack_codec_header(CodecHeader(
        flags=flags,
        num_qualities=n,
        num_reads=len(read_lengths),
        rlt_compressed_len=len(rlt),
        read_length_table=rlt,
        context_params=context_params,
        freq_tables_compressed=freq_tables_blob,
        state_init=state_init,
    ))

    # Body: 16 bytes substream lengths + each substream (no interleave —
    # the streams are independent byte buffers; we lay them end-to-end).
    body = bytearray()
    for s_idx in range(NUM_STREAMS):
        body += struct.pack("<I", len(streams[s_idx]))
    for s_idx in range(NUM_STREAMS):
        body += streams[s_idx]

    trailer = struct.pack(
        "<IIII",
        state_final[0] & 0xFFFFFFFF,
        state_final[1] & 0xFFFFFFFF,
        state_final[2] & 0xFFFFFFFF,
        state_final[3] & 0xFFFFFFFF,
    )
    return header_bytes + bytes(body) + trailer


def _decode_v2_via_native_streaming(
    body_bytes: bytes,
    n_symbols: int,
    n_padded: int,
    freq_per_ctx: dict,
    qbits: int,
    pbits: int,
    sloc: int,
    read_lengths: list,
    revcomp_flags: list,
) -> bytes:
    """Decode V2 body via libttio_rans with M94.Z context derivation in C.

    Calls ``ttio_rans_decode_block_m94z`` (Task 81) which bakes the
    M94.Z context formula directly into native code, eliminating the
    per-symbol ctypes callback overhead that previously made the
    streaming path slower than the pure-Python V2 decoder.

    Raises RuntimeError if _HAVE_NATIVE_LIB is False.
    """
    if not _HAVE_NATIVE_LIB:
        raise RuntimeError("libttio_rans not available")

    # ── Build dense freq / cum / dtab arrays ───────────────────────────
    # The V2 encoder remapped sparse ctx IDs to dense [0, n_active).
    active_ctxs = sorted(freq_per_ctx.keys())
    n_contexts = len(active_ctxs)
    if n_contexts == 0:
        raise ValueError("_decode_v2_via_native_streaming: empty freq_per_ctx")

    # Flat freq + cum arrays (row-major: row c is [c*256, (c+1)*256)).
    # numpy makes the per-context fill one C-level memcpy and the cum
    # computation one vectorised cumsum — the previous nested-Python
    # loop was 1.28M ops at sloc=14, dominating the V2 native decode
    # at 10MB scale.
    import numpy as np
    freq_np = np.empty((n_contexts, 256), dtype=np.uint32)
    for dense, sparse in enumerate(active_ctxs):
        freq_np[dense] = freq_per_ctx[sparse]
    # cum[s] = sum(freq[0..s]); we want exclusive prefix so prepend 0.
    cum_np = np.empty_like(freq_np)
    cum_np[:, 0] = 0
    np.cumsum(freq_np[:, :-1], axis=1, dtype=np.uint32, out=cum_np[:, 1:])
    freq_np = np.ascontiguousarray(freq_np)
    cum_np  = np.ascontiguousarray(cum_np)

    freq_flat = freq_np.ctypes.data_as(ctypes.POINTER(ctypes.c_uint32))
    cum_flat  = cum_np.ctypes.data_as(ctypes.POINTER(ctypes.c_uint32))

    # Build dtab via the C library.
    dtab_size = n_contexts * T  # T = 4096
    dtab_arr = (ctypes.c_uint8 * dtab_size)()
    rc = _lib.ttio_rans_build_decode_table(
        ctypes.c_uint16(n_contexts),
        freq_flat, cum_flat, dtab_arr,
    )
    if rc != 0:
        raise RuntimeError(f"build_decode_table failed: rc={rc}")

    # ── Build sparse->dense ctx_remap table (size 1<<sloc, 0xFFFF=miss)
    # The native function substitutes ``pad_ctx_dense`` for any 0xFFFF
    # sparse-ctx that wasn't in the active set.
    ctx_cap = 1 << sloc
    _remap_arr = array.array('H', [0xFFFF] * ctx_cap)
    for dense, sparse in enumerate(active_ctxs):
        _remap_arr[sparse] = dense
    ctx_remap_buf = (ctypes.c_uint16 * ctx_cap).from_buffer(_remap_arr)

    pad_ctx_sparse = m94z_context(0, 0, 0, qbits, pbits, sloc)
    pad_ctx_dense = _remap_arr[pad_ctx_sparse]
    if pad_ctx_dense == 0xFFFF:
        # The pad context wasn't in the active set; pick 0 as the
        # fallback to match the streaming-callback behaviour.
        pad_ctx_dense = 0

    # ── Read metadata as primitive-typed arrays ──────────────────────
    n_reads = len(read_lengths)
    if n_reads:
        _rl = array.array('I', read_lengths)
        _rc = array.array('B', [v & 1 for v in revcomp_flags])
        rl_buf = (ctypes.c_uint32 * n_reads).from_buffer(_rl)
        rc_buf = (ctypes.c_uint8  * n_reads).from_buffer(_rc)
    else:
        rl_buf = None
        rc_buf = None

    params = _TTIOM94ZParams(qbits=qbits, pbits=pbits, sloc=sloc)
    body_buf = (ctypes.c_uint8 * len(body_bytes)).from_buffer_copy(body_bytes)
    # The C entry pads internally — we pass the unpadded n_symbols and
    # size the output buffer to match. The C function writes
    # symbols[0..n_symbols) and ignores the trailing pad positions.
    out_buf = (ctypes.c_uint8 * n_symbols)()

    rc = _lib.ttio_rans_decode_block_m94z(
        body_buf,
        ctypes.c_size_t(len(body_bytes)),
        ctypes.c_uint16(n_contexts),
        freq_flat, cum_flat, dtab_arr,
        ctypes.byref(params),
        ctx_remap_buf,
        rl_buf, ctypes.c_size_t(n_reads), rc_buf,
        ctypes.c_uint16(int(pad_ctx_dense)),
        out_buf, ctypes.c_size_t(n_symbols),
    )
    if rc != 0:
        raise RuntimeError(f"decode_block_m94z failed: rc={rc}")

    return bytes(out_buf[:n_symbols])


def _decode_v2_with_metadata(
    encoded: bytes,
    revcomp_flags: list[int] | None,
) -> tuple[bytes, list[int], list[int]]:
    """Decode a V2 (libttio_rans-body) M94.Z blob.

    Uses pure-Python decode of the V2 body byte format with on-the-fly
    context derivation from previously-decoded symbols. This is a
    correctness-first implementation; native-accelerated V2 decode is
    deferred to a follow-up task (would require a streaming/iterator
    API on the C side).
    """
    header, body_off = _unpack_codec_header_v2(encoded)
    n_qualities = header.num_qualities
    n_reads = header.num_reads
    pad_count = (header.flags >> 4) & 0x3

    read_lengths = _decode_read_lengths(header.read_length_table, n_reads)

    if revcomp_flags is None:
        revcomp_flags = [0] * n_reads
    elif len(revcomp_flags) != n_reads:
        raise ValueError(
            f"revcomp_flags length {len(revcomp_flags)} != num_reads {n_reads}"
        )

    n_padded = n_qualities + pad_count
    if (n_padded & 3) != 0:
        raise ValueError(
            f"M94Z: n_padded {n_padded} not a multiple of 4 "
            f"(num_qualities={n_qualities}, pad_count={pad_count})"
        )

    body = encoded[body_off:]
    if len(body) < 32:
        raise ValueError("M94Z V2: body shorter than native header")

    # Recover sparse freq tables.
    freq_per_ctx = _deserialize_freq_tables(header.freq_tables_compressed)
    cum_per_ctx = {ctx: cumulative(freq) for ctx, freq in freq_per_ctx.items()}

    qbits = header.context_params.qbits
    pbits = header.context_params.pbits
    sloc = header.context_params.sloc
    pad_ctx = m94z_context(0, 0, 0, qbits, pbits, sloc)
    shift = max(1, qbits // 3)
    qmask_local = (1 << qbits) - 1

    # Parse V2 body header (states, lane sizes).
    states = list(struct.unpack_from("<IIII", body, 0))
    lane_bytes = list(struct.unpack_from("<IIII", body, 16))
    total_data = sum(lane_bytes)
    if len(body) < 32 + total_data:
        raise ValueError(
            f"M94Z V2: body truncated (have {len(body)}, "
            f"need {32 + total_data})"
        )

    # Per-lane sub-buffer pointers.
    mv = memoryview(body)
    lane_data = []
    lane_pos = [0, 0, 0, 0]
    offset = 32
    for s_idx in range(NUM_STREAMS):
        lane_data.append(mv[offset:offset + lane_bytes[s_idx]])
        offset += lane_bytes[s_idx]

    # ── Native streaming dispatch ──────────────────────────────────────
    # Try libttio_rans streaming decode first.  Falls back to pure-Python
    # on any error (e.g. if the streaming API is unavailable at runtime).
    if _HAVE_NATIVE_LIB:
        try:
            q_bytes = _decode_v2_via_native_streaming(
                bytes(body),
                n_qualities,
                n_padded,
                freq_per_ctx,
                qbits,
                pbits,
                sloc,
                read_lengths,
                list(revcomp_flags),
            )
            return q_bytes, read_lengths, list(revcomp_flags)
        except Exception:
            pass  # fall through to pure-Python decode

    out = bytearray(n_padded)

    # Forward decode with on-the-fly context derivation (same model as V1).
    read_idx = 0
    pos_in_read = 0
    cur_read_len = read_lengths[0] if read_lengths else 0
    cur_revcomp = revcomp_flags[0] if revcomp_flags else 0
    cumulative_read_end = cur_read_len
    prev_q = 0

    for i in range(n_padded):
        s_idx = i & 3
        if i < n_qualities:
            if (i >= cumulative_read_end
                    and read_idx < len(read_lengths) - 1):
                read_idx += 1
                pos_in_read = 0
                cur_read_len = read_lengths[read_idx]
                cur_revcomp = revcomp_flags[read_idx]
                cumulative_read_end += cur_read_len
                prev_q = 0
            pb = position_bucket_pbits(pos_in_read, cur_read_len, pbits)
            ctx = m94z_context(prev_q, pb, cur_revcomp & 1, qbits, pbits, sloc)
        else:
            ctx = pad_ctx

        if ctx not in freq_per_ctx:
            raise ValueError(
                f"M94Z V2 decoder: ctx {ctx} not in freq_tables (corrupt blob)"
            )
        freq = freq_per_ctx[ctx]
        cum = cum_per_ctx[ctx]
        x = states[s_idx]
        slot = x & T_MASK
        sym = bisect_right(cum, slot) - 1
        f = freq[sym]
        c = cum[sym]
        x = (x >> T_BITS) * f + slot - c
        # Renormalise: read 16-bit LE chunks while x < L (matches C lib).
        while x < L:
            ld = lane_data[s_idx]
            lp = lane_pos[s_idx]
            if lp + 2 > len(ld):
                raise ValueError(
                    f"M94Z V2: lane {s_idx} exhausted at i={i}"
                )
            chunk = ld[lp] | (ld[lp + 1] << 8)
            lane_pos[s_idx] = lp + 2
            x = (x << B_BITS) | chunk
        states[s_idx] = x
        out[i] = sym

        if i < n_qualities:
            prev_q = ((prev_q << shift) | (sym & ((1 << shift) - 1))) & qmask_local
            pos_in_read += 1

    # Sanity: after decoding all symbols + padding, every state should
    # equal L (the encoder's initial state). Mismatch indicates corruption.
    for s_idx in range(NUM_STREAMS):
        if states[s_idx] != L:
            raise ValueError(
                f"M94Z V2: post-decode state[{s_idx}]={states[s_idx]} != "
                f"L={L}; stream is corrupt"
            )
        if lane_pos[s_idx] != lane_bytes[s_idx]:
            raise ValueError(
                f"M94Z V2: lane {s_idx} consumed {lane_pos[s_idx]} of "
                f"{lane_bytes[s_idx]} bytes; stream may be malformed"
            )

    qualities = bytes(out[:n_qualities])
    return qualities, read_lengths, list(revcomp_flags)


def decode_with_metadata(
    encoded: bytes,
    revcomp_flags: list[int] | None = None,
) -> tuple[bytes, list[int], list[int]]:
    """Decode an M94.Z blob.

    ``revcomp_flags`` must match the encoder's trajectory (as in M94 v1).
    If ``None``, all-zero is assumed. Both V1 (default) and V2
    (native-body) streams are supported.

    V2 decode dispatches to _decode_v2_via_native_streaming when
    libttio_rans is available (Task 26b), falling back to the pure-Python
    implementation on any error.
    """
    if len(encoded) < 5:
        raise ValueError("M94Z: encoded too short to read magic+version")
    if encoded[:4] != MAGIC:
        raise ValueError(
            f"M94Z bad magic: {encoded[:4]!r}, expected {MAGIC!r}"
        )
    if encoded[4] == VERSION_V4_FQZCOMP:
        if not _HAVE_NATIVE_LIB:
            raise RuntimeError(
                "M94Z V4 decode requires libttio_rans (set "
                "TTIO_RANS_LIB_PATH or install the native library)"
            )
        return _decode_v4_via_native(encoded, revcomp_flags)

    if encoded[4] == VERSION_V3_ADAPTIVE:
        if not _HAVE_NATIVE_LIB:
            raise RuntimeError(
                "M94Z V3 decode requires libttio_rans (set "
                "TTIO_RANS_LIB_PATH or install the native library)"
            )
        return _decode_v3_via_native(encoded, revcomp_flags)

    if encoded[4] == VERSION_V2_NATIVE:
        return _decode_v2_with_metadata(encoded, revcomp_flags)

    header, header_size = _unpack_codec_header(encoded)
    n_qualities = header.num_qualities
    n_reads = header.num_reads
    pad_count = (header.flags >> 4) & 0x3

    read_lengths = _decode_read_lengths(header.read_length_table, n_reads)

    if revcomp_flags is None:
        revcomp_flags = [0] * n_reads
    elif len(revcomp_flags) != n_reads:
        raise ValueError(
            f"revcomp_flags length {len(revcomp_flags)} != num_reads {n_reads}"
        )

    n_padded = n_qualities + pad_count
    if (n_padded & 3) != 0:
        raise ValueError(
            f"M94Z: n_padded {n_padded} not a multiple of 4 "
            f"(num_qualities={n_qualities}, pad_count={pad_count})"
        )

    trailer_off = len(encoded) - 16
    if trailer_off < header_size:
        raise ValueError("M94Z: encoded too short for body+trailer")
    body = encoded[header_size:trailer_off]
    state_final = struct.unpack_from("<IIII", encoded, trailer_off)

    # Body layout: 16 bytes of substream lengths + concatenated streams.
    if len(body) < 16:
        raise ValueError("M94Z: body too short for substream lengths")
    sub_lens = struct.unpack_from("<IIII", body, 0)
    cursor = 16
    streams: list[bytes] = []
    for s_idx in range(NUM_STREAMS):
        end = cursor + sub_lens[s_idx]
        if end > len(body):
            raise ValueError(
                f"M94Z: substream {s_idx} truncated (need {sub_lens[s_idx]})"
            )
        streams.append(bytes(body[cursor:end]))
        cursor = end

    qbits = header.context_params.qbits
    pbits = header.context_params.pbits
    sloc = header.context_params.sloc

    if _HAVE_C_EXTENSION:
        active_ctxs, freq_arrays = _deserialize_freq_tables_to_arrays(
            header.freq_tables_compressed
        )
        out_bytes = _ext.decode_body_c(
            streams,
            tuple(state_final),
            tuple(header.state_init),
            int(n_qualities),
            int(n_padded),
            list(read_lengths),
            list(revcomp_flags),
            active_ctxs,
            freq_arrays,
            int(qbits),
            int(pbits),
            int(sloc),
        )
        qualities = bytes(out_bytes[:n_qualities])
        return qualities, read_lengths, list(revcomp_flags)

    # Recover freq tables.
    freq_per_ctx = _deserialize_freq_tables(header.freq_tables_compressed)
    cum_per_ctx = {ctx: cumulative(freq) for ctx, freq in freq_per_ctx.items()}

    # Rebuild context sequence by mirroring the encoder's prev_q ring
    # over the decoded symbols. The decoder must produce the SAME
    # context for each position before decoding it.
    pad_ctx = m94z_context(0, 0, 0, qbits, pbits, sloc)
    shift = max(1, qbits // 3)
    qmask_local = (1 << qbits) - 1

    state = list(state_final)
    pos = [0, 0, 0, 0]
    out = bytearray(n_padded)

    read_idx = 0
    pos_in_read = 0
    cur_read_len = read_lengths[0] if read_lengths else 0
    cur_revcomp = revcomp_flags[0] if revcomp_flags else 0
    cumulative_read_end = cur_read_len
    prev_q = 0

    for i in range(n_padded):
        if i < n_qualities:
            if (i >= cumulative_read_end
                    and read_idx < len(read_lengths) - 1):
                read_idx += 1
                pos_in_read = 0
                cur_read_len = read_lengths[read_idx]
                cur_revcomp = revcomp_flags[read_idx]
                cumulative_read_end += cur_read_len
                prev_q = 0
            pb = position_bucket_pbits(pos_in_read, cur_read_len, pbits)
            ctx = m94z_context(prev_q, pb, cur_revcomp & 1, qbits, pbits, sloc)
        else:
            ctx = pad_ctx

        if ctx not in freq_per_ctx:
            raise ValueError(
                f"M94Z decoder: ctx {ctx} not in freq_tables (corrupt blob)"
            )
        freq = freq_per_ctx[ctx]
        cum = cum_per_ctx[ctx]
        s_idx = i & 3
        sym, new_x, new_pos = _decode_one_step(
            state[s_idx], freq, cum, streams[s_idx], pos[s_idx],
        )
        out[i] = sym
        state[s_idx] = new_x
        pos[s_idx] = new_pos

        if i < n_qualities:
            prev_q = ((prev_q << shift) | (sym & ((1 << shift) - 1))) & qmask_local
            pos_in_read += 1

    if tuple(state) != header.state_init:
        raise ValueError(
            f"M94Z: post-decode state {tuple(state)} != "
            f"state_init {header.state_init}; stream is corrupt"
        )

    qualities = bytes(out[:n_qualities])
    return qualities, read_lengths, list(revcomp_flags)


__all__ = [
    "encode",
    "decode_with_metadata",
    "ContextParams",
    "CodecHeader",
    "MAGIC",
    "VERSION",
    "VERSION_V2_NATIVE",
    "VERSION_V3_ADAPTIVE",
    "VERSION_V4_FQZCOMP",
    "ADAPTIVE_STEP",
    "ADAPTIVE_T_MAX",
    "L",
    "B_BITS",
    "B",
    "T",
    "T_BITS",
    "NUM_STREAMS",
    "X_MAX_PREFACTOR",
    "m94z_context",
    "position_bucket_pbits",
    "normalise_to_total",
    "cumulative",
    "get_backend_name",
]
