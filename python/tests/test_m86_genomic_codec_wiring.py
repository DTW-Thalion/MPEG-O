"""M86 — genomic signal-channel codec wiring tests.

Covers the eleven test cases in HANDOFF.md §6.1:
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
 11.  Cross-language fixture verification (3 fixtures × byte-exact).
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
    """Override on an integer channel must raise ValueError at write time."""
    run = _make_run(
        PURE_ACGT_SEQ, PHRED_CYCLE_QUAL,
        {"positions": Compression.RANS_ORDER0},  # positions is INT64, not byte
    )
    p = tmp_path / "bad.tio"
    with pytest.raises(ValueError, match="positions"):
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

    Uncompressed channels (positions, flags, mapping_qualities) and
    untouched byte channels carry no such attribute.
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
        # Integer / mapping_qualities channels are untouched by M86.
        assert "compression" not in sc["positions"].attrs
        assert "compression" not in sc["flags"].attrs
        assert "compression" not in sc["mapping_qualities"].attrs


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
