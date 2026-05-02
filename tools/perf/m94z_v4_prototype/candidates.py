"""Five candidate context-model functions for M94.Z V4 prototype.

Each ``derive_contexts_<id>`` returns ``(sparse_seq_uint32,
n_active_estimate)``. The harness applies first-encounter dense remap
+ runs the C kernel via :mod:`encode_pipeline`. Bit budgets per spec
§4.

All quantizations are value-aligned ``(q - 33) >> N``, NOT V3's
``q & ((1<<N)-1)`` low-bit hash. ``prev_q`` resets to 0 at every
read start. Pad positions (i >= len(qualities)) get the candidate's
own pad context (whatever ``m94z_context(0, 0, 0, ...)`` resolves to
for that bit packing).
"""

from __future__ import annotations

import numpy as np

# --- Quantization helpers (vectorized, uint8 input) ----------------------

def _q_to_4bit(q: np.ndarray) -> np.ndarray:
    """Phred-aligned 4-bit quantization: 16 bins spanning Q0..Q63."""
    return ((q.astype(np.int64) - 33) >> 2).clip(0, 15).astype(np.int64)


def _q_to_3bit(q: np.ndarray) -> np.ndarray:
    """Phred-aligned 3-bit quantization: 8 bins spanning Q0..Q63."""
    return ((q.astype(np.int64) - 33) >> 3).clip(0, 7).astype(np.int64)


def _q_to_2bit(q: np.ndarray) -> np.ndarray:
    """Phred-aligned 2-bit quantization: Q0-15 / 16-31 / 32-47 / 48+."""
    return ((q.astype(np.int64) - 33) >> 4).clip(0, 3).astype(np.int64)


def _q_to_8bit(q: np.ndarray) -> np.ndarray:
    """Full Phred precision, single byte: q - 33 clamped to [0, 255]."""
    return (q.astype(np.int64) - 33).clip(0, 255).astype(np.int64)


# --- Length-bucket (CRAM 3.1 boundaries) ---------------------------------

# Bucket 0: read_length <= 50; bucket 7: > 10000 (catch-all)
_LENGTH_BOUNDARIES = np.array([50, 100, 150, 200, 300, 1000, 10000],
                              dtype=np.int64)


def _length_bucket_3bit(read_lens: np.ndarray) -> np.ndarray:
    """Per-read length bucket in [0, 7] using CRAM's boundary set.

    bucket = first index i where read_length <= boundary[i], or 7.
    """
    # np.searchsorted with side='left' returns the first i s.t.
    # read_lens <= _LENGTH_BOUNDARIES[i], clipped to 7.
    return np.minimum(np.searchsorted(_LENGTH_BOUNDARIES, read_lens), 7)


def _length_bucket_4bit(read_lens: np.ndarray) -> np.ndarray:
    """Finer 16-bucket length conditioning (c3 only).

    Splits each CRAM bucket in two via midpoints. Boundaries:
    25, 50, 75, 100, 125, 150, 175, 200, 250, 300, 500, 1000, 5000, 10000, 50000.
    """
    boundaries = np.array(
        [25, 50, 75, 100, 125, 150, 175, 200,
         250, 300, 500, 1000, 5000, 10000, 50000],
        dtype=np.int64,
    )
    return np.minimum(np.searchsorted(boundaries, read_lens), 15)


# --- c0: V3 baseline mirror (sloc=14, low-bit hash prev_q ring) ---------

# Bit layout: prev_q (12) | pos_bucket (2, << 12) | revcomp (1, << 14)
# Then mask to sloc=14. This MIRRORS production
# _build_context_seq_arr_vec at qbits=12, pbits=2, sloc=14.

C0_QBITS = 12
C0_PBITS = 2
C0_SLOC = 14


def derive_contexts_c0(
    qualities: bytes,
    read_lengths: np.ndarray,
    revcomp_flags: np.ndarray,
    n_padded: int,
) -> tuple[np.ndarray, int]:
    """V3-baseline mirror. sloc=14. Low-bit hash quantization (q & 0xF)."""
    qmask = (1 << C0_QBITS) - 1
    pmask = (1 << C0_PBITS) - 1
    smask = (1 << C0_SLOC) - 1
    n_buckets = 1 << C0_PBITS
    shift = max(1, C0_QBITS // 3)
    shift_mask = (1 << shift) - 1

    n = len(qualities)
    pad_ctx = 0  # m94z_context(0, 0, 0, ...) is 0 for any sloc
    if n_padded == 0:
        return np.zeros(0, dtype=np.uint32), 0

    n_reads = read_lengths.shape[0]
    if n_reads == 0 or n == 0:
        return np.full(n_padded, pad_ctx, dtype=np.uint32), 1

    qual_arr = np.frombuffer(qualities, dtype=np.uint8)
    starts = np.empty(n_reads, dtype=np.int64)
    starts[0] = 0
    if n_reads > 1:
        np.cumsum(read_lengths[:-1], out=starts[1:])

    contexts = np.full(n_padded, pad_ctx, dtype=np.uint32)
    revcomp_term = (revcomp_flags.astype(np.int64) & 1) << (
        C0_QBITS + C0_PBITS
    )
    prev_q = np.zeros(n_reads, dtype=np.int64)

    max_len = int(read_lengths.max())
    denom = np.maximum(read_lengths, 1)
    for p in range(max_len):
        active = read_lengths > p
        if not active.any():
            break
        flat_pos = starts + p
        if p == 0:
            pb = np.zeros(n_reads, dtype=np.int64)
        else:
            pb = np.minimum(n_buckets - 1, (p * n_buckets) // denom)
        ctx_p = (
            (prev_q & qmask)
            | ((pb & pmask) << C0_QBITS)
            | revcomp_term
        ) & smask
        active_flat = flat_pos[active]
        contexts[active_flat] = ctx_p[active].astype(np.uint32)
        sym_p = qual_arr[active_flat].astype(np.int64)
        # c0 uses LOW-BIT HASH on qualities (q & shift_mask), matching V3
        prev_q[active] = (
            (prev_q[active] << shift) | (sym_p & shift_mask)
        ) & qmask

    return contexts, int(np.unique(contexts).shape[0])


# --- c1: CRAM-faithful, decreasing-precision history (sloc=17) -----------

# Bit layout (low -> high):
#   bits 0..3   prev_q[0]      4-bit value-aligned   (16 bins)
#   bits 4..6   prev_q[1]      3-bit value-aligned   (8 bins)
#   bits 7..8   prev_q[2]      2-bit value-aligned   (4 bins)
#   bits 9..12  pos_bucket     4-bit                 (16 buckets)
#   bits 13..15 length_bucket  3-bit                 (CRAM bounds)
#   bit  16     revcomp        1-bit
# Total: 17 bits, sloc=17.

C1_SLOC = 17
C1_PBITS = 4
C1_PB_BUCKETS = 1 << C1_PBITS  # 16


def derive_contexts_c1(
    qualities: bytes,
    read_lengths: np.ndarray,
    revcomp_flags: np.ndarray,
    n_padded: int,
) -> tuple[np.ndarray, int]:
    """CRAM-faithful: 4 + 3 + 2 prev_q + 4 pos + 3 length + 1 revcomp."""
    smask = (1 << C1_SLOC) - 1
    n = len(qualities)
    pad_ctx = 0  # all features zero
    if n_padded == 0:
        return np.zeros(0, dtype=np.uint32), 0

    n_reads = read_lengths.shape[0]
    if n_reads == 0 or n == 0:
        return np.full(n_padded, pad_ctx, dtype=np.uint32), 1

    qual_arr = np.frombuffer(qualities, dtype=np.uint8)
    starts = np.empty(n_reads, dtype=np.int64)
    starts[0] = 0
    if n_reads > 1:
        np.cumsum(read_lengths[:-1], out=starts[1:])

    # Per-read constant features (length_bucket, revcomp_term)
    length_buckets = _length_bucket_3bit(read_lengths)         # 0..7
    revcomp_bits = (revcomp_flags.astype(np.int64) & 1)        # 0..1
    static_term = (length_buckets << 13) | (revcomp_bits << 16)  # int64

    contexts = np.full(n_padded, pad_ctx, dtype=np.uint32)
    # Per-read history state, value-aligned: prev_q[0]=4b, [1]=3b, [2]=2b
    prev_q0 = np.zeros(n_reads, dtype=np.int64)
    prev_q1 = np.zeros(n_reads, dtype=np.int64)
    prev_q2 = np.zeros(n_reads, dtype=np.int64)

    max_len = int(read_lengths.max())
    denom = np.maximum(read_lengths, 1)
    for p in range(max_len):
        active = read_lengths > p
        if not active.any():
            break
        flat_pos = starts + p
        if p == 0:
            pb = np.zeros(n_reads, dtype=np.int64)
        else:
            pb = np.minimum(C1_PB_BUCKETS - 1,
                            (p * C1_PB_BUCKETS) // denom)
        ctx_p = (
            (prev_q0 & 0xF)
            | ((prev_q1 & 0x7) << 4)
            | ((prev_q2 & 0x3) << 7)
            | ((pb & 0xF) << 9)
            | static_term
        ) & smask
        active_flat = flat_pos[active]
        contexts[active_flat] = ctx_p[active].astype(np.uint32)
        # Shift the history: prev_q[2] <- prev_q[1] (truncated to 2 bits),
        # prev_q[1] <- prev_q[0] (truncated to 3 bits), prev_q[0] <- new sym.
        sym_p = qual_arr[active_flat]
        # Compute new value-aligned bins for ACTIVE reads only
        new_q0 = _q_to_4bit(sym_p)
        # Save existing prev_q before overwrite
        old_q0 = prev_q0[active]
        old_q1 = prev_q1[active]
        prev_q2[active] = old_q1 & 0x3   # 3-bit -> 2-bit
        prev_q1[active] = old_q0 & 0x7   # 4-bit -> 3-bit
        prev_q0[active] = new_q0

    return contexts, int(np.unique(contexts).shape[0])


# --- c2: Equal-precision history, drop length (sloc=17) ------------------

C2_SLOC = 17
C2_PBITS = 4
C2_PB_BUCKETS = 1 << C2_PBITS  # 16


def derive_contexts_c2(
    qualities: bytes,
    read_lengths: np.ndarray,
    revcomp_flags: np.ndarray,
    n_padded: int,
) -> tuple[np.ndarray, int]:
    """Equal-precision: 4+4+4 prev_q + 4 pos + 1 revcomp (no length)."""
    smask = (1 << C2_SLOC) - 1
    n = len(qualities)
    if n_padded == 0:
        return np.zeros(0, dtype=np.uint32), 0
    n_reads = read_lengths.shape[0]
    if n_reads == 0 or n == 0:
        return np.zeros(n_padded, dtype=np.uint32), 1

    qual_arr = np.frombuffer(qualities, dtype=np.uint8)
    starts = np.empty(n_reads, dtype=np.int64)
    starts[0] = 0
    if n_reads > 1:
        np.cumsum(read_lengths[:-1], out=starts[1:])

    revcomp_bits = (revcomp_flags.astype(np.int64) & 1)
    revcomp_term = revcomp_bits << 16

    contexts = np.zeros(n_padded, dtype=np.uint32)
    prev_q0 = np.zeros(n_reads, dtype=np.int64)
    prev_q1 = np.zeros(n_reads, dtype=np.int64)
    prev_q2 = np.zeros(n_reads, dtype=np.int64)

    max_len = int(read_lengths.max())
    denom = np.maximum(read_lengths, 1)
    for p in range(max_len):
        active = read_lengths > p
        if not active.any():
            break
        flat_pos = starts + p
        if p == 0:
            pb = np.zeros(n_reads, dtype=np.int64)
        else:
            pb = np.minimum(C2_PB_BUCKETS - 1,
                            (p * C2_PB_BUCKETS) // denom)
        ctx_p = (
            (prev_q0 & 0xF)
            | ((prev_q1 & 0xF) << 4)
            | ((prev_q2 & 0xF) << 8)
            | ((pb & 0xF) << 12)
            | revcomp_term
        ) & smask
        active_flat = flat_pos[active]
        contexts[active_flat] = ctx_p[active].astype(np.uint32)
        sym_p = qual_arr[active_flat]
        new_q0 = _q_to_4bit(sym_p)
        old_q0 = prev_q0[active]
        old_q1 = prev_q1[active]
        prev_q2[active] = old_q1
        prev_q1[active] = old_q0
        prev_q0[active] = new_q0

    return contexts, int(np.unique(contexts).shape[0])


# --- c3: Length-heavy, single full-Phred prev_q (sloc=17) ----------------

C3_SLOC = 17
C3_PBITS = 4
C3_PB_BUCKETS = 1 << C3_PBITS  # 16


def derive_contexts_c3(
    qualities: bytes,
    read_lengths: np.ndarray,
    revcomp_flags: np.ndarray,
    n_padded: int,
) -> tuple[np.ndarray, int]:
    """Length-heavy: 8 prev_q (full Phred) + 4 pos + 4 length(16) + 1 revcomp."""
    smask = (1 << C3_SLOC) - 1
    n = len(qualities)
    if n_padded == 0:
        return np.zeros(0, dtype=np.uint32), 0
    n_reads = read_lengths.shape[0]
    if n_reads == 0 or n == 0:
        return np.zeros(n_padded, dtype=np.uint32), 1

    qual_arr = np.frombuffer(qualities, dtype=np.uint8)
    starts = np.empty(n_reads, dtype=np.int64)
    starts[0] = 0
    if n_reads > 1:
        np.cumsum(read_lengths[:-1], out=starts[1:])

    length_buckets = _length_bucket_4bit(read_lengths)        # 0..15
    revcomp_bits = (revcomp_flags.astype(np.int64) & 1)
    static_term = (length_buckets << 12) | (revcomp_bits << 16)

    contexts = np.zeros(n_padded, dtype=np.uint32)
    prev_q0 = np.zeros(n_reads, dtype=np.int64)

    max_len = int(read_lengths.max())
    denom = np.maximum(read_lengths, 1)
    for p in range(max_len):
        active = read_lengths > p
        if not active.any():
            break
        flat_pos = starts + p
        if p == 0:
            pb = np.zeros(n_reads, dtype=np.int64)
        else:
            pb = np.minimum(C3_PB_BUCKETS - 1,
                            (p * C3_PB_BUCKETS) // denom)
        ctx_p = (
            (prev_q0 & 0xFF)
            | ((pb & 0xF) << 8)
            | static_term
        ) & smask
        active_flat = flat_pos[active]
        contexts[active_flat] = ctx_p[active].astype(np.uint32)
        sym_p = qual_arr[active_flat]
        prev_q0[active] = _q_to_8bit(sym_p)

    return contexts, int(np.unique(contexts).shape[0])


# --- Candidate registry --------------------------------------------------

# (name, sloc, derive_function, description)
CANDIDATES = [
    ("c0", C0_SLOC, derive_contexts_c0,
     "V3 baseline mirror (sloc=14, low-bit hash prev_q ring)"),
    ("c1", C1_SLOC, derive_contexts_c1,
     "CRAM-faithful: 4+3+2 prev_q + 4 pos + 3 length + 1 revcomp (sloc=17)"),
    ("c2", C2_SLOC, derive_contexts_c2,
     "Equal-precision history, drop length: 4+4+4 prev_q + 4 pos + 1 revcomp (sloc=17)"),
    ("c3", C3_SLOC, derive_contexts_c3,
     "Length-heavy: 8 prev_q + 4 pos + 4 length + 1 revcomp (sloc=17)"),
]
