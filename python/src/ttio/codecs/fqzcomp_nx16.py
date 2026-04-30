"""TTI-O M94 — FQZCOMP_NX16 lossless quality codec.

Wire format and algorithm documented in
``docs/superpowers/specs/2026-04-28-m93-m94-m95-codec-design.md`` §3 (M94)
and ``docs/codecs/fqzcomp_nx16.md``. Codec id is
:class:`Compression.FQZCOMP_NX16` = 10.

The codec is a context-modeled adaptive arithmetic coder layered on top of
4-way interleaved rANS. Each Phred quality byte is predicted from a
context vector ``(prev_q[0], prev_q[1], prev_q[2], position_bucket,
revcomp_flag, length_bucket)`` hashed into a 12-bit context table; each
context maintains a 256-entry uint16 frequency table that adapts after
every symbol with deterministic halve-with-floor-1 renormalisation at the
4096-count boundary.

This module is the **byte-exact reference implementation**. ObjC
(``TTIOFqzcompNx16.{h,m}``) and Java
(``codecs.FqzcompNx16``) decode the bytes this module produces
byte-for-byte; the eight canonical conformance fixtures under
``python/tests/fixtures/codecs/fqzcomp_nx16_{a..h}.bin`` are the contract.

Cross-language byte-exact contract (the three pinch points ObjC + Java
must replicate verbatim):

1. **Context-hash mixer** — see :func:`fqzn_context_hash`. A
   SplitMix64-style finaliser over a packed 64-bit key reduced modulo
   the 12-bit context-table size.

2. **Adaptive count update + per-symbol freq normalisation** — after
   encoding/decoding symbol ``s`` in context ``c``:
       c.count[s] += 16          (LEARNING_RATE)
   When ``c.count[s] > 4096`` (MAX_COUNT), every entry becomes
       c.count[s'] = max(1, c.count[s'] >> 1)
   For the rANS arithmetic, ``c.count`` is normalised to sum exactly to
   ``M=4096`` via the M83 deterministic normaliser
   (:func:`ttio.codecs.rans._normalise_freqs`). This produces a
   power-of-two total which the rANS state machine requires.

3. **4-way rANS state ordering** — symbol ``i`` of the input goes
   to substream ``i % 4``; each substream has its own renorm byte
   stream. The four substream byte streams are written round-robin
   into the body (``stream0[0], stream1[0], stream2[0], stream3[0],
   stream0[1], ...``), zero-padded to equalise lengths. The first 16
   bytes of the body are the four substream byte counts as
   little-endian uint32 so the decoder can de-interleave precisely.
   ``state_init[k]`` and ``state_final[k]`` are recorded in the
   header/trailer in little-endian uint32.

Cross-language: ObjC ``TTIOFqzcompNx16`` · Java ``codecs.FqzcompNx16``.
"""
from __future__ import annotations

import struct
from dataclasses import dataclass

from ttio.codecs.rans import (
    L as RANS_L,
    M as RANS_M,
    M_BITS as RANS_M_BITS,
    M_MASK as RANS_M_MASK,
    B_BITS as RANS_B_BITS,
    B as RANS_B,
    _normalise_freqs,
)


# ── Wire-format constants ───────────────────────────────────────────────

MAGIC = b"FQZN"
VERSION = 1

# Codec header layout:
#   magic(4) + version(1) + flags(1) + num_qualities(8) + num_reads(4)
#   + rlt_compressed_len(4) = 22 bytes  (fixed prefix)
#   + read_length_table(L)
#   + context_model_params(16) + state_init[4](16)
# Total = 22 + L + 32 = 54 + L bytes.
HEADER_FIXED_PREFIX = 22
HEADER_TRAILING_FIXED = 32      # context_model_params + state_init[4]
CONTEXT_MODEL_PARAMS_SIZE = 16

# ── Algorithm constants (Binding Decision §80d defaults) ───────────────

DEFAULT_CONTEXT_TABLE_SIZE_LOG2 = 12   # 4096 contexts
DEFAULT_LEARNING_RATE = 16
DEFAULT_MAX_COUNT = 4096
DEFAULT_FREQ_TABLE_INIT = 0            # 0 = uniform
DEFAULT_CONTEXT_HASH_SEED = 0xC0FFEE

NUM_STREAMS = 4
RANS_INITIAL_STATE = RANS_L


# ── Context bucketing helpers ───────────────────────────────────────────


def position_bucket(position: int, read_length: int) -> int:
    """4-bit bucket of position-within-read, 0..15."""
    if read_length <= 0:
        return 0
    if position <= 0:
        return 0
    if position >= read_length:
        return 15
    return min(15, (position * 16) // read_length)


# Length buckets (3-bit, 0..7) — covering common Illumina/PacBio ranges.
#   bucket 0:    1- 49bp   bucket 4:  200- 299bp
#   bucket 1:   50- 99bp   bucket 5:  300- 999bp
#   bucket 2:  100-149bp   bucket 6: 1000-9999bp
#   bucket 3:  150-199bp   bucket 7: 10000bp+
_LENGTH_BUCKET_BOUNDS = (50, 100, 150, 200, 300, 1000, 10000)


def length_bucket(read_length: int) -> int:
    """3-bit bucket of read length, 0..7."""
    if read_length <= 0:
        return 0
    for i, bound in enumerate(_LENGTH_BUCKET_BOUNDS):
        if read_length < bound:
            return i
    return 7


def fqzn_context_hash(
    prev_q0: int,
    prev_q1: int,
    prev_q2: int,
    pos_bucket: int,
    revcomp: int,
    len_bucket: int,
    seed: int,
    table_size_log2: int = DEFAULT_CONTEXT_TABLE_SIZE_LOG2,
) -> int:
    """Deterministic hash of the context vector to ``[0, 1<<table_size_log2)``.

    **Cross-language byte-exact contract.** ObjC + Java MUST replicate
    this mixer bit-for-bit. The mixer packs the context vector + seed
    into a 64-bit unsigned key, then applies the SplitMix64 finaliser:

      Pack:
        bits  0.. 7 = prev_q0
        bits  8..15 = prev_q1
        bits 16..23 = prev_q2
        bits 24..27 = pos_bucket  (4 bits)
        bit  28     = revcomp     (1 bit)
        bits 29..31 = len_bucket  (3 bits)
        bits 32..63 = seed        (32 bits)

      Mix (SplitMix64 finaliser; all arithmetic mod 2**64):
        key ^= key >> 33
        key  = (key * 0xff51afd7ed558ccd) & 0xFFFFFFFFFFFFFFFF
        key ^= key >> 33
        key  = (key * 0xc4ceb9fe1a85ec53) & 0xFFFFFFFFFFFFFFFF
        key ^= key >> 33

      Reduce: key & ((1 << table_size_log2) - 1)

    The ``& 0xFFFFFFFFFFFFFFFF`` after every multiplication is essential
    for byte-parity with Java (whose ``long`` carries a sign bit).
    """
    key = (prev_q0 & 0xFF)
    key |= (prev_q1 & 0xFF) << 8
    key |= (prev_q2 & 0xFF) << 16
    key |= (pos_bucket & 0xF) << 24
    key |= (revcomp & 0x1) << 28
    key |= (len_bucket & 0x7) << 29
    key |= (seed & 0xFFFFFFFF) << 32

    mask64 = 0xFFFFFFFFFFFFFFFF
    key ^= (key >> 33)
    key = (key * 0xff51afd7ed558ccd) & mask64
    key ^= (key >> 33)
    key = (key * 0xc4ceb9fe1a85ec53) & mask64
    key ^= (key >> 33)

    return key & ((1 << table_size_log2) - 1)


# ── Adaptive count table + per-symbol M-normalised freq ─────────────────


def _new_count_table() -> list[int]:
    """Initial uniform 256-entry count table (each entry = 1, sum = 256).

    Starting at 1 (not 0) ensures every symbol is encodable from the
    first step without needing an escape mechanism.
    """
    return [1] * 256


def _adaptive_update(count: list[int], symbol: int,
                     learning_rate: int = DEFAULT_LEARNING_RATE,
                     max_count: int = DEFAULT_MAX_COUNT) -> None:
    """In-place adaptive update of ``count`` after encoding/decoding ``symbol``.

    Per spec §3 M94:
        c.count[s] += LEARNING_RATE       # default 16
        if max(c.count) > MAX_COUNT:      # default 4096
            for s' in 0..255:
                c.count[s'] = max(1, c.count[s'] >> 1)

    The renormalisation schedule is the cross-language pinch point —
    Java/ObjC implementations must reproduce the exact step-count →
    renorm-fires correspondence.

    Note: only the symbol's count is checked against ``max_count``,
    consistent with classical fqzcomp; the comparison is on the
    just-incremented entry, not the global ``max(count)``. This is the
    exact-equivalent behaviour because incrementing only affects one
    entry per call.
    """
    count[symbol] += learning_rate
    if count[symbol] > max_count:
        for k in range(256):
            v = count[k] >> 1
            count[k] = v if v >= 1 else 1


# ── M-normalisation helpers (per-symbol, fixed-M=4096 form) ─────────────


def _normalised_freq_for_count(count: list[int]) -> list[int]:
    """Normalise the adaptive count table to sum exactly to ``M=4096``."""
    return _normalise_freqs(count)


# ── Incremental-sort optimisation ────────────────────────────────────────
#
# The per-symbol qsort inside _normalise_freqs is the encode/decode
# bottleneck (≈86% of CPU). We replace it with a per-context "sorted_desc"
# index that is maintained incrementally across _adapt calls. Because
# count[sym] only changes by +LEARNING_RATE each step (or a halve event),
# the sort order changes by AT MOST one bubble; an O(256) bubble-up beats
# an O(256 log 256) qsort.
#
# Invariants (sorted_desc):
#   count[sorted_desc[0]] >= count[sorted_desc[1]] >= ... >= count[sorted_desc[255]]
# with ties broken by ASCENDING symbol value. This matches the
# (-cnt, sym) key the canonical _normalise_freqs uses for the delta>0
# distribute step.
#
# The delta<0 distribute step (which uses ASCENDING-count, ASCENDING-sym
# order) is rare; we fall back to the existing _normalise_freqs there.


class _CtxState:
    """Per-context adaptive state with maintained sort order.

    sorted_desc[k] = symbol at rank k (rank 0 = most frequent, ties
        broken by ascending symbol value).
    inv_sort[s] = rank of symbol s in sorted_desc.

    Initial state: count = [1]*256 (uniform), sorted_desc = [0..255].
    """

    __slots__ = ("count", "sorted_desc", "inv_sort")

    def __init__(self) -> None:
        self.count = [1] * 256
        self.sorted_desc = list(range(256))
        self.inv_sort = list(range(256))


def _normalise_freqs_incremental(
    count: list[int], sorted_desc: list[int]
) -> list[int]:
    """Byte-exact equivalent of :func:`_normalise_freqs` for delta >= 0.

    Uses the pre-maintained ``sorted_desc`` (descending count, ascending
    sym tie-break) for the delta>0 distribute step instead of resorting
    from scratch every call.

    For delta < 0 (rare: it requires a count distribution where the
    proportional scale overshoots M, which happens infrequently in
    adaptive streams), falls back to the canonical :func:`_normalise_freqs`.
    """
    M = RANS_M
    total = 0
    for c in count:
        total += c
    if total <= 0:
        raise ValueError("cannot normalise empty count vector")

    freq = [0] * 256
    freq_sum = 0
    for s in range(256):
        c = count[s]
        if c > 0:
            scaled = (c * M) // total
            freq[s] = scaled if scaled >= 1 else 1
            freq_sum += freq[s]

    delta = M - freq_sum
    if delta == 0:
        return freq
    if delta > 0:
        # Distribute +1 round-robin walking sorted_desc.
        # Note: with the [1]*256 init, all 256 symbols have count > 0
        # for the entire codec lifetime (halve floors at 1), so all 256
        # are eligible and sorted_desc covers the full alphabet.
        i = 0
        while delta > 0:
            freq[sorted_desc[i & 0xFF]] += 1
            i += 1
            delta -= 1
        return freq
    # delta < 0: rare path — fall back to the canonical sort-from-scratch
    # normaliser.
    return _normalise_freqs(count)


def _adapt_with_sort(
    state: _CtxState,
    sym: int,
    learning_rate: int = DEFAULT_LEARNING_RATE,
    max_count: int = DEFAULT_MAX_COUNT,
) -> None:
    """In-place adaptive update + maintenance of ``sorted_desc`` / ``inv_sort``.

    Mirrors :func:`_adaptive_update` semantically; additionally bubbles
    ``sym`` up ``state.sorted_desc`` to preserve the invariant
    ``count[sorted_desc[0]] >= ... >= count[sorted_desc[255]]`` with
    ascending-sym tie-break.
    """
    count = state.count
    sorted_desc = state.sorted_desc
    inv_sort = state.inv_sort

    count[sym] += learning_rate
    if count[sym] > max_count:
        # Halve all counts with floor 1; rebuild sorted_desc from scratch.
        for k in range(256):
            v = count[k] >> 1
            count[k] = v if v >= 1 else 1
        sd = sorted(range(256), key=lambda s: (-count[s], s))
        for i, s in enumerate(sd):
            sorted_desc[i] = s
            inv_sort[s] = i
        return

    # Bubble sym up: the increment may have moved sym past zero or more
    # entries that previously preceded it. The sort key is
    # (-count[s], s); sym belongs BEFORE prev iff
    #     count[sym] > count[prev]  OR
    #     (count[sym] == count[prev]  AND  sym < prev).
    pos = inv_sort[sym]
    cnt_sym = count[sym]
    while pos > 0:
        prev = sorted_desc[pos - 1]
        cnt_prev = count[prev]
        if cnt_sym > cnt_prev or (cnt_sym == cnt_prev and sym < prev):
            sorted_desc[pos] = prev
            sorted_desc[pos - 1] = sym
            inv_sort[prev] = pos
            inv_sort[sym] = pos - 1
            pos -= 1
        else:
            break


def _cumulative(freq: list[int]) -> list[int]:
    """Cumulative-frequency table c[0..256] where c[s] = sum(freq[0:s])."""
    cum = [0] * 257
    s = 0
    for i in range(256):
        cum[i] = s
        s += freq[i]
    cum[256] = s
    return cum


def _slot_to_symbol(freq: list[int]) -> list[int]:
    """M-element lookup mapping ``slot`` to the decoded symbol."""
    table = [0] * RANS_M
    pos = 0
    for s in range(256):
        f = freq[s]
        for j in range(f):
            table[pos + j] = s
        pos += f
    return table


# ── 4-way rANS encode / decode (pure Python reference, fixed-M form) ────


def _rans_four_way_encode(
    qualities: bytes,
    read_lengths: list[int],
    revcomp_flags: list[int],
    *,
    table_size_log2: int = DEFAULT_CONTEXT_TABLE_SIZE_LOG2,
    learning_rate: int = DEFAULT_LEARNING_RATE,
    max_count: int = DEFAULT_MAX_COUNT,
    seed: int = DEFAULT_CONTEXT_HASH_SEED,
) -> tuple[bytes, tuple[int, int, int, int], tuple[int, int, int, int], int]:
    """Encode ``qualities`` with 4-way interleaved rANS over context-modeled
    adaptive frequency tables (fixed-M=4096 form).

    Returns:
        (body_bytes, state_init, state_final, padding_count)

    ``body_bytes`` layout: 16 bytes of substream byte counts (4 ×
    little-endian uint32) followed by round-robin-interleaved bytes from
    the four substream byte streams (zero-padded to equalise lengths).

    Encoder runs symbols in REVERSE (canonical rANS); the decoder runs
    forward. Adaptive updates evolve in FORWARD encoder order, so the
    encoder does a forward "snapshot" pass first to capture
    ``(f_i, c_i)`` for each symbol against the per-symbol M-normalised
    frequency table, then the reverse rANS pass consumes those snapshots.
    """
    n = len(qualities)
    pad_count = (-n) & 3  # 0..3 zero-bytes appended to last 4-way row
    n_padded = n + pad_count

    # --- Forward pass: snapshot (f, c) from M-normalised freq table
    #     BEFORE the +learning_rate update at each step. ---
    n_contexts = 1 << table_size_log2
    ctx_states: list[_CtxState | None] = [None] * n_contexts
    snap_f = [0] * n_padded
    snap_c = [0] * n_padded
    symbols = bytearray(n_padded)
    symbols[:n] = qualities  # padding symbols stay 0

    # Padding context (all-zero context vector).
    pad_ctx = fqzn_context_hash(0, 0, 0, 0, 0, 0, seed, table_size_log2)

    read_idx = 0
    pos_in_read = 0
    cur_read_len = read_lengths[0] if read_lengths else 0
    cur_revcomp = revcomp_flags[0] if revcomp_flags else 0
    cumulative_read_end = cur_read_len
    prev_q0 = 0
    prev_q1 = 0
    prev_q2 = 0

    for i in range(n_padded):
        if i < n:
            if (i >= cumulative_read_end
                    and read_idx < len(read_lengths) - 1):
                read_idx += 1
                pos_in_read = 0
                cur_read_len = read_lengths[read_idx]
                cur_revcomp = revcomp_flags[read_idx]
                cumulative_read_end += cur_read_len
                prev_q0 = 0
                prev_q1 = 0
                prev_q2 = 0
            pb = position_bucket(pos_in_read, cur_read_len)
            lb = length_bucket(cur_read_len)
            ctx = fqzn_context_hash(
                prev_q0, prev_q1, prev_q2, pb, cur_revcomp & 1, lb,
                seed, table_size_log2,
            )
        else:
            ctx = pad_ctx

        if ctx_states[ctx] is None:
            ctx_states[ctx] = _CtxState()
        cstate = ctx_states[ctx]

        sym = symbols[i]
        # M-normalise count -> freq using maintained sort order.
        freq = _normalise_freqs_incremental(cstate.count, cstate.sorted_desc)
        cum = _cumulative(freq)
        snap_f[i] = freq[sym]
        snap_c[i] = cum[sym]

        # Adaptive update for next step (also maintains sorted_desc/inv_sort).
        _adapt_with_sort(cstate, sym, learning_rate, max_count)

        if i < n:
            prev_q2 = prev_q1
            prev_q1 = prev_q0
            prev_q0 = sym
            pos_in_read += 1

    # --- Reverse rANS encoder pass (fixed-M arithmetic). ---
    state = [RANS_INITIAL_STATE] * NUM_STREAMS
    state_init = tuple(state)
    out_streams: list[bytearray] = [bytearray() for _ in range(NUM_STREAMS)]

    for i in range(n_padded - 1, -1, -1):
        s_idx = i & 3
        f = snap_f[i]
        c = snap_c[i]
        x = state[s_idx]
        # x_max(s) = ((L >> M_BITS) << B_BITS) * f.
        xm = ((RANS_L >> RANS_M_BITS) << RANS_B_BITS) * f
        while x >= xm:
            out_streams[s_idx].append(x & 0xFF)
            x >>= 8
        # Encode: x = (x // f) * M + (x % f) + cum.
        x = (x // f) * RANS_M + (x % f) + c
        state[s_idx] = x

    state_final = tuple(state)

    # Reverse each substream's output (LIFO during encode → emit-order).
    for s_idx in range(NUM_STREAMS):
        out_streams[s_idx].reverse()

    # Interleave round-robin, zero-padded to max_len.
    max_len = max(len(s) for s in out_streams)
    body = bytearray()
    for s_idx in range(NUM_STREAMS):
        body += struct.pack("<I", len(out_streams[s_idx]))
    for j in range(max_len):
        for s_idx in range(NUM_STREAMS):
            stream = out_streams[s_idx]
            body.append(stream[j] if j < len(stream) else 0)
    return bytes(body), state_init, state_final, pad_count


def _rans_four_way_decode(
    body: bytes,
    state_init: tuple[int, int, int, int],
    state_final: tuple[int, int, int, int],
    n_padded: int,
    evolver: "_StatefulContextEvolver",
    *,
    table_size_log2: int = DEFAULT_CONTEXT_TABLE_SIZE_LOG2,
    learning_rate: int = DEFAULT_LEARNING_RATE,
    max_count: int = DEFAULT_MAX_COUNT,
) -> bytearray:
    """Inverse of :func:`_rans_four_way_encode` (fixed-M=4096 form)."""
    if len(body) < 16:
        raise ValueError("FQZCOMP_NX16: body too short for substream lengths")
    sub_lens = struct.unpack_from("<IIII", body, 0)
    body_payload = body[16:]
    max_len = max(sub_lens) if sub_lens else 0
    streams = [bytearray(sub_lens[s]) for s in range(NUM_STREAMS)]
    cursor = 0
    for j in range(max_len):
        for s_idx in range(NUM_STREAMS):
            if cursor >= len(body_payload):
                raise ValueError("FQZCOMP_NX16: truncated body")
            byte = body_payload[cursor]
            cursor += 1
            if j < sub_lens[s_idx]:
                streams[s_idx][j] = byte

    # Decoder runs forward, starting from state_final (encoder ran reverse).
    state = list(state_final)
    sub_pos = [0] * NUM_STREAMS

    n_contexts = 1 << table_size_log2
    ctx_states: list[_CtxState | None] = [None] * n_contexts

    out = bytearray(n_padded)

    for i in range(n_padded):
        s_idx = i & 3
        ctx = evolver.context_for(i)
        if ctx_states[ctx] is None:
            ctx_states[ctx] = _CtxState()
        cstate = ctx_states[ctx]
        # M-normalise count -> freq (mirrors encoder).
        freq = _normalise_freqs_incremental(cstate.count, cstate.sorted_desc)
        cum = _cumulative(freq)
        sym_table = _slot_to_symbol(freq)

        x = state[s_idx]
        slot = x & RANS_M_MASK
        sym = sym_table[slot]
        out[i] = sym
        f = freq[sym]
        c = cum[sym]
        x = f * (x >> RANS_M_BITS) + slot - c
        # Renormalise — pull bytes in until x is back in [L, b*L).
        while x < RANS_L:
            if sub_pos[s_idx] >= len(streams[s_idx]):
                raise ValueError(
                    f"FQZCOMP_NX16: substream {s_idx} exhausted "
                    f"while decoding symbol {i}"
                )
            x = (x << 8) | streams[s_idx][sub_pos[s_idx]]
            sub_pos[s_idx] += 1
        state[s_idx] = x

        # Adaptive update (mirrors encoder's per-symbol step).
        _adapt_with_sort(cstate, sym, learning_rate, max_count)
        evolver.feed(sym, i)

    if tuple(state) != tuple(state_init):
        raise ValueError(
            f"FQZCOMP_NX16: post-decode state {tuple(state)} != "
            f"state_init {state_init}; stream is corrupt"
        )

    return out


class _StatefulContextEvolver:
    """Decoder-side per-symbol context-vector mirror.

    Produces the same context-index sequence the encoder used by tracking
    per-read structural state (read_idx, pos_in_read, cur_read_len,
    cur_revcomp) plus the prev_q ring buffer (prev_q0, prev_q1,
    prev_q2). The decoder calls :meth:`context_for(i)` BEFORE decoding
    symbol ``i``, then :meth:`feed(symbol, i)` after.
    """

    def __init__(
        self,
        n_qualities: int,
        n_padded: int,
        read_lengths: list[int],
        revcomp_flags: list[int],
        seed: int,
        table_size_log2: int,
    ) -> None:
        self.n_qualities = n_qualities
        self.n_padded = n_padded
        self.read_lengths = read_lengths
        self.revcomp_flags = revcomp_flags
        self.seed = seed
        self.table_size_log2 = table_size_log2
        self.pad_ctx = fqzn_context_hash(0, 0, 0, 0, 0, 0, seed, table_size_log2)

        self.read_idx = 0
        self.pos_in_read = 0
        self.cur_read_len = read_lengths[0] if read_lengths else 0
        self.cur_revcomp = revcomp_flags[0] if revcomp_flags else 0
        self.cumulative_read_end = self.cur_read_len
        self.prev_q0 = 0
        self.prev_q1 = 0
        self.prev_q2 = 0

    def context_for(self, i: int) -> int:
        if i >= self.n_qualities:
            return self.pad_ctx
        if (i >= self.cumulative_read_end
                and self.read_idx < len(self.read_lengths) - 1):
            self.read_idx += 1
            self.pos_in_read = 0
            self.cur_read_len = self.read_lengths[self.read_idx]
            self.cur_revcomp = self.revcomp_flags[self.read_idx]
            self.cumulative_read_end += self.cur_read_len
            self.prev_q0 = 0
            self.prev_q1 = 0
            self.prev_q2 = 0
        pb = position_bucket(self.pos_in_read, self.cur_read_len)
        lb = length_bucket(self.cur_read_len)
        return fqzn_context_hash(
            self.prev_q0, self.prev_q1, self.prev_q2, pb,
            self.cur_revcomp & 1, lb,
            self.seed, self.table_size_log2,
        )

    def feed(self, symbol: int, i: int) -> None:
        if i >= self.n_qualities:
            return
        self.prev_q2 = self.prev_q1
        self.prev_q1 = self.prev_q0
        self.prev_q0 = symbol
        self.pos_in_read += 1


# ── Header pack/unpack ──────────────────────────────────────────────────


@dataclass(frozen=True)
class ContextModelParams:
    """16-byte per-codec parameter block.

    Wire layout:
        context_table_size_log2 : uint8
        learning_rate           : uint8
        max_count               : uint16 LE
        freq_table_init         : uint8
        context_hash_seed       : uint32 LE
        reserved                : uint8[7] (must be 0)
    """

    context_table_size_log2: int = DEFAULT_CONTEXT_TABLE_SIZE_LOG2
    learning_rate: int = DEFAULT_LEARNING_RATE
    max_count: int = DEFAULT_MAX_COUNT
    freq_table_init: int = DEFAULT_FREQ_TABLE_INIT
    context_hash_seed: int = DEFAULT_CONTEXT_HASH_SEED


def pack_context_model_params(p: ContextModelParams) -> bytes:
    return struct.pack(
        "<BBHBI7x",
        p.context_table_size_log2 & 0xFF,
        p.learning_rate & 0xFF,
        p.max_count & 0xFFFF,
        p.freq_table_init & 0xFF,
        p.context_hash_seed & 0xFFFFFFFF,
    )


def unpack_context_model_params(blob: bytes, off: int = 0) -> ContextModelParams:
    if len(blob) - off < CONTEXT_MODEL_PARAMS_SIZE:
        raise ValueError("FQZCOMP_NX16: context_model_params truncated")
    table_log2, lr, max_count, ft_init, seed = struct.unpack_from(
        "<BBHBI7x", blob, off,
    )
    return ContextModelParams(
        context_table_size_log2=table_log2,
        learning_rate=lr,
        max_count=max_count,
        freq_table_init=ft_init,
        context_hash_seed=seed,
    )


@dataclass(frozen=True)
class CodecHeader:
    """FQZCOMP_NX16 wire-format header (54 + L bytes total)."""

    flags: int                  # 1 byte
    num_qualities: int          # uint64
    num_reads: int              # uint32
    rlt_compressed_len: int     # uint32
    read_length_table: bytes    # L bytes (rANS_ORDER0-compressed)
    params: ContextModelParams  # 16 bytes
    state_init: tuple[int, int, int, int]  # 4 × uint32 LE = 16 bytes


def pack_codec_header(h: CodecHeader) -> bytes:
    if len(h.read_length_table) != h.rlt_compressed_len:
        raise ValueError(
            f"rlt_compressed_len ({h.rlt_compressed_len}) != "
            f"len(read_length_table) ({len(h.read_length_table)})"
        )
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
    out += h.read_length_table
    out += pack_context_model_params(h.params)
    out += struct.pack(
        "<IIII",
        h.state_init[0] & 0xFFFFFFFF,
        h.state_init[1] & 0xFFFFFFFF,
        h.state_init[2] & 0xFFFFFFFF,
        h.state_init[3] & 0xFFFFFFFF,
    )
    return bytes(out)


def unpack_codec_header(blob: bytes) -> tuple[CodecHeader, int]:
    """Returns (header, bytes_consumed)."""
    if len(blob) < HEADER_FIXED_PREFIX:
        raise ValueError(
            f"FQZCOMP_NX16 header too short: {len(blob)} bytes"
        )
    if blob[:4] != MAGIC:
        raise ValueError(
            f"FQZCOMP_NX16 bad magic: {blob[:4]!r}, expected {MAGIC!r}"
        )
    version = blob[4]
    if version != VERSION:
        raise ValueError(
            f"FQZCOMP_NX16 unsupported version: {version}"
        )
    flags = blob[5]
    if (flags >> 6) & 0x3:
        raise ValueError(
            f"FQZCOMP_NX16 reserved flag bits 6-7 must be 0, got 0x{flags:02x}"
        )
    num_qualities, num_reads, rlt_len = struct.unpack_from("<QII", blob, 6)
    cursor = HEADER_FIXED_PREFIX
    end_rlt = cursor + rlt_len
    if len(blob) < end_rlt + CONTEXT_MODEL_PARAMS_SIZE + 16:
        raise ValueError("FQZCOMP_NX16 header truncated")
    rlt = blob[cursor:end_rlt]
    cursor = end_rlt
    params = unpack_context_model_params(blob, cursor)
    cursor += CONTEXT_MODEL_PARAMS_SIZE
    state_init = struct.unpack_from("<IIII", blob, cursor)
    cursor += 16
    header = CodecHeader(
        flags=flags,
        num_qualities=num_qualities,
        num_reads=num_reads,
        rlt_compressed_len=rlt_len,
        read_length_table=rlt,
        params=params,
        state_init=state_init,
    )
    return header, cursor


# ── Read-length table sidecar ───────────────────────────────────────────


def encode_read_lengths(read_lengths: list[int]) -> bytes:
    """Encode ``read_lengths`` to rANS_ORDER0-compressed bytes."""
    from ttio.codecs.rans import encode as _rans_enc
    if not read_lengths:
        return _rans_enc(b"", order=0)
    buf = bytearray(4 * len(read_lengths))
    for i, ln in enumerate(read_lengths):
        struct.pack_into("<I", buf, 4 * i, ln & 0xFFFFFFFF)
    return _rans_enc(bytes(buf), order=0)


def decode_read_lengths(encoded: bytes, num_reads: int) -> list[int]:
    """Inverse of :func:`encode_read_lengths`."""
    from ttio.codecs.rans import decode as _rans_dec
    raw = _rans_dec(encoded)
    if num_reads == 0:
        return []
    if len(raw) != 4 * num_reads:
        raise ValueError(
            f"decode_read_lengths: expected {4*num_reads} raw bytes, "
            f"got {len(raw)}"
        )
    return [struct.unpack_from("<I", raw, 4 * i)[0] for i in range(num_reads)]


# ── Top-level encode / decode ──────────────────────────────────────────


def _build_flags(
    has_revcomp: bool = True,
    has_pos: bool = True,
    has_length: bool = True,
    has_prev_q: bool = True,
    pad_count: int = 0,
) -> int:
    if not (0 <= pad_count <= 3):
        raise ValueError(f"pad_count must be 0..3, got {pad_count}")
    f = 0
    if has_revcomp:
        f |= 0x01
    if has_pos:
        f |= 0x02
    if has_length:
        f |= 0x04
    if has_prev_q:
        f |= 0x08
    f |= (pad_count & 0x3) << 4
    return f


def encode(
    qualities: bytes,
    read_lengths: list[int],
    revcomp_flags: list[int],
    *,
    params: ContextModelParams | None = None,
) -> bytes:
    """Top-level FQZCOMP_NX16 encoder.

    Args:
        qualities: concatenated Phred quality byte stream.
        read_lengths: per-read length list (sum must equal len(qualities)).
        revcomp_flags: parallel list of 0/1 (1 = SAM REVERSE flag set).
        params: optional :class:`ContextModelParams`; default uses the
            spec defaults.

    Returns:
        On-wire byte stream: header || body || trailer.
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
    if params is None:
        params = ContextModelParams()

    # Prefer the C accelerator when available; falls back to pure Python.
    if _HAVE_C_EXTENSION:
        body, state_init, state_final, pad_count = _rans_four_way_encode_fast(
            qualities, read_lengths, revcomp_flags,
            table_size_log2=params.context_table_size_log2,
            learning_rate=params.learning_rate,
            max_count=params.max_count,
            seed=params.context_hash_seed,
        )
    else:
        body, state_init, state_final, pad_count = _rans_four_way_encode(
            qualities, read_lengths, revcomp_flags,
            table_size_log2=params.context_table_size_log2,
            learning_rate=params.learning_rate,
            max_count=params.max_count,
            seed=params.context_hash_seed,
        )

    rlt = encode_read_lengths(read_lengths)
    flags = _build_flags(pad_count=pad_count)

    header = pack_codec_header(CodecHeader(
        flags=flags,
        num_qualities=len(qualities),
        num_reads=len(read_lengths),
        rlt_compressed_len=len(rlt),
        read_length_table=rlt,
        params=params,
        state_init=state_init,
    ))

    trailer = struct.pack(
        "<IIII",
        state_final[0] & 0xFFFFFFFF,
        state_final[1] & 0xFFFFFFFF,
        state_final[2] & 0xFFFFFFFF,
        state_final[3] & 0xFFFFFFFF,
    )

    return header + body + trailer


def decode(encoded: bytes) -> tuple[bytes, list[int], list[int]]:
    """Decode with default revcomp_flags (all-zero).

    Returns ``(qualities, read_lengths, revcomp_flags_used)``.

    Note: revcomp_flags are NOT carried in the wire format; they're a
    sibling channel in the M86 pipeline. Use :func:`decode_with_metadata`
    when round-tripping a non-trivial revcomp trajectory.
    """
    return decode_with_metadata(encoded, revcomp_flags=None)


def decode_with_metadata(
    encoded: bytes,
    revcomp_flags: list[int] | None = None,
) -> tuple[bytes, list[int], list[int]]:
    """Decode ``encoded`` using the supplied ``revcomp_flags``.

    If ``revcomp_flags`` is ``None``, all-zero is used. The flags must
    match the trajectory the encoder used (or decoded qualities will
    differ from the original).
    """
    header, header_size = unpack_codec_header(encoded)
    n_qualities = header.num_qualities
    n_reads = header.num_reads
    pad_count = (header.flags >> 4) & 0x3

    read_lengths = decode_read_lengths(header.read_length_table, n_reads)

    if revcomp_flags is None:
        revcomp_flags = [0] * n_reads
    elif len(revcomp_flags) != n_reads:
        raise ValueError(
            f"revcomp_flags length {len(revcomp_flags)} != num_reads {n_reads}"
        )

    trailer_off = len(encoded) - 16
    if trailer_off < header_size:
        raise ValueError("FQZCOMP_NX16: encoded too short for body + trailer")
    body = encoded[header_size:trailer_off]
    state_final = struct.unpack_from("<IIII", encoded, trailer_off)

    n_padded = n_qualities + pad_count
    if (n_padded & 3) != 0:
        raise ValueError(
            f"FQZCOMP_NX16: n_padded {n_padded} not a multiple of 4 "
            f"(num_qualities={n_qualities}, pad_count={pad_count})"
        )

    if _HAVE_C_EXTENSION and hasattr(_ext, "decode_body_with_evolver_c"):
        out = _rans_four_way_decode_fast(
            body,
            state_init=header.state_init,
            state_final=state_final,
            n_qualities=n_qualities,
            n_padded=n_padded,
            read_lengths=read_lengths,
            revcomp_flags=revcomp_flags,
            table_size_log2=header.params.context_table_size_log2,
            learning_rate=header.params.learning_rate,
            max_count=header.params.max_count,
            seed=header.params.context_hash_seed,
        )
    else:
        evolver = _StatefulContextEvolver(
            n_qualities, n_padded, read_lengths, revcomp_flags,
            seed=header.params.context_hash_seed,
            table_size_log2=header.params.context_table_size_log2,
        )
        out = _rans_four_way_decode(
            body,
            state_init=header.state_init,
            state_final=state_final,
            n_padded=n_padded,
            evolver=evolver,
            table_size_log2=header.params.context_table_size_log2,
            learning_rate=header.params.learning_rate,
            max_count=header.params.max_count,
        )

    qualities = bytes(out[:n_qualities])
    return qualities, read_lengths, list(revcomp_flags)


# ── C extension hook (optional acceleration) ───────────────────────────

try:
    from ttio.codecs._fqzcomp_nx16 import _fqzcomp_nx16 as _ext
    _HAVE_C_EXTENSION = True
except ImportError:
    _HAVE_C_EXTENSION = False
    _ext = None


def _build_encoder_contexts(
    qualities: bytes,
    read_lengths: list[int],
    revcomp_flags: list[int],
    n_padded: int,
    seed: int,
    table_size_log2: int,
) -> list[int]:
    """Build the per-symbol context list using the encoder's prev_q ring.

    This is the canonical context-evolution sequence; ObjC + Java
    implementations port this verbatim.
    """
    n = len(qualities)
    contexts = [0] * n_padded
    pad_ctx = fqzn_context_hash(0, 0, 0, 0, 0, 0, seed, table_size_log2)
    read_idx = 0
    pos_in_read = 0
    cur_read_len = read_lengths[0] if read_lengths else 0
    cur_revcomp = revcomp_flags[0] if revcomp_flags else 0
    cumulative_read_end = cur_read_len
    prev_q0 = 0
    prev_q1 = 0
    prev_q2 = 0
    for i in range(n_padded):
        if i < n:
            if (i >= cumulative_read_end
                    and read_idx < len(read_lengths) - 1):
                read_idx += 1
                pos_in_read = 0
                cur_read_len = read_lengths[read_idx]
                cur_revcomp = revcomp_flags[read_idx]
                cumulative_read_end += cur_read_len
                prev_q0 = 0
                prev_q1 = 0
                prev_q2 = 0
            pb = position_bucket(pos_in_read, cur_read_len)
            lb = length_bucket(cur_read_len)
            contexts[i] = fqzn_context_hash(
                prev_q0, prev_q1, prev_q2, pb, cur_revcomp & 1, lb,
                seed, table_size_log2,
            )
            sym = qualities[i]
            prev_q2 = prev_q1
            prev_q1 = prev_q0
            prev_q0 = sym
            pos_in_read += 1
        else:
            contexts[i] = pad_ctx
    return contexts


def _rans_four_way_encode_fast(
    qualities: bytes,
    read_lengths: list[int],
    revcomp_flags: list[int],
    *,
    table_size_log2: int = DEFAULT_CONTEXT_TABLE_SIZE_LOG2,
    learning_rate: int = DEFAULT_LEARNING_RATE,
    max_count: int = DEFAULT_MAX_COUNT,
    seed: int = DEFAULT_CONTEXT_HASH_SEED,
):
    """C-accelerated wrapper around :func:`_rans_four_way_encode`.

    Falls back silently to the pure-Python path when the extension is
    not built. Output is byte-identical either way.
    """
    n = len(qualities)
    n_padded = n + ((-n) & 3)
    if hasattr(_ext, "build_encoder_contexts_c"):
        contexts = _ext.build_encoder_contexts_c(
            qualities, read_lengths, revcomp_flags, n_padded,
            seed, table_size_log2,
        )
    else:
        contexts = _build_encoder_contexts(
            qualities, read_lengths, revcomp_flags, n_padded,
            seed, table_size_log2,
        )
    return _ext.encode_body_c(
        qualities, contexts, n_padded,
        table_size_log2, learning_rate, max_count,
    )


def _rans_four_way_decode_fast(
    body: bytes,
    state_init: tuple[int, int, int, int],
    state_final: tuple[int, int, int, int],
    n_qualities: int,
    n_padded: int,
    read_lengths: list[int],
    revcomp_flags: list[int],
    *,
    table_size_log2: int = DEFAULT_CONTEXT_TABLE_SIZE_LOG2,
    learning_rate: int = DEFAULT_LEARNING_RATE,
    max_count: int = DEFAULT_MAX_COUNT,
    seed: int = DEFAULT_CONTEXT_HASH_SEED,
) -> bytes:
    """C-accelerated decode with embedded context evolution.

    Mirrors :func:`_rans_four_way_decode` byte-for-byte but evolves the
    context vector inside the Cython kernel (no per-symbol Python call into
    :class:`_StatefulContextEvolver`). Output is byte-identical to the
    pure-Python reference.
    """
    return _ext.decode_body_with_evolver_c(
        body, state_init, state_final,
        n_qualities, n_padded,
        list(read_lengths), list(revcomp_flags),
        seed, table_size_log2, learning_rate, max_count,
    )


__all__ = [
    "encode",
    "decode",
    "decode_with_metadata",
    "CodecHeader",
    "ContextModelParams",
    "pack_codec_header",
    "unpack_codec_header",
    "pack_context_model_params",
    "unpack_context_model_params",
    "encode_read_lengths",
    "decode_read_lengths",
    "fqzn_context_hash",
    "position_bucket",
    "length_bucket",
    "MAGIC",
    "VERSION",
    "DEFAULT_CONTEXT_HASH_SEED",
    "DEFAULT_LEARNING_RATE",
    "DEFAULT_MAX_COUNT",
    "DEFAULT_CONTEXT_TABLE_SIZE_LOG2",
    "RANS_L",
    "RANS_INITIAL_STATE",
    "NUM_STREAMS",
]
