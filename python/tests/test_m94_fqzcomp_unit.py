"""TTI-O M94 — FQZCOMP_NX16 unit tests.

Covers: enum value, header pack/unpack, read-length sidecar round-trip,
context-hash determinism, adaptive-update schedule, and small round-trip
encode/decode validation.
"""
from __future__ import annotations

import struct

import pytest

from ttio.codecs.fqzcomp_nx16 import (
    CodecHeader,
    ContextModelParams,
    DEFAULT_CONTEXT_HASH_SEED,
    DEFAULT_LEARNING_RATE,
    DEFAULT_MAX_COUNT,
    HEADER_FIXED_PREFIX,
    MAGIC,
    NUM_STREAMS,
    RANS_INITIAL_STATE,
    VERSION,
    _adaptive_update,
    _new_count_table,
    decode,
    decode_read_lengths,
    decode_with_metadata,
    encode,
    encode_read_lengths,
    fqzn_context_hash,
    length_bucket,
    pack_codec_header,
    pack_context_model_params,
    position_bucket,
    unpack_codec_header,
    unpack_context_model_params,
)
from ttio.enums import Compression


def test_compression_enum_value_is_10():
    """FQZCOMP_NX16 codec id is 10 per spec §3 M94."""
    assert int(Compression.FQZCOMP_NX16) == 10


def test_compression_enum_name():
    assert Compression.FQZCOMP_NX16.name == "FQZCOMP_NX16"


# ── Header pack/unpack ─────────────────────────────────────────────────


def test_pack_unpack_context_model_params_round_trip():
    p = ContextModelParams(
        context_table_size_log2=12,
        learning_rate=16,
        max_count=4096,
        freq_table_init=0,
        context_hash_seed=0xC0FFEE,
    )
    blob = pack_context_model_params(p)
    assert len(blob) == 16
    p2 = unpack_context_model_params(blob)
    assert p == p2


def test_pack_unpack_codec_header_round_trip():
    rlt = encode_read_lengths([10, 20, 30])
    h = CodecHeader(
        flags=0x0F,
        num_qualities=60,
        num_reads=3,
        rlt_compressed_len=len(rlt),
        read_length_table=rlt,
        params=ContextModelParams(),
        state_init=(RANS_INITIAL_STATE,) * 4,
    )
    blob = pack_codec_header(h)
    h2, consumed = unpack_codec_header(blob)
    assert consumed == len(blob)
    assert h2 == h


def test_unpack_rejects_bad_magic():
    bad = b"XXXX" + bytes(50)
    with pytest.raises(ValueError, match="bad magic"):
        unpack_codec_header(bad)


def test_unpack_rejects_bad_version():
    blob = bytearray(MAGIC + struct.pack("<BB", 99, 0) + bytes(20))
    with pytest.raises(ValueError, match="unsupported version"):
        unpack_codec_header(bytes(blob))


def test_unpack_rejects_reserved_flag_bits():
    bad_flags = 0xC0  # bits 6-7 set
    blob = bytearray(MAGIC + struct.pack("<BBQII", 1, bad_flags, 0, 0, 0))
    blob += pack_context_model_params(ContextModelParams())
    blob += struct.pack("<IIII", 0, 0, 0, 0)
    with pytest.raises(ValueError, match="reserved flag bits"):
        unpack_codec_header(bytes(blob))


# ── Read-length table sidecar ─────────────────────────────────────────


@pytest.mark.parametrize("n_reads", [0, 1, 4, 100, 5_000])
def test_read_length_table_round_trip(n_reads):
    import random
    rng = random.Random(0xBEEF)
    lengths = [rng.randrange(1, 500) for _ in range(n_reads)]
    encoded = encode_read_lengths(lengths)
    decoded = decode_read_lengths(encoded, n_reads)
    assert decoded == lengths


# ── Context-hash determinism + spread ─────────────────────────────────


def test_context_hash_deterministic():
    h1 = fqzn_context_hash(30, 31, 32, 5, 0, 3, DEFAULT_CONTEXT_HASH_SEED)
    h2 = fqzn_context_hash(30, 31, 32, 5, 0, 3, DEFAULT_CONTEXT_HASH_SEED)
    assert h1 == h2


def test_context_hash_in_range():
    """Hash output fits in the 12-bit context table."""
    for q in range(0, 256, 31):
        h = fqzn_context_hash(q, q ^ 0xFF, 0, 7, 1, 4, 0xC0FFEE)
        assert 0 <= h < 4096


def test_context_hash_distinct_inputs_distinct_outputs():
    """Adjacent context vectors should rarely collide.

    For 1000 distinct inputs hashing to 4096 buckets, the birthday
    bound says ~893 unique values (= 4096 × (1 − exp(−1000/4096))).
    Allow a 10% slack for the SplitMix64 mixer's distribution.
    """
    seen = set()
    n = 1000
    for q in range(50):
        for p in range(20):
            seen.add(
                fqzn_context_hash(q, q + 1, q + 2, p % 16, 0, 3,
                                  DEFAULT_CONTEXT_HASH_SEED)
            )
    # Birthday bound: ~893 unique for 1000 inputs in 4096 buckets.
    assert len(seen) >= 700, (
        f"context hash diversity too low: {len(seen)}/{n} unique "
        f"(expected ≥ ~700 by birthday bound)"
    )


# ── Adaptive update schedule ──────────────────────────────────────────


def test_adaptive_update_increments():
    count = _new_count_table()
    _adaptive_update(count, 30)
    assert count[30] == 1 + DEFAULT_LEARNING_RATE


def test_adaptive_update_renorm_fires_at_correct_step():
    """Pinch point of cross-language byte-exactness — the renorm
    schedule MUST match across implementations.

    Initial count[s] = 1. After each adaptive_update(s) the count
    grows by LEARNING_RATE = 16. Renorm fires when count > MAX_COUNT
    = 4096. With initial count 1 and increment 16, we need
    ``1 + N*16 > 4096`` → N > 256, so the 257th update on a single
    symbol triggers renorm.

    Pre-renorm count[s] before update 257 = 1 + 256*16 = 4097.
    Wait — 1 + 256*16 = 4097 > 4096 — so renorm fired on update 256.
    Let's recount: update 256 sees count[s] = 1 + 256*16 = 4097, so
    renorm halves all to 2048 (count[s] = 2048; entries that were 1
    halve to 0 → floor 1).
    """
    count = _new_count_table()
    triggered_step = None
    for step in range(1, 300):
        _adaptive_update(count, 30)
        # Count[30] before this update was 1 + (step-1)*16; after this
        # update it's 1 + step*16 unless renorm fired.
        # First step where pre-update count[30] > MAX_COUNT happens
        # when (1 + step*16) > 4096 i.e. step >= 256.
        # On step 256: pre-renorm count[30] = 1 + 256*16 = 4097, so
        # renorm fires immediately and count[30] drops to 4097 // 2 = 2048.
        if count[30] < (1 + step * 16):
            triggered_step = step
            break
    assert triggered_step == 256, (
        f"renorm fired at step {triggered_step}, expected 256"
    )
    assert count[30] == 2048
    # Other entries: started at 1, halved with floor → 1 stays at 1.
    for k in range(256):
        if k != 30:
            assert count[k] == 1


# ── Position + length buckets ─────────────────────────────────────────


def test_position_bucket_endpoints():
    assert position_bucket(0, 100) == 0
    assert position_bucket(99, 100) == 15
    assert position_bucket(50, 100) == 8


def test_length_bucket_boundaries():
    assert length_bucket(1) == 0
    assert length_bucket(49) == 0
    assert length_bucket(50) == 1
    assert length_bucket(100) == 2
    assert length_bucket(150) == 3
    assert length_bucket(200) == 4
    assert length_bucket(300) == 5
    assert length_bucket(1000) == 6
    assert length_bucket(10_000) == 7
    assert length_bucket(50_000) == 7


# ── End-to-end small round trip ───────────────────────────────────────


def test_round_trip_4_reads_minimum():
    """Smallest valid input — 4 reads × 4 qualities each (alignment with
    the 4-way rANS interleave)."""
    qualities = b"@@@@" * 4  # 16 bytes — sum of read lengths must equal len
    read_lengths = [4, 4, 4, 4]
    revcomp_flags = [0, 0, 0, 0]
    enc = encode(qualities, read_lengths, revcomp_flags)
    decoded_q, decoded_rl, decoded_rc = decode_with_metadata(
        enc, revcomp_flags=revcomp_flags,
    )
    assert decoded_q == qualities
    assert decoded_rl == read_lengths
    assert decoded_rc == revcomp_flags


def test_round_trip_single_read_zero_pad():
    """Single read with non-multiple-of-4 length exercises padding."""
    qualities = b"IIIII"  # 5 bytes — pad_count = 3
    read_lengths = [5]
    revcomp_flags = [0]
    enc = encode(qualities, read_lengths, revcomp_flags)
    header, _ = unpack_codec_header(enc)
    pad_count = (header.flags >> 4) & 0x3
    assert pad_count == 3
    decoded_q, _, _ = decode_with_metadata(enc, revcomp_flags=revcomp_flags)
    assert decoded_q == qualities


def test_round_trip_typical_illumina_synthetic():
    """100 reads × 100bp, deterministic synthetic Phred profile."""
    import random
    rng = random.Random(0xBEEF)
    n_reads = 100
    read_len = 100
    read_lengths = [read_len] * n_reads
    revcomp_flags = [0] * n_reads
    quals = bytearray()
    for _ in range(n_reads * read_len):
        # Bias toward Q30, range Q20-Q40 (Phred bytes Q+33).
        q = max(20, min(40, int(rng.gauss(30, 5))))
        quals.append(q + 33)
    enc = encode(bytes(quals), read_lengths, revcomp_flags)
    decoded_q, decoded_rl, _ = decode_with_metadata(
        enc, revcomp_flags=revcomp_flags,
    )
    assert decoded_q == bytes(quals)
    assert decoded_rl == read_lengths


def test_round_trip_revcomp_majority_changes_bytes():
    """Setting revcomp_flags must change the encoded bytes when the input
    has enough symbol diversity that contexts encounter different
    symbol distributions (the revcomp bit feeds the context hash).

    With a constant input every context sees the same single symbol so
    the M-normalised freq tables happen to agree across context buckets;
    pin this test on a varied input.
    """
    import random
    rng = random.Random(0xCAFE)
    n_reads = 4
    read_len = 50
    read_lengths = [read_len] * n_reads
    qualities = bytes(rng.randrange(33, 74) for _ in range(n_reads * read_len))
    enc_fwd = encode(qualities, read_lengths, [0] * n_reads)
    enc_rev = encode(qualities, read_lengths, [1] * n_reads)
    assert enc_fwd != enc_rev
    assert decode_with_metadata(enc_fwd, [0] * n_reads)[0] == qualities
    assert decode_with_metadata(enc_rev, [1] * n_reads)[0] == qualities


def test_decode_validates_state_at_end():
    """Tampered final state should raise."""
    qualities = b"IIII" * 4
    read_lengths = [4] * 4
    enc = encode(qualities, read_lengths, [0] * 4)
    # Flip a bit in the trailer (state_final).
    tampered = bytearray(enc)
    tampered[-1] ^= 0xFF
    with pytest.raises(ValueError, match="post-decode|substream|state"):
        decode_with_metadata(bytes(tampered), [0] * 4)


def test_encode_validates_length_consistency():
    with pytest.raises(ValueError, match="sum.read_lengths"):
        encode(b"AAA", read_lengths=[2], revcomp_flags=[0])


