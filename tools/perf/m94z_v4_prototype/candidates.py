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


# --- Candidate registry --------------------------------------------------

# (name, sloc, derive_function, description)
CANDIDATES = [
    ("c0", C0_SLOC, derive_contexts_c0,
     "V3 baseline mirror (sloc=14, low-bit hash prev_q ring)"),
]
