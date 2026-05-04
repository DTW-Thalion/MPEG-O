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

    # Empty-run short-circuit (Phase 2c): the v1.0 encoder synthesises
    # a minimal 26-byte header for n_qualities==0; mirror that in
    # decode so we don't dispatch to the native fqzcomp_qual core
    # which rejects zero-length inputs.
    if num_qualities == 0 and num_reads == 0:
        return b"", [], list(revcomp_flags)

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
    v4_strategy_hint: int = -1,
    # Legacy keyword arguments accepted but ignored (Phase 2c: V1/V2/V3
    # encoders deleted; only V4 remains). Surface a deprecation message
    # below to make the removal visible to callers.
    context_params: ContextParams | None = None,
    prefer_native: bool | None = None,
    prefer_v3: bool | None = None,
    prefer_v4: bool | None = None,
) -> bytes:
    """Top-level M94.Z encoder — V4 (CRAM 3.1 fqzcomp_qual port) only.

    v1.0 reset (Phase 2c): the V1 (pure-Python static rANS), V2
    (native-body) and V3 (adaptive Range Coder) encoder paths were
    removed. V4 is the only encoded version. The native libttio_rans
    library is required.

    Empty-run case: V4 native rejects n_qualities==0 (the htscodecs
    fqzcomp_qual core requires at least one symbol); when there are
    no qualities, the encoder returns a minimal V4-tagged blob with
    a zero-length body so readers can still dispatch by version byte.

    Args:
        qualities: concatenated Phred quality byte stream.
        read_lengths: per-read length list (sum must equal
            len(qualities)).
        revcomp_flags: parallel list of 0/1.
        v4_strategy_hint: -1 = auto-tune (default), 0..4 = preset for
            the V4 fqzcomp_qual encoder.
        context_params, prefer_native, prefer_v3, prefer_v4: accepted
            for backward-compatible call sites only — the encoder
            always emits V4 in v1.0.

    Returns:
        On-wire byte stream tagged with version byte 4
        (``VERSION_V4_FQZCOMP``).
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

    if not _HAVE_NATIVE_LIB:
        raise RuntimeError(
            "FQZCOMP_NX16_Z V4 encode requires libttio_rans (set "
            "TTIO_RANS_LIB_PATH or install the native library). The "
            "V1/V2/V3 fallbacks were removed in v1.0."
        )

    n = len(qualities)
    pad_count = (-n) & 3

    if n == 0:
        # Empty run: synthesise a minimal V4 outer header so the
        # reader can still detect the version byte. Layout per
        # m94z_v4_wire.h: magic(4) + version(1) + flags(1)
        # + num_qualities(8) + num_reads(8) + rlt_compressed_len(4)
        # + (RLT body, empty here) + (cram body, empty here).
        flags_byte = (pad_count & 0x3) << 4
        return (
            MAGIC
            + bytes([VERSION_V4_FQZCOMP, flags_byte])
            + struct.pack("<Q", 0)   # num_qualities
            + struct.pack("<Q", 0)   # num_reads
            + struct.pack("<I", 0)   # rlt_compressed_len
        )

    return _encode_v4_native(
        qualities, list(read_lengths), list(revcomp_flags),
        pad_count, strategy_hint=v4_strategy_hint,
    )



def decode_with_metadata(
    encoded: bytes,
    revcomp_flags: list[int] | None = None,
) -> tuple[bytes, list[int], list[int]]:
    """Decode an M94.Z V4 blob.

    v1.0 reset (Phase 2c): only V4 (CRAM 3.1 fqzcomp_qual port) is
    decoded. The V1 (pure-Python static rANS), V2 (native-body) and
    V3 (adaptive Range Coder) reader header dispatches were removed
    — files written with those version bytes surface a clear
    migration error pointing at V4.

    ``revcomp_flags`` must match the encoder's trajectory; ``None``
    is treated as all-zero by V4.
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

    if encoded[4] in (VERSION, VERSION_V2_NATIVE, VERSION_V3_ADAPTIVE):
        raise ValueError(
            f"FQZCOMP_NX16_Z V{encoded[4]} (M94Z version byte = "
            f"{encoded[4]}) is no longer supported in v1.0; only V4 "
            "(CRAM 3.1 fqzcomp_qual port) is decoded. Re-encode with "
            "v1.0+."
        )
    raise ValueError(
        f"M94Z: unknown version byte {encoded[4]} (only V4 = "
        f"{VERSION_V4_FQZCOMP} is supported in v1.0)"
    )


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
