"""M86 — genomic signal-channel codec wiring tests.

Covers the original eleven test cases (Phase A), six Phase D cases,
and six Phase E cases (HANDOFF.md M86 Phase E §6.1):
  1.  Round-trip sequences via rANS order-0.
  2.  Round-trip sequences via rANS order-1.
  3.  Round-trip sequences via BASE_PACK (pure ACGT).
  4.  Round-trip qualities via rANS order-1.
  5.  Mixed: sequences=BASE_PACK + qualities=RANS_ORDER1.
  6.  Back-compat: empty overrides path unchanged.
  7.  Validation: override on a non-byte channel raises.
  8.  Validation: non-TTIO codec value raises.
  9.  ``@compression`` attribute is set correctly.
 10.  Size-win: BASE_PACK on pure-ACGT sequences < 30% raw.
 11.  Cross-language fixture verification (4 fixtures × byte-exact).
 12.  Round-trip qualities via QUALITY_BINNED (bin-centre input).
 13.  Round-trip qualities via QUALITY_BINNED (lossy mapping).
 14.  Size-win: QUALITY_BINNED qualities ~50% raw.
 15.  ``@compression == 7`` for QUALITY_BINNED qualities.
 16.  Validation: QUALITY_BINNED on sequences raises with rationale.
 17.  Mixed: sequences=BASE_PACK + qualities=QUALITY_BINNED.
 18.  Round-trip read_names via NAME_TOKENIZED (Illumina-style).
 19.  Size-win: NAME_TOKENIZED < 50% of M82 compound storage.
 20.  Schema lift: read_names dataset is 1-D uint8 with @compression == 8.
 21.  Back-compat: read_names is still compound when no override.
 22.  Validation: NAME_TOKENIZED on sequences raises with rationale.
 23.  Mixed: sequences=BASE_PACK + qualities=QUALITY_BINNED + read_names=NAME_TOKENIZED.
 24.  Cross-language fixture for NAME_TOKENIZED.
"""
from __future__ import annotations

from pathlib import Path

import h5py
import numpy as np
import pytest

from ttio.enums import Compression
from ttio.spectral_dataset import SpectralDataset
from ttio.written_genomic_run import WrittenGenomicRun


# ----------------------------------------------------------------------
# Fixture helpers
# ----------------------------------------------------------------------

N_READS = 10
READ_LEN = 100
TOTAL_BYTES = N_READS * READ_LEN  # 1000

# Common cross-language fixture inputs (HANDOFF.md §6.2).
PURE_ACGT_SEQ = (b"ACGT" * 25) * N_READS                    # 1000 bytes
PHRED_CYCLE_QUAL = bytes((30 + (i % 11)) for i in range(TOTAL_BYTES))

# Phase D cross-language fixture: 1000 bytes of bin-centre Phred values
# (Illumina-8 centres 0/5/15/22/27/32/37/40 cycled). Bin centres
# round-trip byte-exact through QUALITY_BINNED (HANDOFF.md §120).
BIN_CENTRES = (0, 5, 15, 22, 27, 32, 37, 40)
QUAL_BIN_CENTRE = bytes(BIN_CENTRES * (TOTAL_BYTES // len(BIN_CENTRES)))
assert len(QUAL_BIN_CENTRE) == TOTAL_BYTES


def _make_run(
    seq_bytes: bytes,
    qual_bytes: bytes,
    codec_overrides: dict[str, Compression] | None = None,
) -> WrittenGenomicRun:
    """Build a 10-read × 100-bp synthetic genomic run.

    ``seq_bytes`` and ``qual_bytes`` must be ``N_READS * READ_LEN`` long;
    they are stored verbatim in the concatenated signal channels.
    """
    assert len(seq_bytes) == TOTAL_BYTES, (
        f"seq_bytes must be {TOTAL_BYTES} bytes, got {len(seq_bytes)}")
    assert len(qual_bytes) == TOTAL_BYTES, (
        f"qual_bytes must be {TOTAL_BYTES} bytes, got {len(qual_bytes)}")
    return WrittenGenomicRun(
        acquisition_mode=7,                       # GENOMIC_WGS
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="M86_TEST",
        positions=np.arange(N_READS, dtype=np.int64) * 1000,
        mapping_qualities=np.full(N_READS, 60, dtype=np.uint8),
        flags=np.zeros(N_READS, dtype=np.uint32),
        sequences=np.frombuffer(seq_bytes, dtype=np.uint8),
        qualities=np.frombuffer(qual_bytes, dtype=np.uint8),
        offsets=np.arange(N_READS, dtype=np.uint64) * READ_LEN,
        lengths=np.full(N_READS, READ_LEN, dtype=np.uint32),
        cigars=["100M"] * N_READS,
        read_names=[f"r{i}" for i in range(N_READS)],
        mate_chromosomes=["chr1"] * N_READS,
        mate_positions=np.full(N_READS, -1, dtype=np.int64),
        template_lengths=np.zeros(N_READS, dtype=np.int32),
        chromosomes=["chr1"] * N_READS,
        signal_codec_overrides=codec_overrides or {},
    )


def _write_and_open(tmp_path: Path, run: WrittenGenomicRun, fname: str = "g.tio"):
    p = tmp_path / fname
    SpectralDataset.write_minimal(
        p, title="t", isa_investigation_id="i",
        runs={}, genomic_runs={"genomic_0001": run},
    )
    return p


def _expected_seq_slice(seq_bytes: bytes, i: int) -> str:
    return seq_bytes[i * READ_LEN:(i + 1) * READ_LEN].decode("ascii")


def _expected_qual_slice(qual_bytes: bytes, i: int) -> bytes:
    return qual_bytes[i * READ_LEN:(i + 1) * READ_LEN]


# ----------------------------------------------------------------------
# 1–5: Round-trip with each codec / mixed
# ----------------------------------------------------------------------

def test_round_trip_sequences_rans_order0(tmp_path: Path):
    """Sequences encoded with rANS order-0 round-trip byte-exact."""
    run = _make_run(
        PURE_ACGT_SEQ, PHRED_CYCLE_QUAL,
        {"sequences": Compression.RANS_ORDER0},
    )
    p = _write_and_open(tmp_path, run)
    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        assert len(gr) == N_READS
        for i in range(N_READS):
            r = gr[i]
            assert r.sequence == _expected_seq_slice(PURE_ACGT_SEQ, i)
            # Qualities unchanged path (no override).
            assert r.qualities == _expected_qual_slice(PHRED_CYCLE_QUAL, i)
    finally:
        ds.close()


def test_round_trip_sequences_rans_order1(tmp_path: Path):
    """Sequences encoded with rANS order-1 round-trip byte-exact."""
    run = _make_run(
        PURE_ACGT_SEQ, PHRED_CYCLE_QUAL,
        {"sequences": Compression.RANS_ORDER1},
    )
    p = _write_and_open(tmp_path, run)
    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        for i in range(N_READS):
            r = gr[i]
            assert r.sequence == _expected_seq_slice(PURE_ACGT_SEQ, i)
            assert r.qualities == _expected_qual_slice(PHRED_CYCLE_QUAL, i)
    finally:
        ds.close()


def test_round_trip_sequences_base_pack(tmp_path: Path):
    """Sequences encoded with BASE_PACK round-trip byte-exact (pure ACGT)."""
    run = _make_run(
        PURE_ACGT_SEQ, PHRED_CYCLE_QUAL,
        {"sequences": Compression.BASE_PACK},
    )
    p = _write_and_open(tmp_path, run)
    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        for i in range(N_READS):
            r = gr[i]
            assert r.sequence == _expected_seq_slice(PURE_ACGT_SEQ, i)
            assert r.qualities == _expected_qual_slice(PHRED_CYCLE_QUAL, i)
    finally:
        ds.close()


def test_round_trip_qualities_rans_order1(tmp_path: Path):
    """Qualities encoded with rANS order-1 round-trip byte-exact."""
    run = _make_run(
        PURE_ACGT_SEQ, PHRED_CYCLE_QUAL,
        {"qualities": Compression.RANS_ORDER1},
    )
    p = _write_and_open(tmp_path, run)
    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        for i in range(N_READS):
            r = gr[i]
            assert r.sequence == _expected_seq_slice(PURE_ACGT_SEQ, i)
            assert r.qualities == _expected_qual_slice(PHRED_CYCLE_QUAL, i)
    finally:
        ds.close()


def test_round_trip_mixed(tmp_path: Path):
    """Both overrides at once: BASE_PACK on sequences + RANS_ORDER1 on qualities."""
    run = _make_run(
        PURE_ACGT_SEQ, PHRED_CYCLE_QUAL,
        {
            "sequences": Compression.BASE_PACK,
            "qualities": Compression.RANS_ORDER1,
        },
    )
    p = _write_and_open(tmp_path, run)
    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        for i in range(N_READS):
            r = gr[i]
            assert r.sequence == _expected_seq_slice(PURE_ACGT_SEQ, i)
            assert r.qualities == _expected_qual_slice(PHRED_CYCLE_QUAL, i)
    finally:
        ds.close()


# ----------------------------------------------------------------------
# 6: Back-compat — empty overrides goes through the unchanged HDF5 path
# ----------------------------------------------------------------------

def test_back_compat_no_overrides(tmp_path: Path):
    """Empty signal_codec_overrides leaves the M82 write path unchanged."""
    run = _make_run(PURE_ACGT_SEQ, PHRED_CYCLE_QUAL, codec_overrides={})
    p = _write_and_open(tmp_path, run)

    # Sanity: no @compression attribute on the byte channels.
    with h5py.File(p, "r") as f:
        seq_ds = f["study/genomic_runs/genomic_0001/signal_channels/sequences"]
        qual_ds = f["study/genomic_runs/genomic_0001/signal_channels/qualities"]
        assert "compression" not in seq_ds.attrs
        assert "compression" not in qual_ds.attrs
        # And the dataset length equals the raw byte count (no codec headers).
        assert seq_ds.shape == (TOTAL_BYTES,)
        assert qual_ds.shape == (TOTAL_BYTES,)

    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        for i in range(N_READS):
            r = gr[i]
            assert r.sequence == _expected_seq_slice(PURE_ACGT_SEQ, i)
            assert r.qualities == _expected_qual_slice(PHRED_CYCLE_QUAL, i)
    finally:
        ds.close()


# ----------------------------------------------------------------------
# 7–8: Validation
# ----------------------------------------------------------------------

def test_reject_invalid_channel(tmp_path: Path):
    """Override on a non-overridable channel must raise ValueError at write time.

    M86 Phase C (Binding Decision §124) extended the override map to
    the cigars channel; mate_info remains the only structurally-VL
    channel without a codec match (HANDOFF.md §8 "Out of scope" plus
    Gotcha §137: mate_info validation must continue to reject all
    codec overrides).
    """
    run = _make_run(
        PURE_ACGT_SEQ, PHRED_CYCLE_QUAL,
        {"mate_info": Compression.RANS_ORDER0},  # mate_info is not overridable
    )
    p = tmp_path / "bad.tio"
    with pytest.raises(ValueError, match="mate_info"):
        SpectralDataset.write_minimal(
            p, title="t", isa_investigation_id="i",
            runs={}, genomic_runs={"genomic_0001": run},
        )


def test_reject_invalid_codec(tmp_path: Path):
    """Override with a non-TTIO codec (e.g. LZ4) must raise ValueError at write."""
    run = _make_run(
        PURE_ACGT_SEQ, PHRED_CYCLE_QUAL,
        {"sequences": Compression.LZ4},  # LZ4 is an HDF5 filter, not a TTIO codec
    )
    p = tmp_path / "bad.tio"
    with pytest.raises(ValueError, match="not supported"):
        SpectralDataset.write_minimal(
            p, title="t", isa_investigation_id="i",
            runs={}, genomic_runs={"genomic_0001": run},
        )


# ----------------------------------------------------------------------
# 9: @compression attribute is set correctly per codec
# ----------------------------------------------------------------------

@pytest.mark.parametrize("codec", [
    Compression.RANS_ORDER0,
    Compression.RANS_ORDER1,
    Compression.BASE_PACK,
])
def test_attribute_set_correctly(tmp_path: Path, codec: Compression):
    """Each compressed channel carries @compression == codec.value (uint8).

    Untouched byte channels carry no such attribute.

    v1.6: positions / flags / mapping_qualities no longer live under
    signal_channels/ — they were removed and now live only in
    genomic_index/. See test_v1_6_signal_channels_has_no_int_dups.
    """
    run = _make_run(
        PURE_ACGT_SEQ, PHRED_CYCLE_QUAL,
        {"sequences": codec},
    )
    p = _write_and_open(tmp_path, run, fname=f"attr_{codec.name}.tio")
    with h5py.File(p, "r") as f:
        sc = f["study/genomic_runs/genomic_0001/signal_channels"]
        # sequences has the override → @compression == codec.value
        seq_attr = sc["sequences"].attrs.get("compression")
        assert seq_attr is not None, "sequences must carry @compression"
        assert int(seq_attr) == int(codec.value)
        # qualities has no override → no @compression attribute
        assert "compression" not in sc["qualities"].attrs


# ----------------------------------------------------------------------
# 10: BASE_PACK size win on a 100 000-base pure-ACGT channel
# ----------------------------------------------------------------------

def test_size_win_base_pack(tmp_path: Path):
    """BASE_PACK dataset for pure ACGT must be < 30% the size of raw uint8."""
    n_reads = 1000
    read_len = 100
    total = n_reads * read_len  # 100 000
    seq = (b"ACGT" * 25) * n_reads
    qual = bytes((30 + (i % 11)) for i in range(total))
    base_kw = dict(
        acquisition_mode=7, reference_uri="GRCh38.p14",
        platform="ILLUMINA", sample_name="SIZE_WIN",
        positions=np.arange(n_reads, dtype=np.int64) * 1000,
        mapping_qualities=np.full(n_reads, 60, dtype=np.uint8),
        flags=np.zeros(n_reads, dtype=np.uint32),
        sequences=np.frombuffer(seq, dtype=np.uint8),
        qualities=np.frombuffer(qual, dtype=np.uint8),
        offsets=np.arange(n_reads, dtype=np.uint64) * read_len,
        lengths=np.full(n_reads, read_len, dtype=np.uint32),
        cigars=["100M"] * n_reads,
        read_names=[f"r{i}" for i in range(n_reads)],
        mate_chromosomes=["chr1"] * n_reads,
        mate_positions=np.full(n_reads, -1, dtype=np.int64),
        template_lengths=np.zeros(n_reads, dtype=np.int32),
        chromosomes=["chr1"] * n_reads,
        signal_compression="none",  # uncompressed at the HDF5-filter level
    )
    raw_run = WrittenGenomicRun(**base_kw)
    bp_run = WrittenGenomicRun(
        **base_kw,
        signal_codec_overrides={"sequences": Compression.BASE_PACK},
    )

    p_raw = tmp_path / "raw.tio"
    SpectralDataset.write_minimal(
        p_raw, title="r", isa_investigation_id="i",
        runs={}, genomic_runs={"genomic_0001": raw_run},
    )
    p_bp = tmp_path / "bp.tio"
    SpectralDataset.write_minimal(
        p_bp, title="b", isa_investigation_id="i",
        runs={}, genomic_runs={"genomic_0001": bp_run},
    )

    # Compare the on-disk dataset storage size for the sequences channel.
    with h5py.File(p_raw, "r") as f:
        raw_size = f[
            "study/genomic_runs/genomic_0001/signal_channels/sequences"
        ].id.get_storage_size()
    with h5py.File(p_bp, "r") as f:
        bp_size = f[
            "study/genomic_runs/genomic_0001/signal_channels/sequences"
        ].id.get_storage_size()

    ratio = bp_size / raw_size
    assert ratio < 0.30, (
        f"BASE_PACK sequences dataset = {bp_size} bytes; "
        f"raw = {raw_size} bytes; ratio = {ratio:.3f} (target < 0.30)"
    )


# ----------------------------------------------------------------------
# 11: Cross-language fixture verification
# ----------------------------------------------------------------------

FIXTURE_DIR = Path(__file__).parent / "fixtures" / "genomic"
# Phase A fixtures encode both channels with the same codec.
FIXTURE_NAMES = (
    ("rans_order0", Compression.RANS_ORDER0),
    ("rans_order1", Compression.RANS_ORDER1),
    ("base_pack",   Compression.BASE_PACK),
)


@pytest.mark.parametrize("codec_name,codec", FIXTURE_NAMES)
def test_cross_language_fixtures(codec_name: str, codec: Compression):
    """Each committed fixture decodes to the known cross-language input."""
    fixture_path = FIXTURE_DIR / f"m86_codec_{codec_name}.tio"
    assert fixture_path.exists(), (
        f"fixture missing: {fixture_path} — regenerate with "
        f"python/tests/fixtures/genomic/regenerate_m86.py"
    )
    ds = SpectralDataset.open(fixture_path)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        assert len(gr) == N_READS
        for i in range(N_READS):
            r = gr[i]
            assert r.sequence == _expected_seq_slice(PURE_ACGT_SEQ, i), (
                f"{codec_name} read {i} sequence mismatch"
            )
            assert r.qualities == _expected_qual_slice(PHRED_CYCLE_QUAL, i), (
                f"{codec_name} read {i} qualities mismatch"
            )
        # Verify both channels really do carry the codec id.
        with h5py.File(fixture_path, "r") as f:
            sc = f["study/genomic_runs/genomic_0001/signal_channels"]
            assert int(sc["sequences"].attrs["compression"]) == int(codec.value)
            assert int(sc["qualities"].attrs["compression"]) == int(codec.value)
    finally:
        ds.close()


# ----------------------------------------------------------------------
# 12–17: Phase D — QUALITY_BINNED on the qualities channel
# ----------------------------------------------------------------------


def test_round_trip_qualities_quality_binned(tmp_path: Path):
    """Bin-centre Phred values round-trip byte-exact via QUALITY_BINNED.

    QUALITY_BINNED is lossy by construction (M85 §97), but inputs that
    are already at bin centres (0/5/15/22/27/32/37/40) decode back to
    themselves byte-exact.
    """
    run = _make_run(
        PURE_ACGT_SEQ, QUAL_BIN_CENTRE,
        {"qualities": Compression.QUALITY_BINNED},
    )
    p = _write_and_open(tmp_path, run, fname="qb_centres.tio")
    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        assert len(gr) == N_READS
        for i in range(N_READS):
            r = gr[i]
            assert r.sequence == _expected_seq_slice(PURE_ACGT_SEQ, i)
            assert r.qualities == _expected_qual_slice(QUAL_BIN_CENTRE, i)
    finally:
        ds.close()


def test_round_trip_qualities_quality_binned_lossy(tmp_path: Path):
    """Arbitrary Phred values round-trip via the documented lossy mapping."""
    # 1000 bytes cycling through Phred 0..49 — covers every bin and
    # the saturation case (≥40 → centre 40).
    arbitrary_qual = bytes((i % 50) for i in range(TOTAL_BYTES))
    # Compute the expected lossy output up-front using the codec's
    # public encode/decode round-trip — keeps this test as a pure
    # integration check (we don't reimplement the bin table here).
    from ttio.codecs.quality import encode as _enc, decode as _dec
    expected_qual = _dec(_enc(arbitrary_qual))
    assert len(expected_qual) == TOTAL_BYTES
    # Sanity: lossy mapping must actually differ from the input
    # (otherwise the test is degenerate).
    assert expected_qual != arbitrary_qual

    run = _make_run(
        PURE_ACGT_SEQ, arbitrary_qual,
        {"qualities": Compression.QUALITY_BINNED},
    )
    p = _write_and_open(tmp_path, run, fname="qb_lossy.tio")
    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        for i in range(N_READS):
            r = gr[i]
            assert r.sequence == _expected_seq_slice(PURE_ACGT_SEQ, i)
            assert r.qualities == _expected_qual_slice(expected_qual, i), (
                f"read {i}: qualities did not match expected lossy mapping"
            )
    finally:
        ds.close()


def test_size_win_quality_binned(tmp_path: Path):
    """QUALITY_BINNED qualities dataset is ~50% the size of uncompressed.

    The codec is 4-bits-per-index with a 6-byte header. For 100 000
    qualities bytes the wire stream is 6 + 50 000 = 50 006 bytes — a
    50.006% ratio of the raw 100 000 (well under our 0.55 target).
    """
    n_reads = 1000
    read_len = 100
    total = n_reads * read_len  # 100 000
    seq = (b"ACGT" * 25) * n_reads
    # Use bin-centre values cycled through all 8 centres so the
    # round-trip semantics are byte-exact (not strictly required for
    # the size assertion, but keeps this test stylistically consistent
    # with the byte-exact round-trip suite above).
    qual = bytes(BIN_CENTRES * (total // len(BIN_CENTRES)))
    base_kw = dict(
        acquisition_mode=7, reference_uri="GRCh38.p14",
        platform="ILLUMINA", sample_name="SIZE_WIN_QB",
        positions=np.arange(n_reads, dtype=np.int64) * 1000,
        mapping_qualities=np.full(n_reads, 60, dtype=np.uint8),
        flags=np.zeros(n_reads, dtype=np.uint32),
        sequences=np.frombuffer(seq, dtype=np.uint8),
        qualities=np.frombuffer(qual, dtype=np.uint8),
        offsets=np.arange(n_reads, dtype=np.uint64) * read_len,
        lengths=np.full(n_reads, read_len, dtype=np.uint32),
        cigars=["100M"] * n_reads,
        read_names=[f"r{i}" for i in range(n_reads)],
        mate_chromosomes=["chr1"] * n_reads,
        mate_positions=np.full(n_reads, -1, dtype=np.int64),
        template_lengths=np.zeros(n_reads, dtype=np.int32),
        chromosomes=["chr1"] * n_reads,
        signal_compression="none",  # no HDF5 filter on the baseline
    )
    raw_run = WrittenGenomicRun(**base_kw)
    qb_run = WrittenGenomicRun(
        **base_kw,
        signal_codec_overrides={"qualities": Compression.QUALITY_BINNED},
    )

    p_raw = tmp_path / "qb_raw.tio"
    SpectralDataset.write_minimal(
        p_raw, title="r", isa_investigation_id="i",
        runs={}, genomic_runs={"genomic_0001": raw_run},
    )
    p_qb = tmp_path / "qb_compressed.tio"
    SpectralDataset.write_minimal(
        p_qb, title="b", isa_investigation_id="i",
        runs={}, genomic_runs={"genomic_0001": qb_run},
    )

    with h5py.File(p_raw, "r") as f:
        raw_size = f[
            "study/genomic_runs/genomic_0001/signal_channels/qualities"
        ].id.get_storage_size()
    with h5py.File(p_qb, "r") as f:
        qb_size = f[
            "study/genomic_runs/genomic_0001/signal_channels/qualities"
        ].id.get_storage_size()

    ratio = qb_size / raw_size
    # Target: ~50% (the codec is 4-bit-packed; header is a constant
    # 6 bytes for the whole channel, negligible at 100k bytes).
    assert ratio < 0.55, (
        f"QUALITY_BINNED qualities dataset = {qb_size} bytes; "
        f"raw = {raw_size} bytes; ratio = {ratio:.3f} (target < 0.55)"
    )


def test_attribute_set_correctly_quality_binned(tmp_path: Path):
    """QUALITY_BINNED qualities channel carries @compression == 7 (uint8).

    v1.6: positions / flags / mapping_qualities no longer live under
    signal_channels/. See test_v1_6_signal_channels_has_no_int_dups.
    """
    run = _make_run(
        PURE_ACGT_SEQ, QUAL_BIN_CENTRE,
        {"qualities": Compression.QUALITY_BINNED},
    )
    p = _write_and_open(tmp_path, run, fname="attr_qb.tio")
    with h5py.File(p, "r") as f:
        sc = f["study/genomic_runs/genomic_0001/signal_channels"]
        qual_attr = sc["qualities"].attrs.get("compression")
        assert qual_attr is not None, "qualities must carry @compression"
        assert int(qual_attr) == int(Compression.QUALITY_BINNED.value) == 7
        # sequences has no override → no @compression attribute.
        assert "compression" not in sc["sequences"].attrs


def test_reject_quality_binned_on_sequences(tmp_path: Path):
    """QUALITY_BINNED on the sequences channel raises ValueError at write time.

    Per Binding Decision §108: QUALITY_BINNED would map all four
    ACGT bytes (0x41/0x43/0x47/0x54 = 65/67/71/84, all ≥ 40) to
    bin 7 / centre 40, silently destroying the sequence. The
    validation rejects this combination before touching the file.
    The error message must name the codec, the channel, and explain
    the lossy-quantisation rationale (Binding Decision §110).
    """
    run = _make_run(
        PURE_ACGT_SEQ, QUAL_BIN_CENTRE,
        {"sequences": Compression.QUALITY_BINNED},
    )
    p = tmp_path / "bad_qb_seq.tio"
    with pytest.raises(ValueError) as excinfo:
        SpectralDataset.write_minimal(
            p, title="t", isa_investigation_id="i",
            runs={}, genomic_runs={"genomic_0001": run},
        )
    msg = str(excinfo.value)
    # Names the codec.
    assert "QUALITY_BINNED" in msg, f"error must name the codec; got: {msg!r}"
    # Names the channel.
    assert "sequences" in msg, f"error must name the channel; got: {msg!r}"
    # Explains the lossy-quantisation rationale.
    assert "lossy" in msg.lower(), (
        f"error must explain that quality binning is lossy; got: {msg!r}"
    )
    # Mentions Phred quality scores so the user knows where it
    # *does* belong.
    assert "Phred" in msg or "quality" in msg.lower(), (
        f"error must mention Phred/quality scores; got: {msg!r}"
    )


def test_mixed_quality_binned_with_rans(tmp_path: Path):
    """Mixed override: BASE_PACK on sequences + QUALITY_BINNED on qualities.

    Exercises the per-channel codec dispatch on both byte channels
    in the same run with two different codec ids (6 and 7). Both
    round-trip correctly: sequences byte-exact (BASE_PACK is
    lossless on pure ACGT), qualities byte-exact (input is bin
    centres, which round-trip exactly).
    """
    run = _make_run(
        PURE_ACGT_SEQ, QUAL_BIN_CENTRE,
        {
            "sequences": Compression.BASE_PACK,
            "qualities": Compression.QUALITY_BINNED,
        },
    )
    p = _write_and_open(tmp_path, run, fname="mixed_bp_qb.tio")

    # Verify both channels really do carry their respective codec ids.
    with h5py.File(p, "r") as f:
        sc = f["study/genomic_runs/genomic_0001/signal_channels"]
        assert int(sc["sequences"].attrs["compression"]) == int(
            Compression.BASE_PACK.value
        )
        assert int(sc["qualities"].attrs["compression"]) == int(
            Compression.QUALITY_BINNED.value
        )

    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        for i in range(N_READS):
            r = gr[i]
            assert r.sequence == _expected_seq_slice(PURE_ACGT_SEQ, i)
            assert r.qualities == _expected_qual_slice(QUAL_BIN_CENTRE, i)
    finally:
        ds.close()


# ----------------------------------------------------------------------
# 11+: Cross-language fixture for QUALITY_BINNED
# ----------------------------------------------------------------------
# Separate test (not a parameterization extension of FIXTURE_NAMES) because
# the QUALITY_BINNED fixture uses the bin-centre quality buffer rather than
# the PHRED_CYCLE_QUAL used by the Phase A fixtures, and only the qualities
# channel carries QUALITY_BINNED — sequences uses BASE_PACK.


# ----------------------------------------------------------------------
# 18–23: Phase E — NAME_TOKENIZED on the read_names channel (schema lift)
# ----------------------------------------------------------------------
# Phase E lifts read_names from VL_STRING-in-compound to a flat 1-D
# uint8 dataset when the override is set, so that the @compression
# attribute can travel with the codec output. Readers dispatch on
# dataset shape (compound vs uint8). Per Binding Decision §111 the
# two layouts are mutually exclusive within a single run; per §113
# NAME_TOKENIZED is only valid on the read_names channel.

# Deterministic Illumina-style names — same generator the ObjC and
# Java agents use to construct the cross-language fixture input.
# Tokenises to ["INSTR:RUN:", N, ":", N, ":", N, ":", N] — 7
# alternating string/numeric columns that pack tightly through the
# NAME_TOKENIZED columnar mode.
ILLUMINA_NAMES = [
    f"INSTR:RUN:1:{i // 4}:{i % 4}:{i * 100}"
    for i in range(N_READS)
]


def _make_run_with_names(
    seq_bytes: bytes,
    qual_bytes: bytes,
    names: list[str],
    codec_overrides: dict[str, Compression] | None = None,
) -> WrittenGenomicRun:
    """Variant of :func:`_make_run` that accepts custom read names.

    Used for the Phase E NAME_TOKENIZED tests — the codec is sensitive
    to name structure, so synthesising structured names (instead of
    the default ``r{i}``) lets us exercise the columnar encode path.
    """
    assert len(names) == N_READS, f"expected {N_READS} names, got {len(names)}"
    run = _make_run(seq_bytes, qual_bytes, codec_overrides)
    run.read_names = names
    return run




# ----------------------------------------------------------------------
# v1.6: Phase B integer-channel codec wiring REMOVED
# ----------------------------------------------------------------------
# v1.5 wrote positions/flags/mapping_qualities under BOTH
# genomic_index/ AND signal_channels/, with the signal_channels copy
# accepting rANS / DELTA_RANS overrides via signal_codec_overrides.
# v1.6 drops the signal_channels copy — those fields live exclusively
# in genomic_index/ now (mirroring MS's spectrum_index/ pattern).
# These tests pin the new contract: setting the override raises, and
# the datasets do NOT exist in signal_channels/.
# ----------------------------------------------------------------------


def _make_minimal_genomic_run(
    n_reads: int = 5, read_len: int = 50,
    overrides: dict[str, Compression] | None = None,
) -> WrittenGenomicRun:
    """Tiny synthetic run sufficient to exercise the writer's override path."""
    return WrittenGenomicRun(
        acquisition_mode=7,  # GENOMIC_WGS
        reference_uri="v1.6-test",
        platform="Illumina",
        sample_name="v1.6-test",
        positions=np.arange(n_reads, dtype=np.int64) * 1000,
        mapping_qualities=np.full(n_reads, 60, dtype=np.uint8),
        flags=np.zeros(n_reads, dtype=np.uint32),
        sequences=np.frombuffer(
            (b"ACGT" * (read_len // 4)) * n_reads, dtype=np.uint8,
        ).copy(),
        qualities=np.full(n_reads * read_len, 40, dtype=np.uint8),
        offsets=np.arange(n_reads, dtype=np.uint64) * read_len,
        lengths=np.full(n_reads, read_len, dtype=np.uint32),
        cigars=[f"{read_len}M"] * n_reads,
        read_names=[f"read_{i}" for i in range(n_reads)],
        mate_chromosomes=["*"] * n_reads,
        mate_positions=np.full(n_reads, -1, dtype=np.int64),
        template_lengths=np.zeros(n_reads, dtype=np.int32),
        chromosomes=["chr1"] * n_reads,
        signal_compression="gzip",
        signal_codec_overrides=overrides or {},
    )


@pytest.mark.parametrize("channel", ["positions", "flags", "mapping_qualities"])
def test_v1_6_override_on_int_channel_raises(tmp_path: Path, channel: str):
    """Setting signal_codec_overrides[positions|flags|mapping_qualities]
    raises a ValueError mentioning v1.6 and genomic_index."""
    run = _make_minimal_genomic_run(
        overrides={channel: Compression.RANS_ORDER1},
    )
    out = tmp_path / f"v1_6_reject_{channel}.tio"
    with pytest.raises(ValueError, match=r"v1\.6|genomic_index"):
        SpectralDataset.write_minimal(
            out,
            title="v1.6 reject test",
            isa_investigation_id="ISA:v1.6:reject",
            runs={"genomic_0001": run},
        )


def test_v1_6_signal_channels_has_no_int_dups(tmp_path: Path):
    """v1.6 writers do not emit positions/flags/mapping_qualities under
    signal_channels/. The canonical home is genomic_index/."""
    run = _make_minimal_genomic_run()
    out = tmp_path / "v1_6_no_dups.tio"
    SpectralDataset.write_minimal(
        out,
        title="v1.6 no-dups test",
        isa_investigation_id="ISA:v1.6:no-dups",
        runs={"genomic_0001": run},
    )
    with h5py.File(out, "r") as f:
        sc = f["study/genomic_runs/genomic_0001/signal_channels"]
        gi = f["study/genomic_runs/genomic_0001/genomic_index"]
        for ch in ("positions", "flags", "mapping_qualities"):
            assert ch not in sc, (
                f"v1.6: signal_channels/{ch} must not be written; "
                f"canonical home is genomic_index/{ch}"
            )
            assert ch in gi, (
                f"v1.6: genomic_index/{ch} must remain (canonical home)"
            )


# ----------------------------------------------------------------------
# 39–47: Phase C — rANS + NAME_TOKENIZED on the cigars channel
# ----------------------------------------------------------------------
# Phase C lifts cigars from VL_STRING-in-compound to a flat 1-D
# uint8 dataset when the override is set, so that the @compression
# attribute can travel with the codec output. Three codec choices
# are accepted (Binding Decision §120):
#   * RANS_ORDER0 (4)  — entropy code length-prefix-concat byte stream
#   * RANS_ORDER1 (5)  — same, with order-1 context model (recommended
#                        default for real WGS data, §1.2)
#   * NAME_TOKENIZED (8) — the M85 codec's columnar mode wins on
#                        all-uniform CIGARs but degrades to verbatim
#                        on mixed token-count input
# Readers dispatch on dataset shape (compound vs uint8) and codec
# id (@compression).


def _make_run_with_cigars(
    seq_bytes: bytes,
    qual_bytes: bytes,
    cigars: list[str],
    codec_overrides: dict[str, Compression] | None = None,
) -> WrittenGenomicRun:
    """Variant of :func:`_make_run` that accepts custom cigars.

    Used for the Phase C rANS/NAME_TOKENIZED tests on the cigars
    channel — the codec choice is sensitive to CIGAR distribution
    (uniform vs mixed token-count), so synthesising controlled
    cigars lets us exercise both code paths.
    """
    assert len(cigars) == N_READS, f"expected {N_READS} cigars, got {len(cigars)}"
    run = _make_run(seq_bytes, qual_bytes, codec_overrides)
    run.cigars = cigars
    return run


def _mixed_cigars(n_reads: int) -> list[str]:
    """Realistic mixed-CIGAR distribution — 80% perfect-match, 10% del, 10% soft-clip.

    Per HANDOFF.md §6.4 fixture A spec.
    """
    out: list[str] = []
    for i in range(n_reads):
        m = i % 10
        if m < 8:
            out.append("100M")
        elif m == 8:
            out.append("99M1D")
        else:
            out.append("50M50S")
    return out


def test_round_trip_cigars_rans_order1(tmp_path: Path):
    """Mixed CIGARs encoded with RANS_ORDER1 round-trip byte-exact.

    Uses 80% '100M' + 10% '99M1D' + 10% '50M50S' across 1000 reads
    — the realistic-WGS distribution from HANDOFF.md §1.2 where rANS
    wins decisively over NAME_TOKENIZED's verbatim fallback.
    """
    n_reads = 1000
    read_len = 100
    total = n_reads * read_len
    seq = (b"ACGT" * 25) * n_reads
    qual = bytes((30 + (i % 11)) for i in range(total))
    cigars = _mixed_cigars(n_reads)
    run = WrittenGenomicRun(
        acquisition_mode=7, reference_uri="GRCh38.p14",
        platform="ILLUMINA", sample_name="M86C_RANS",
        positions=np.arange(n_reads, dtype=np.int64) * 1000,
        mapping_qualities=np.full(n_reads, 60, dtype=np.uint8),
        flags=np.zeros(n_reads, dtype=np.uint32),
        sequences=np.frombuffer(seq, dtype=np.uint8),
        qualities=np.frombuffer(qual, dtype=np.uint8),
        offsets=np.arange(n_reads, dtype=np.uint64) * read_len,
        lengths=np.full(n_reads, read_len, dtype=np.uint32),
        cigars=cigars,
        read_names=[f"r{i}" for i in range(n_reads)],
        mate_chromosomes=["chr1"] * n_reads,
        mate_positions=np.full(n_reads, -1, dtype=np.int64),
        template_lengths=np.zeros(n_reads, dtype=np.int32),
        chromosomes=["chr1"] * n_reads,
        signal_codec_overrides={"cigars": Compression.RANS_ORDER1},
    )
    p = _write_and_open(tmp_path, run, fname="cigars_rans1.tio")
    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        assert len(gr) == n_reads
        for i in range(n_reads):
            r = gr[i]
            assert r.cigar == cigars[i], (
                f"read {i} cigar mismatch — expected {cigars[i]!r}, "
                f"got {r.cigar!r}"
            )
    finally:
        ds.close()


@pytest.mark.parametrize("codec", [
    Compression.RANS_ORDER0,
    Compression.RANS_ORDER1,
])
def test_attribute_set_correctly_cigars(tmp_path: Path, codec: Compression):
    """Each accepted cigars codec produces 1-D uint8 with @compression == id.

    Verifies the schema lift and the @compression dispatch tag for
    all three accepted codecs (HANDOFF.md §5.2 / §5.3).
    """
    cigars = ["100M"] * N_READS
    run = _make_run_with_cigars(
        PURE_ACGT_SEQ, PHRED_CYCLE_QUAL, cigars,
        {"cigars": codec},
    )
    p = _write_and_open(tmp_path, run, fname=f"attr_cig_{codec.name}.tio")
    with h5py.File(p, "r") as f:
        sc = f["study/genomic_runs/genomic_0001/signal_channels"]
        cig_ds = sc["cigars"]
        assert cig_ds.dtype == np.uint8, (
            f"cigars dtype must be uint8 under {codec.name}, "
            f"got {cig_ds.dtype}"
        )
        assert len(cig_ds.shape) == 1, (
            f"cigars must be 1-D under {codec.name}, "
            f"got shape {cig_ds.shape}"
        )
        attr = cig_ds.attrs.get("compression")
        assert attr is not None, "cigars must carry @compression"
        assert int(attr) == int(codec.value)
        # Other byte channels untouched by this override (sequences may be
        # a v2 group, but its top-level layout still doesn't carry the
        # cigars-channel compression attr).
        assert "compression" not in sc["qualities"].attrs


def test_back_compat_cigars_unchanged(tmp_path: Path):
    """No cigars override leaves the M82 compound path unchanged.

    Covers two cases: empty overrides, and overrides that touch
    only sequences/qualities. In both, cigars must remain a
    VL_STRING-in-compound dataset (the M82 layout). Round-trip
    through the existing __getitem__ path (which dispatches
    through _cigar_at).
    """
    for desc, overrides in (
        ("empty", {}),
        ("seq+qual only", {
            "sequences": Compression.BASE_PACK,
            "qualities": Compression.RANS_ORDER1,
        }),
    ):
        run = _make_run(
            PURE_ACGT_SEQ, PHRED_CYCLE_QUAL, codec_overrides=overrides,
        )
        p = tmp_path / f"cig_bc_{desc.replace(' ', '_').replace('+', '')}.tio"
        SpectralDataset.write_minimal(
            p, title="t", isa_investigation_id="i",
            runs={}, genomic_runs={"genomic_0001": run},
        )

        with h5py.File(p, "r") as f:
            cig = f["study/genomic_runs/genomic_0001/signal_channels/cigars"]
            assert cig.dtype.kind == "V", (
                f"{desc}: cigars must remain compound (kind='V'), "
                f"got kind={cig.dtype.kind!r}"
            )
            assert cig.dtype.names is not None and "value" in cig.dtype.names, (
                f"{desc}: M82 compound must have 'value' field, "
                f"got fields={cig.dtype.names}"
            )
            assert "compression" not in cig.attrs

        ds = SpectralDataset.open(p)
        try:
            gr = ds.genomic_runs["genomic_0001"]
            for i in range(N_READS):
                r = gr[i]
                # _make_run uses cigars=["100M"] * N_READS.
                assert r.cigar == "100M", (
                    f"{desc}: read {i} cigar mismatch — got {r.cigar!r}"
                )
        finally:
            ds.close()


def test_reject_base_pack_on_cigars(tmp_path: Path):
    """BASE_PACK on the cigars channel raises with a clear message.

    Per Binding Decision §120 / §121: BASE_PACK 2-bit-packs ACGT
    bytes and would silently corrupt CIGAR strings (digits +
    operator letters MIDNSHP=X are not ACGT). Validation must
    name the codec, the channel, and explain the wrong-content
    rationale.
    """
    run = _make_run(
        PURE_ACGT_SEQ, PHRED_CYCLE_QUAL,
        {"cigars": Compression.BASE_PACK},
    )
    p = tmp_path / "bad_bp_cig.tio"
    with pytest.raises(ValueError) as excinfo:
        SpectralDataset.write_minimal(
            p, title="t", isa_investigation_id="i",
            runs={}, genomic_runs={"genomic_0001": run},
        )
    msg = str(excinfo.value)
    assert "BASE_PACK" in msg, f"error must name the codec; got: {msg!r}"
    assert "cigars" in msg, f"error must name the channel; got: {msg!r}"
    # Mentions the rANS/NAME_TOKENIZED replacements.
    assert "RANS" in msg or "NAME_TOKENIZED" in msg, (
        f"error must point at the accepted codecs; got: {msg!r}"
    )

    # Also verify QUALITY_BINNED is rejected on cigars (parallel
    # wrong-content rejection per §120 / §137 — both are wrong-
    # content for CIGAR strings).
    run_qb = _make_run(
        PURE_ACGT_SEQ, PHRED_CYCLE_QUAL,
        {"cigars": Compression.QUALITY_BINNED},
    )
    p_qb = tmp_path / "bad_qb_cig.tio"
    with pytest.raises(ValueError) as excinfo_qb:
        SpectralDataset.write_minimal(
            p_qb, title="t", isa_investigation_id="i",
            runs={}, genomic_runs={"genomic_0001": run_qb},
        )
    msg_qb = str(excinfo_qb.value)
    assert "QUALITY_BINNED" in msg_qb
    assert "cigars" in msg_qb


def test_cross_language_fixture_cigars_rans():
    """Phase C fixture (rANS path) decodes byte-exact: 100-read mixed CIGARs.

    Companion to the per-language conformance suites in objc/ and java/.
    """
    fixture_path = FIXTURE_DIR / "m86_codec_cigars_rans.tio"
    assert fixture_path.exists(), (
        f"fixture missing: {fixture_path} — regenerate with "
        f"python/tests/fixtures/genomic/regenerate_m86_cigars_rans.py"
    )
    n_reads = 100
    expected_cigars = _mixed_cigars(n_reads)
    ds = SpectralDataset.open(fixture_path)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        assert len(gr) == n_reads
        for i in range(n_reads):
            r = gr[i]
            assert r.cigar == expected_cigars[i], (
                f"cigars_rans fixture: read {i} cigar mismatch — "
                f"got {r.cigar!r}, expected {expected_cigars[i]!r}"
            )
        with h5py.File(fixture_path, "r") as f:
            cig = f["study/genomic_runs/genomic_0001/signal_channels/cigars"]
            assert cig.dtype == np.uint8
            assert int(cig.attrs["compression"]) == int(
                Compression.RANS_ORDER1.value
            )
    finally:
        ds.close()


# ----------------------------------------------------------------------
# 48–56: M86 Phase F — mate_info per-field decomposition
# ----------------------------------------------------------------------
#
# Phase F replaces the M82 mate_info compound dataset with a subgroup
# (``signal_channels/mate_info/``) containing three child datasets
# (chrom, pos, tlen) when ANY of the three per-field overrides
# (mate_info_chrom, mate_info_pos, mate_info_tlen) is in
# ``signal_codec_overrides``. Reader dispatches on HDF5 link type
# (dataset = M82 compound; group = Phase F subgroup).
#
# Realistic mate distributions for the 100-read tests below:
# - chrom: most paired mates on chr1, a few elsewhere, two unmapped
# - pos: monotonically increasing positions for paired mates,
#   -1 for unmapped
# - tlen: cluster around 350 (typical Illumina insert size) for
#   paired, 0 for unmapped


_PHASE_F_N_READS = 100


def _phase_f_mate_chroms() -> list[str]:
    """100-entry chrom distribution per HANDOFF.md §6.4."""
    return ["chr1"] * 90 + ["chr2"] * 5 + ["chrX"] * 3 + ["*"] * 2


def _phase_f_mate_positions() -> np.ndarray:
    """Monotonic positions for paired mates, -1 for unpaired (the four "*" slots)."""
    chroms = _phase_f_mate_chroms()
    out = np.empty(_PHASE_F_N_READS, dtype=np.int64)
    for i, c in enumerate(chroms):
        out[i] = -1 if c == "*" else (i * 100 + 500)
    return out


def _phase_f_mate_tlens() -> np.ndarray:
    """Insert sizes clustered around 350 for paired, 0 for unpaired."""
    chroms = _phase_f_mate_chroms()
    out = np.empty(_PHASE_F_N_READS, dtype=np.int32)
    for i, c in enumerate(chroms):
        out[i] = 0 if c == "*" else (350 + (i % 11) - 5)
    return out


def _make_phase_f_run(
    overrides: dict[str, Compression],
    *,
    n_reads: int = _PHASE_F_N_READS,
    chroms: list[str] | None = None,
    positions: np.ndarray | None = None,
    tlens: np.ndarray | None = None,
) -> WrittenGenomicRun:
    """Build a 100-read run with realistic mate distributions for Phase F tests."""
    if chroms is None:
        chroms = _phase_f_mate_chroms()
    if positions is None:
        positions = _phase_f_mate_positions()
    if tlens is None:
        tlens = _phase_f_mate_tlens()
    assert len(chroms) == n_reads
    assert positions.shape == (n_reads,)
    assert tlens.shape == (n_reads,)
    read_len = 100
    total = n_reads * read_len
    seq = (b"ACGT" * 25) * n_reads
    qual = bytes((30 + (i % 11)) for i in range(total))
    return WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="M86F_TEST",
        positions=np.arange(n_reads, dtype=np.int64) * 1000,
        mapping_qualities=np.full(n_reads, 60, dtype=np.uint8),
        flags=np.zeros(n_reads, dtype=np.uint32),
        sequences=np.frombuffer(seq, dtype=np.uint8),
        qualities=np.frombuffer(qual, dtype=np.uint8),
        offsets=np.arange(n_reads, dtype=np.uint64) * read_len,
        lengths=np.full(n_reads, read_len, dtype=np.uint32),
        cigars=["100M"] * n_reads,
        read_names=[f"r{i}" for i in range(n_reads)],
        mate_chromosomes=chroms,
        mate_positions=positions,
        template_lengths=tlens,
        chromosomes=["chr1"] * n_reads,
        signal_codec_overrides=overrides,
    )


def _phase_f_write(tmp_path: Path, run: WrittenGenomicRun, fname: str) -> Path:
    p = tmp_path / fname
    SpectralDataset.write_minimal(
        p, title="t", isa_investigation_id="i",
        runs={}, genomic_runs={"genomic_0001": run},
    )
    return p


# 54 ----------------------------------------------------------------------

def test_reject_bare_mate_info_key(tmp_path: Path):
    """The bare 'mate_info' key is reserved and rejected at write time.

    Per Binding Decision §126 / Gotcha §143: the error message must
    point the caller at the three per-field virtual channel names.
    """
    run = _make_phase_f_run(
        {"mate_info": Compression.RANS_ORDER1},
    )
    p = tmp_path / "bad_bare_mate.tio"
    with pytest.raises(ValueError) as excinfo:
        SpectralDataset.write_minimal(
            p, title="t", isa_investigation_id="i",
            runs={}, genomic_runs={"genomic_0001": run},
        )
    msg = str(excinfo.value)
    assert "mate_info" in msg, (
        f"error must mention the rejected key; got: {msg!r}"
    )
    # Critical: must point at all three per-field names.
    assert "mate_info_chrom" in msg, (
        f"error must point at mate_info_chrom; got: {msg!r}"
    )
    assert "mate_info_pos" in msg, (
        f"error must point at mate_info_pos; got: {msg!r}"
    )
    assert "mate_info_tlen" in msg, (
        f"error must point at mate_info_tlen; got: {msg!r}"
    )


