"""M94.Z byte-pairing math verification (spec §2 acceptance check).

For all valid (T, f, c, x_in) tuples, the encoder pop count MUST equal
the decoder pull count. This is the M94.X failure mode — at 8-bit renorm
with non-power-of-2 T, ``floor(b·L / T) * f`` rounding error could fit
inside a single chunk and break byte-pairing for some inputs.

M94.Z's parameter triple (L=2^15, B=16, T=4096) makes ``b·L = 2^31``
exactly divisible by T, so ``x_max = 2^19 * f`` is exact. This test
verifies that property holds for 1000 random (count, sym, x_in) tuples.
"""
from __future__ import annotations

import random

import pytest

from ttio.codecs.fqzcomp_nx16_z import (
    B,
    B_BITS,
    B_MASK,
    L,
    STATE_MAX,
    T,
    T_BITS,
    T_MASK,
    X_MAX_PREFACTOR,
    cumulative,
    normalise_to_total,
)


def _encoder_step(x: int, f: int, c: int) -> tuple[int, list[int]]:
    """Replay one encoder step in isolation. Returns (x_new, popped_chunks).

    ``popped_chunks`` is the list of 16-bit chunks emitted (low bits first).
    Encoder semantics from spec §2.1 / fqzcomp_nx16_z._encode_one_step.
    """
    chunks: list[int] = []
    x_max = X_MAX_PREFACTOR * f
    while x >= x_max:
        chunks.append(x & B_MASK)
        x >>= B_BITS
    x_new = (x // f) * T + (x % f) + c
    return x_new, chunks


def _decoder_step(x: int, freq: list[int], cum: list[int],
                  chunks_to_pull: list[int]) -> tuple[int, int, int]:
    """Replay one decoder step in isolation.

    Pulls chunks from ``chunks_to_pull`` (in REVERSE pop-order — i.e.
    decoder consumes the chunks the encoder emitted, but in opposite
    sequence since the byte stream was reversed at finalisation).

    Returns (sym, x_new, n_chunks_pulled).
    """
    slot = x & T_MASK
    # Find sym such that cum[sym] <= slot < cum[sym+1].
    sym = 0
    for s in range(256):
        if cum[s + 1] > slot:
            sym = s
            break
    f = freq[sym]
    c = cum[sym]
    x = (x >> T_BITS) * f + slot - c
    pulled = 0
    while x < L:
        if pulled >= len(chunks_to_pull):
            raise AssertionError("decoder underflow: not enough chunks")
        chunk = chunks_to_pull[pulled]
        pulled += 1
        x = (x << B_BITS) | chunk
    return sym, x, pulled


def test_xmax_is_exact_for_all_valid_f():
    """Spec §2.4 invariant: ``x_max = (b*L / T) * f`` is exact (no floor)."""
    for f in range(1, T):
        x_max_exact = (B * L // T) * f
        x_max_formula = X_MAX_PREFACTOR * f
        assert x_max_formula == x_max_exact, (
            f"x_max mismatch at f={f}: {x_max_formula} != {x_max_exact}"
        )


def test_post_encode_state_in_bounds_for_all_freq_table_shapes():
    """For arbitrary normalised freq tables and any valid x_in, the
    encode formula must produce x_out in [0, b*L)."""
    rng = random.Random(0xC001D00D)
    for trial in range(200):
        # Random distinct symbols, random raw counts.
        n_symbols = rng.randint(1, 64)
        raw = [0] * 256
        for _ in range(rng.randint(n_symbols, 10_000)):
            raw[rng.randrange(256)] += 1
        # Force at least n_symbols distinct.
        for s in range(n_symbols):
            if raw[s] == 0:
                raw[s] = 1
        freq = normalise_to_total(raw, T)
        cum = cumulative(freq)

        for _ in range(5):
            sym = rng.choice([s for s in range(256) if freq[s] > 0])
            f = freq[sym]
            c = cum[sym]
            # x_in in valid range [L, b*L)
            x_in = rng.randint(L, STATE_MAX - 1)
            x_out, _ = _encoder_step(x_in, f, c)
            assert 0 < x_out < STATE_MAX, (
                f"x_out={x_out} outside [0, {STATE_MAX}) "
                f"for x_in={x_in}, f={f}, c={c}"
            )


def test_byte_pairing_pop_count_equals_pull_count():
    """The core invariant: encoder pops N chunks → decoder pulls exactly N.

    Sample 1000 random (freq_table, sym, x_in) tuples and verify.
    """
    rng = random.Random(0xB17EBA17)
    n_trials = 1000
    for trial in range(n_trials):
        # Build a random freq table summing to T.
        raw = [0] * 256
        n_symbols = rng.randint(1, 64)
        for _ in range(rng.randint(n_symbols, 5_000)):
            raw[rng.randrange(256)] += 1
        # Force at least one count
        if sum(raw) == 0:
            raw[0] = 1
        freq = normalise_to_total(raw, T)
        cum = cumulative(freq)

        sym = rng.choice([s for s in range(256) if freq[s] > 0])
        f = freq[sym]
        c = cum[sym]
        x_in = rng.randint(L, STATE_MAX - 1)

        # ENCODE: produces (x_out, popped chunks low-bit-first)
        x_out, popped = _encoder_step(x_in, f, c)
        # x_out becomes the "post-encode state" the decoder will see.
        # The decoder runs forward and starts from x_out, then must
        # produce sym and recover x_in.

        # The encoder emitted `popped` in pop order: chunk0 = low chunk
        # of original x, chunk1 = next, ... Stream finalisation reverses
        # so the decoder, scanning forward, sees chunks in REVERSE pop
        # order. Pull invariant: same count, but consumed in opposite seq.
        chunks_for_decoder = list(reversed(popped))

        sym_out, x_recovered, pulled = _decoder_step(
            x_out, freq, cum, chunks_for_decoder,
        )

        assert sym_out == sym, (
            f"trial {trial}: sym mismatch: enc={sym} dec={sym_out} "
            f"x_in={x_in} f={f} c={c} x_out={x_out}"
        )
        assert pulled == len(popped), (
            f"trial {trial}: pop/pull mismatch: pop={len(popped)} "
            f"pull={pulled} x_in={x_in} f={f} c={c} x_out={x_out}"
        )
        assert x_recovered == x_in, (
            f"trial {trial}: state mismatch: x_in={x_in} recovered={x_recovered}"
        )


def test_byte_pairing_at_boundaries():
    """Test boundary cases explicitly: x at exactly x_max, x = L,
    x = b*L - 1, f = 1, f = T-1."""
    raw = [0] * 256
    raw[42] = 100
    raw[100] = 50
    raw[200] = 1
    freq = normalise_to_total(raw, T)
    cum = cumulative(freq)

    test_cases = []
    for sym in (42, 100, 200):
        f = freq[sym]
        if f == 0:
            continue
        c = cum[sym]
        x_max = X_MAX_PREFACTOR * f
        test_cases.append((sym, f, c, L))             # x = L (steady-state floor)
        test_cases.append((sym, f, c, L + 1))
        test_cases.append((sym, f, c, x_max - 1))     # just below threshold
        test_cases.append((sym, f, c, x_max))         # at threshold (must pop)
        test_cases.append((sym, f, c, x_max + 1))     # above threshold
        test_cases.append((sym, f, c, STATE_MAX - 1)) # x just below b*L

    for sym, f, c, x_in in test_cases:
        x_out, popped = _encoder_step(x_in, f, c)
        chunks_for_decoder = list(reversed(popped))
        sym_dec, x_rec, pulled = _decoder_step(
            x_out, freq, cum, chunks_for_decoder,
        )
        assert sym_dec == sym, (
            f"boundary case sym={sym} f={f} x_in={x_in}: "
            f"got sym_dec={sym_dec}"
        )
        assert pulled == len(popped), (
            f"boundary case sym={sym} f={f} x_in={x_in}: "
            f"pop={len(popped)} pull={pulled}"
        )
        assert x_rec == x_in
        assert L <= x_out < STATE_MAX, (
            f"x_out={x_out} outside steady-state for sym={sym}"
        )


def test_byte_pairing_at_all_freq_values():
    """For every f in [1, T-1] and a representative x_in, verify
    pairing. Catches the M94.X failure: any rounding-error in x_max."""
    rng = random.Random(0xFEEDF00D)
    for f in range(1, T):
        # Build a freq table with this freq at sym=0 and the rest as 0/spread.
        freq = [0] * 256
        freq[0] = f
        # Distribute the remaining T-f among other symbols.
        remaining = T - f
        if remaining > 0:
            # Put it all on sym=1 if possible; ensure sum == T.
            freq[1] = remaining
        cum = cumulative(freq)
        assert sum(freq) == T

        # Test sym=0 (the variable-f symbol) at several x_in values.
        sym = 0
        c = cum[0]
        for x_in in (L, L + 1, X_MAX_PREFACTOR * f - 1,
                     X_MAX_PREFACTOR * f, STATE_MAX - 1):
            if x_in < L or x_in >= STATE_MAX:
                continue
            x_out, popped = _encoder_step(x_in, f, c)
            chunks_for_decoder = list(reversed(popped))
            sym_dec, x_rec, pulled = _decoder_step(
                x_out, freq, cum, chunks_for_decoder,
            )
            assert sym_dec == sym
            assert pulled == len(popped)
            assert x_rec == x_in
