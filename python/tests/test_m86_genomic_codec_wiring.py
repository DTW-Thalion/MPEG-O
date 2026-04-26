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
    """QUALITY_BINNED qualities channel carries @compression == 7 (uint8)."""
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
        # Integer / mapping_qualities channels are untouched.
        assert "compression" not in sc["positions"].attrs
        assert "compression" not in sc["flags"].attrs
        assert "compression" not in sc["mapping_qualities"].attrs


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


def test_round_trip_read_names_name_tokenized(tmp_path: Path):
    """Structured Illumina-style names round-trip byte-exact via NAME_TOKENIZED.

    NAME_TOKENIZED is a lossless codec (M85 Phase B §1) so every
    name in the input list must appear unchanged on the read side.
    """
    run = _make_run_with_names(
        PURE_ACGT_SEQ, PHRED_CYCLE_QUAL, ILLUMINA_NAMES,
        {"read_names": Compression.NAME_TOKENIZED},
    )
    p = _write_and_open(tmp_path, run, fname="rn_nt.tio")
    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        assert len(gr) == N_READS
        for i in range(N_READS):
            r = gr[i]
            assert r.read_name == ILLUMINA_NAMES[i], (
                f"read {i}: name mismatch — expected "
                f"{ILLUMINA_NAMES[i]!r}, got {r.read_name!r}"
            )
            # Sequences/qualities unchanged path (no override on those).
            assert r.sequence == _expected_seq_slice(PURE_ACGT_SEQ, i)
            assert r.qualities == _expected_qual_slice(PHRED_CYCLE_QUAL, i)
    finally:
        ds.close()


def test_size_win_name_tokenized(tmp_path: Path):
    """NAME_TOKENIZED is significantly smaller than the M82 compound layout.

    The HDF5 VL_STRING compound stores the dataset's primary chunk
    plus a separate global heap holding the variable-length
    payloads. ``Dataset.id.get_storage_size()`` reports only the
    primary chunk and misses the heap; the realistic comparison
    is the total file-size delta between the two writes (per
    HANDOFF.md §6.1 — "the exact ratio depends on HDF5 VL_STRING
    overhead; just verify it's a meaningful win"). For 1000
    structured Illumina-style names the codec output is well
    under 50% of the compound's combined primary+heap footprint.
    """
    n_reads = 1000
    read_len = 100
    total = n_reads * read_len
    seq = (b"ACGT" * 25) * n_reads
    qual = bytes((30 + (i % 11)) for i in range(total))
    names = [
        f"INSTR:RUN:1:{i // 4}:{i % 4}:{i * 100}"
        for i in range(n_reads)
    ]
    base_kw = dict(
        acquisition_mode=7, reference_uri="GRCh38.p14",
        platform="ILLUMINA", sample_name="SIZE_WIN_NT",
        positions=np.arange(n_reads, dtype=np.int64) * 1000,
        mapping_qualities=np.full(n_reads, 60, dtype=np.uint8),
        flags=np.zeros(n_reads, dtype=np.uint32),
        sequences=np.frombuffer(seq, dtype=np.uint8),
        qualities=np.frombuffer(qual, dtype=np.uint8),
        offsets=np.arange(n_reads, dtype=np.uint64) * read_len,
        lengths=np.full(n_reads, read_len, dtype=np.uint32),
        cigars=["100M"] * n_reads,
        read_names=names,
        mate_chromosomes=["chr1"] * n_reads,
        mate_positions=np.full(n_reads, -1, dtype=np.int64),
        template_lengths=np.zeros(n_reads, dtype=np.int32),
        chromosomes=["chr1"] * n_reads,
        signal_compression="none",
    )
    raw_run = WrittenGenomicRun(**base_kw)
    nt_run = WrittenGenomicRun(
        **base_kw,
        signal_codec_overrides={"read_names": Compression.NAME_TOKENIZED},
    )

    p_raw = tmp_path / "rn_raw.tio"
    SpectralDataset.write_minimal(
        p_raw, title="r", isa_investigation_id="i",
        runs={}, genomic_runs={"genomic_0001": raw_run},
    )
    p_nt = tmp_path / "rn_nt.tio"
    SpectralDataset.write_minimal(
        p_nt, title="b", isa_investigation_id="i",
        runs={}, genomic_runs={"genomic_0001": nt_run},
    )

    raw_file_size = p_raw.stat().st_size
    nt_file_size = p_nt.stat().st_size
    # Footprint attributable to read_names = file-size delta. The
    # two files differ only in the read_names channel (both written
    # with signal_compression="none" so other channels are identical).
    saved = raw_file_size - nt_file_size
    # The on-disk codec stream is the realistic "after" size; the
    # M82 footprint for read_names is approximately the codec
    # stream plus the bytes saved.
    with h5py.File(p_nt, "r") as f:
        nt_codec_bytes = f[
            "study/genomic_runs/genomic_0001/signal_channels/read_names"
        ].id.get_storage_size()
    m82_footprint = nt_codec_bytes + saved
    ratio = nt_codec_bytes / m82_footprint
    assert ratio < 0.50, (
        f"NAME_TOKENIZED read_names dataset = {nt_codec_bytes} bytes; "
        f"M82 footprint (codec+saved) = {m82_footprint} bytes; "
        f"ratio = {ratio:.3f} (target < 0.50)"
    )


def test_attribute_set_correctly_name_tokenized(tmp_path: Path):
    """NAME_TOKENIZED override produces 1-D uint8 read_names with @compression == 8.

    Verifies the schema lift: instead of the M82 compound, the
    dataset is a flat uint8 array carrying the codec output, with
    @compression set to the NAME_TOKENIZED codec id.
    """
    run = _make_run_with_names(
        PURE_ACGT_SEQ, PHRED_CYCLE_QUAL, ILLUMINA_NAMES,
        {"read_names": Compression.NAME_TOKENIZED},
    )
    p = _write_and_open(tmp_path, run, fname="attr_nt.tio")
    with h5py.File(p, "r") as f:
        sc = f["study/genomic_runs/genomic_0001/signal_channels"]
        rn = sc["read_names"]
        # Schema lift: 1-D uint8, NOT compound.
        assert rn.dtype == np.uint8, (
            f"read_names dtype must be uint8 under NAME_TOKENIZED, "
            f"got {rn.dtype}"
        )
        assert len(rn.shape) == 1, (
            f"read_names must be 1-D under NAME_TOKENIZED, "
            f"got shape {rn.shape}"
        )
        # @compression attribute carries the codec id.
        attr = rn.attrs.get("compression")
        assert attr is not None, "read_names must carry @compression"
        assert int(attr) == int(Compression.NAME_TOKENIZED.value) == 8
        # Other byte channels untouched by this override.
        assert "compression" not in sc["sequences"].attrs
        assert "compression" not in sc["qualities"].attrs


def test_back_compat_read_names_unchanged(tmp_path: Path):
    """No read_names override leaves the M82 compound path unchanged.

    Covers two cases: empty overrides, and overrides that touch
    only sequences/qualities. In both, read_names must remain a
    VL_STRING-in-compound dataset (the M82 layout).
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
        p = tmp_path / f"backcompat_{desc.replace(' ', '_').replace('+', '')}.tio"
        SpectralDataset.write_minimal(
            p, title="t", isa_investigation_id="i",
            runs={}, genomic_runs={"genomic_0001": run},
        )

        with h5py.File(p, "r") as f:
            rn = f["study/genomic_runs/genomic_0001/signal_channels/read_names"]
            # Compound dataset → dtype.kind == 'V', has named fields.
            assert rn.dtype.kind == "V", (
                f"{desc}: read_names must remain compound (kind='V'), "
                f"got kind={rn.dtype.kind!r}"
            )
            assert rn.dtype.names is not None and "value" in rn.dtype.names, (
                f"{desc}: M82 compound must have a 'value' field, "
                f"got fields={rn.dtype.names}"
            )
            # No @compression attribute on the compound.
            assert "compression" not in rn.attrs

        # Round-trip through the existing read path.
        ds = SpectralDataset.open(p)
        try:
            gr = ds.genomic_runs["genomic_0001"]
            for i in range(N_READS):
                r = gr[i]
                assert r.read_name == f"r{i}", (
                    f"{desc}: read {i} name mismatch — got {r.read_name!r}"
                )
        finally:
            ds.close()


def test_reject_name_tokenized_on_sequences(tmp_path: Path):
    """NAME_TOKENIZED on the sequences channel raises ValueError at write.

    Per Binding Decision §113: the codec tokenises UTF-8 strings,
    not binary byte streams. The error must name the codec, the
    channel, and explain the wrong-input-type rationale.
    """
    run = _make_run(
        PURE_ACGT_SEQ, PHRED_CYCLE_QUAL,
        {"sequences": Compression.NAME_TOKENIZED},
    )
    p = tmp_path / "bad_nt_seq.tio"
    with pytest.raises(ValueError) as excinfo:
        SpectralDataset.write_minimal(
            p, title="t", isa_investigation_id="i",
            runs={}, genomic_runs={"genomic_0001": run},
        )
    msg = str(excinfo.value)
    assert "NAME_TOKENIZED" in msg, f"error must name the codec; got: {msg!r}"
    assert "sequences" in msg, f"error must name the channel; got: {msg!r}"
    # Mentions read_names so the user knows where it *does* belong.
    assert "read_names" in msg, (
        f"error must point at the read_names channel; got: {msg!r}"
    )

    # Same check for the qualities channel (also forbidden).
    run_q = _make_run(
        PURE_ACGT_SEQ, PHRED_CYCLE_QUAL,
        {"qualities": Compression.NAME_TOKENIZED},
    )
    p_q = tmp_path / "bad_nt_qual.tio"
    with pytest.raises(ValueError) as excinfo_q:
        SpectralDataset.write_minimal(
            p_q, title="t", isa_investigation_id="i",
            runs={}, genomic_runs={"genomic_0001": run_q},
        )
    msg_q = str(excinfo_q.value)
    assert "NAME_TOKENIZED" in msg_q
    assert "qualities" in msg_q


def test_mixed_all_three_overrides(tmp_path: Path):
    """All three overrides at once — full codec stack on a single file.

    Exercises sequences=BASE_PACK + qualities=QUALITY_BINNED +
    read_names=NAME_TOKENIZED simultaneously. Verifies the on-disk
    @compression attributes for all three channels and that all
    three round-trip correctly (with QUALITY_BINNED's bin-centre
    inputs preserving byte-exact qualities).
    """
    run = _make_run_with_names(
        PURE_ACGT_SEQ, QUAL_BIN_CENTRE, ILLUMINA_NAMES,
        {
            "sequences": Compression.BASE_PACK,
            "qualities": Compression.QUALITY_BINNED,
            "read_names": Compression.NAME_TOKENIZED,
        },
    )
    p = _write_and_open(tmp_path, run, fname="mixed_all_three.tio")

    with h5py.File(p, "r") as f:
        sc = f["study/genomic_runs/genomic_0001/signal_channels"]
        assert int(sc["sequences"].attrs["compression"]) == int(
            Compression.BASE_PACK.value
        )
        assert int(sc["qualities"].attrs["compression"]) == int(
            Compression.QUALITY_BINNED.value
        )
        assert int(sc["read_names"].attrs["compression"]) == int(
            Compression.NAME_TOKENIZED.value
        )
        # read_names must be the lifted 1-D uint8 layout, not compound.
        assert sc["read_names"].dtype == np.uint8

    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        assert len(gr) == N_READS
        for i in range(N_READS):
            r = gr[i]
            assert r.sequence == _expected_seq_slice(PURE_ACGT_SEQ, i)
            assert r.qualities == _expected_qual_slice(QUAL_BIN_CENTRE, i)
            assert r.read_name == ILLUMINA_NAMES[i]
    finally:
        ds.close()


def test_cross_language_fixture_name_tokenized():
    """Phase E fixture decodes byte-exact: structured Illumina-style names.

    Companion to the QUALITY_BINNED cross-language test — checks
    that the committed fixture round-trips through the Python
    reader, providing the cross-language baseline for ObjC and
    Java conformance.
    """
    fixture_path = FIXTURE_DIR / "m86_codec_name_tokenized.tio"
    assert fixture_path.exists(), (
        f"fixture missing: {fixture_path} — regenerate with "
        f"python/tests/fixtures/genomic/regenerate_m86_name_tokenized.py"
    )
    ds = SpectralDataset.open(fixture_path)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        assert len(gr) == N_READS
        for i in range(N_READS):
            r = gr[i]
            assert r.read_name == ILLUMINA_NAMES[i], (
                f"name_tokenized fixture: read {i} name mismatch — "
                f"got {r.read_name!r}, expected {ILLUMINA_NAMES[i]!r}"
            )
        # Verify the fixture really uses the lifted layout with @compression == 8.
        with h5py.File(fixture_path, "r") as f:
            rn = f["study/genomic_runs/genomic_0001/signal_channels/read_names"]
            assert rn.dtype == np.uint8
            assert int(rn.attrs["compression"]) == int(
                Compression.NAME_TOKENIZED.value
            )
    finally:
        ds.close()


def test_cross_language_fixture_quality_binned():
    """Phase D fixture decodes byte-exact: BASE_PACK seq + QUALITY_BINNED qual.

    The qualities buffer is bin centres, so the lossy QUALITY_BINNED
    round-trip is byte-exact and meaningful for cross-language
    conformance comparison against the ObjC and Java readers.
    """
    fixture_path = FIXTURE_DIR / "m86_codec_quality_binned.tio"
    assert fixture_path.exists(), (
        f"fixture missing: {fixture_path} — regenerate with "
        f"python/tests/fixtures/genomic/regenerate_m86_quality_binned.py"
    )
    ds = SpectralDataset.open(fixture_path)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        assert len(gr) == N_READS
        for i in range(N_READS):
            r = gr[i]
            assert r.sequence == _expected_seq_slice(PURE_ACGT_SEQ, i), (
                f"quality_binned fixture: read {i} sequence mismatch"
            )
            assert r.qualities == _expected_qual_slice(QUAL_BIN_CENTRE, i), (
                f"quality_binned fixture: read {i} qualities mismatch"
            )
        # Verify channel @compression attributes match the fixture spec.
        with h5py.File(fixture_path, "r") as f:
            sc = f["study/genomic_runs/genomic_0001/signal_channels"]
            assert int(sc["sequences"].attrs["compression"]) == int(
                Compression.BASE_PACK.value
            )
            assert int(sc["qualities"].attrs["compression"]) == int(
                Compression.QUALITY_BINNED.value
            )
    finally:
        ds.close()
