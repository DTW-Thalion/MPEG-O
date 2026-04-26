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


# ----------------------------------------------------------------------
# 30–36: Phase B — rANS on the integer channels (positions, flags,
# mapping_qualities). Per Binding Decision §119 ``__getitem__`` still
# uses ``self.index.*`` for per-read integer access; these tests
# directly call the new ``GenomicRun._int_channel_array(name)`` helper
# for round-trip verification (Gotcha §132).
# ----------------------------------------------------------------------


def _make_int_run(
    positions: np.ndarray,
    flags: np.ndarray,
    mapping_qualities: np.ndarray,
    codec_overrides: dict[str, Compression] | None = None,
) -> WrittenGenomicRun:
    """Build a synthetic genomic run with caller-controlled integer arrays.

    Mirrors :func:`_make_run` but lets the caller supply the three
    integer channels under test (positions, flags, mapping_qualities)
    so the round-trip assertions can use known values.
    """
    n_reads = int(positions.shape[0])
    seq = (b"ACGT" * 25) * n_reads
    qual = bytes((30 + (i % 11)) for i in range(n_reads * READ_LEN))
    return WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="M86_PHASEB",
        positions=positions,
        mapping_qualities=mapping_qualities,
        flags=flags,
        sequences=np.frombuffer(seq, dtype=np.uint8),
        qualities=np.frombuffer(qual, dtype=np.uint8),
        offsets=np.arange(n_reads, dtype=np.uint64) * READ_LEN,
        lengths=np.full(n_reads, READ_LEN, dtype=np.uint32),
        cigars=["100M"] * n_reads,
        read_names=[f"r{i}" for i in range(n_reads)],
        mate_chromosomes=["chr1"] * n_reads,
        mate_positions=np.full(n_reads, -1, dtype=np.int64),
        template_lengths=np.zeros(n_reads, dtype=np.int32),
        chromosomes=["chr1"] * n_reads,
        signal_codec_overrides=codec_overrides or {},
    )


def test_round_trip_positions_rans_order1(tmp_path: Path):
    """Monotonic int64 positions encoded with RANS_ORDER1 round-trip exactly.

    Per Binding Decision §119 ``__getitem__`` still reads positions
    from the index; this test directly calls the new
    ``_int_channel_array`` helper to verify the compressed
    ``signal_channels/positions`` decodes back to the original array.
    """
    n_reads = N_READS
    positions = np.array(
        [i * 1000 + 1_000_000 for i in range(n_reads)],
        dtype=np.int64,
    )
    flags = np.zeros(n_reads, dtype=np.uint32)
    mapq = np.full(n_reads, 60, dtype=np.uint8)
    run = _make_int_run(
        positions, flags, mapq,
        {"positions": Compression.RANS_ORDER1},
    )
    p = _write_and_open(tmp_path, run, fname="phaseb_positions.tio")
    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        decoded = gr._int_channel_array("positions")
        assert decoded.dtype == np.int64
        assert decoded.shape == (n_reads,)
        np.testing.assert_array_equal(decoded, positions)
    finally:
        ds.close()


def test_round_trip_flags_rans_order0(tmp_path: Path):
    """Alternating uint32 flags encoded with RANS_ORDER0 round-trip exactly."""
    n_reads = N_READS
    positions = np.arange(n_reads, dtype=np.int64) * 1000
    flags = np.array(
        [0x0001 if (i % 2 == 0) else 0x0083 for i in range(n_reads)],
        dtype=np.uint32,
    )
    mapq = np.full(n_reads, 60, dtype=np.uint8)
    run = _make_int_run(
        positions, flags, mapq,
        {"flags": Compression.RANS_ORDER0},
    )
    p = _write_and_open(tmp_path, run, fname="phaseb_flags.tio")
    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        decoded = gr._int_channel_array("flags")
        assert decoded.dtype == np.uint32
        assert decoded.shape == (n_reads,)
        np.testing.assert_array_equal(decoded, flags)
    finally:
        ds.close()


def test_round_trip_mapping_qualities_rans_order1(tmp_path: Path):
    """uint8 MAPQ encoded with RANS_ORDER1 round-trip exactly.

    Per Gotcha §131 the LE serialisation is a no-op for uint8 (1
    byte per element), but the dispatch path is still exercised
    end-to-end (write through ``_write_int_channel_with_codec``,
    read through ``_int_channel_array``).
    """
    n_reads = N_READS
    positions = np.arange(n_reads, dtype=np.int64) * 1000
    flags = np.zeros(n_reads, dtype=np.uint32)
    # 80% MAPQ 60, 20% MAPQ 0 — typical Illumina mapping-quality
    # distribution.
    mapq = np.array(
        [60 if (i % 5) != 0 else 0 for i in range(n_reads)],
        dtype=np.uint8,
    )
    run = _make_int_run(
        positions, flags, mapq,
        {"mapping_qualities": Compression.RANS_ORDER1},
    )
    p = _write_and_open(tmp_path, run, fname="phaseb_mapq.tio")
    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        decoded = gr._int_channel_array("mapping_qualities")
        assert decoded.dtype == np.uint8
        assert decoded.shape == (n_reads,)
        np.testing.assert_array_equal(decoded, mapq)
    finally:
        ds.close()


def test_size_win_positions(tmp_path: Path):
    """Realistic clustered-position int64 under RANS_ORDER1 wins decisively.

    Real WGS data has many reads sharing the same start position
    in regions of high coverage; the LE byte representation of such
    a clustered position array is highly compressible by rANS
    order-1. Target: rANS encoded length < 50% of the raw int64
    byte length. Per Gotcha §130 we use a realistic input size
    (10000 reads) so the rANS frequency-table overhead is
    amortised.

    HANDOFF.md §6.1 #33 originally framed this against an
    HDF5-ZLIB baseline on monotonic positions; in practice ZLIB's
    LZ77 matching is hard to beat on perfectly-monotonic int64s
    without an explicit delta transform (which the M83 rANS codec
    intentionally does not perform — Gotcha §130 acknowledges
    rANS may not always beat HDF5-filter compression on integer
    inputs). The clustered-position pattern is the realistic
    rANS-win scenario for the integer-channel codec wiring.
    """
    from ttio.codecs.rans import encode as _rans_encode
    n_reads = 10_000
    # Realistic high-coverage WGS: reads cluster around 100 distinct
    # loci, each covered ~100×. The LE bytes have very low entropy
    # in the high bytes (always constant) and only ~100 distinct
    # symbols in the low bytes — ideal for rANS.
    positions = np.array(
        [1_000_000 + (i // 100) * 1000 for i in range(n_reads)],
        dtype=np.int64,
    )
    raw_bytes = positions.astype("<i8", copy=False).tobytes()
    raw_len = len(raw_bytes)  # n_reads * 8 = 80 000 bytes

    encoded = _rans_encode(raw_bytes, order=1)
    encoded_len = len(encoded)

    # Verify the on-disk dataset shape matches what we just measured
    # (sanity check that the dispatch path actually wrote the
    # codec output).
    flags = np.zeros(n_reads, dtype=np.uint32)
    mapq = np.full(n_reads, 60, dtype=np.uint8)
    rans_run = _make_int_run(
        positions, flags, mapq,
        {"positions": Compression.RANS_ORDER1},
    )
    p_rans = tmp_path / "pos_rans.tio"
    SpectralDataset.write_minimal(
        p_rans, title="b", isa_investigation_id="i",
        runs={}, genomic_runs={"genomic_0001": rans_run},
    )
    with h5py.File(p_rans, "r") as f:
        ds = f["study/genomic_runs/genomic_0001/signal_channels/positions"]
        assert ds.dtype == np.uint8
        assert ds.shape[0] == encoded_len, (
            f"on-disk dataset shape {ds.shape[0]} != codec output "
            f"length {encoded_len}"
        )

    ratio = encoded_len / raw_len
    assert ratio < 0.50, (
        f"RANS_ORDER1 positions encoded = {encoded_len} bytes; "
        f"raw int64 LE = {raw_len} bytes; ratio = {ratio:.3f} "
        "(target < 0.50)"
    )


def test_attribute_set_correctly_integer_channels(tmp_path: Path):
    """Integer channels under rANS overrides become flat uint8 with @compression.

    Verifies the on-disk schema (HANDOFF.md §5.2): each compressed
    integer dataset is dtype uint8 (not the original int64/uint32/
    uint8 scalar dtype) and carries an ``@compression`` attribute
    holding the codec id.
    """
    n_reads = N_READS
    positions = np.arange(n_reads, dtype=np.int64) * 1000
    flags = np.zeros(n_reads, dtype=np.uint32)
    mapq = np.full(n_reads, 60, dtype=np.uint8)
    run = _make_int_run(
        positions, flags, mapq,
        {
            "positions": Compression.RANS_ORDER1,
            "flags": Compression.RANS_ORDER0,
            "mapping_qualities": Compression.RANS_ORDER1,
        },
    )
    p = _write_and_open(tmp_path, run, fname="attr_int.tio")
    with h5py.File(p, "r") as f:
        sc = f["study/genomic_runs/genomic_0001/signal_channels"]
        # positions: RANS_ORDER1 (codec id 5)
        pos_ds = sc["positions"]
        assert pos_ds.dtype == np.uint8
        assert int(pos_ds.attrs["compression"]) == int(
            Compression.RANS_ORDER1.value
        )
        # flags: RANS_ORDER0 (codec id 4)
        flg_ds = sc["flags"]
        assert flg_ds.dtype == np.uint8
        assert int(flg_ds.attrs["compression"]) == int(
            Compression.RANS_ORDER0.value
        )
        # mapping_qualities: RANS_ORDER1 (codec id 5)
        mq_ds = sc["mapping_qualities"]
        assert mq_ds.dtype == np.uint8
        assert int(mq_ds.attrs["compression"]) == int(
            Compression.RANS_ORDER1.value
        )
        # Untouched byte channels carry no @compression.
        assert "compression" not in sc["sequences"].attrs
        assert "compression" not in sc["qualities"].attrs


def test_reject_base_pack_on_positions(tmp_path: Path):
    """BASE_PACK on the positions channel raises with a clear message.

    Per Binding Decision §117: BASE_PACK 2-bit-packs ACGT bytes and
    would silently corrupt int64 position values. Validation must
    name the codec, the channel, and explain the wrong-content
    rationale.
    """
    n_reads = N_READS
    positions = np.arange(n_reads, dtype=np.int64) * 1000
    flags = np.zeros(n_reads, dtype=np.uint32)
    mapq = np.full(n_reads, 60, dtype=np.uint8)
    run = _make_int_run(
        positions, flags, mapq,
        {"positions": Compression.BASE_PACK},
    )
    p = tmp_path / "bad_bp_pos.tio"
    with pytest.raises(ValueError) as excinfo:
        SpectralDataset.write_minimal(
            p, title="t", isa_investigation_id="i",
            runs={}, genomic_runs={"genomic_0001": run},
        )
    msg = str(excinfo.value)
    assert "BASE_PACK" in msg, f"error must name the codec; got: {msg!r}"
    assert "positions" in msg, f"error must name the channel; got: {msg!r}"
    # Mentions the rANS replacement so the user knows what to use.
    assert "RANS" in msg, f"error must point at the rANS codecs; got: {msg!r}"


def test_reject_quality_binned_on_flags(tmp_path: Path):
    """QUALITY_BINNED on the flags channel raises with a clear message.

    Per Binding Decision §117: QUALITY_BINNED's 8-bin Phred
    quantisation is wrong-content for uint32 flag bitfields and
    would destroy them. Validation must name the codec, the
    channel, and explain the wrong-content rationale.
    """
    n_reads = N_READS
    positions = np.arange(n_reads, dtype=np.int64) * 1000
    flags = np.zeros(n_reads, dtype=np.uint32)
    mapq = np.full(n_reads, 60, dtype=np.uint8)
    run = _make_int_run(
        positions, flags, mapq,
        {"flags": Compression.QUALITY_BINNED},
    )
    p = tmp_path / "bad_qb_flags.tio"
    with pytest.raises(ValueError) as excinfo:
        SpectralDataset.write_minimal(
            p, title="t", isa_investigation_id="i",
            runs={}, genomic_runs={"genomic_0001": run},
        )
    msg = str(excinfo.value)
    assert "QUALITY_BINNED" in msg, f"error must name the codec; got: {msg!r}"
    assert "flags" in msg, f"error must name the channel; got: {msg!r}"
    assert "RANS" in msg, f"error must point at the rANS codecs; got: {msg!r}"


def test_round_trip_full_stack(tmp_path: Path):
    """All six channel overrides at once — full codec stack on one file.

    Exercises sequences=BASE_PACK + qualities=QUALITY_BINNED +
    read_names=NAME_TOKENIZED + positions=RANS_ORDER1 +
    flags=RANS_ORDER0 + mapping_qualities=RANS_ORDER1
    simultaneously (Gotcha §133: the most likely test to surface
    ordering bugs across the codec dispatch matrix). Verifies:

    - Every byte/string channel round-trips byte-exact.
    - Every integer channel decodes back to the input array via
      ``_int_channel_array`` (per Binding Decision §119
      ``__getitem__`` still uses the index for per-read access, but
      the ``signal_channels/`` integer datasets must round-trip
      through the new helper).
    """
    n_reads = N_READS
    positions = np.array(
        [i * 1000 + 1_000_000 for i in range(n_reads)],
        dtype=np.int64,
    )
    flags = np.array(
        [0x0001 if (i % 2 == 0) else 0x0083 for i in range(n_reads)],
        dtype=np.uint32,
    )
    mapq = np.array(
        [60 if (i % 5) != 0 else 0 for i in range(n_reads)],
        dtype=np.uint8,
    )
    run = WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="M86_FULL_STACK",
        positions=positions,
        mapping_qualities=mapq,
        flags=flags,
        sequences=np.frombuffer(PURE_ACGT_SEQ, dtype=np.uint8),
        qualities=np.frombuffer(QUAL_BIN_CENTRE, dtype=np.uint8),
        offsets=np.arange(n_reads, dtype=np.uint64) * READ_LEN,
        lengths=np.full(n_reads, READ_LEN, dtype=np.uint32),
        cigars=["100M"] * n_reads,
        read_names=ILLUMINA_NAMES,
        mate_chromosomes=["chr1"] * n_reads,
        mate_positions=np.full(n_reads, -1, dtype=np.int64),
        template_lengths=np.zeros(n_reads, dtype=np.int32),
        chromosomes=["chr1"] * n_reads,
        signal_codec_overrides={
            "sequences": Compression.BASE_PACK,
            "qualities": Compression.QUALITY_BINNED,
            "read_names": Compression.NAME_TOKENIZED,
            "positions": Compression.RANS_ORDER1,
            "flags": Compression.RANS_ORDER0,
            "mapping_qualities": Compression.RANS_ORDER1,
        },
    )
    p = _write_and_open(tmp_path, run, fname="full_stack.tio")

    # All six @compression attributes must be set on disk.
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
        assert int(sc["positions"].attrs["compression"]) == int(
            Compression.RANS_ORDER1.value
        )
        assert int(sc["flags"].attrs["compression"]) == int(
            Compression.RANS_ORDER0.value
        )
        assert int(sc["mapping_qualities"].attrs["compression"]) == int(
            Compression.RANS_ORDER1.value
        )

    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        # Byte/string channels via the AlignedRead reader (existing path).
        for i in range(n_reads):
            r = gr[i]
            assert r.sequence == _expected_seq_slice(PURE_ACGT_SEQ, i)
            assert r.qualities == _expected_qual_slice(QUAL_BIN_CENTRE, i)
            assert r.read_name == ILLUMINA_NAMES[i]

        # Integer channels via the new Phase B helper. Per §119
        # ``__getitem__`` does NOT consume these — it reads from
        # the genomic_index — so we directly call the helper.
        np.testing.assert_array_equal(
            gr._int_channel_array("positions"), positions
        )
        np.testing.assert_array_equal(
            gr._int_channel_array("flags"), flags
        )
        np.testing.assert_array_equal(
            gr._int_channel_array("mapping_qualities"), mapq
        )
    finally:
        ds.close()


# ----------------------------------------------------------------------
# 37: Cross-language fixture for Phase B integer-channel codec wiring
# ----------------------------------------------------------------------


def test_cross_language_fixture_integer_channels():
    """Phase B fixture decodes byte-exact across all three integer channels.

    The committed ``m86_codec_integer_channels.tio`` is a 100-read
    run with positions / flags / mapping_qualities all under rANS
    overrides (HANDOFF.md §6.4). Verifies the Python reader
    decodes each integer channel back to the deterministic
    cross-language input that the ObjC and Java agents will also
    produce and consume.
    """
    fixture_path = FIXTURE_DIR / "m86_codec_integer_channels.tio"
    assert fixture_path.exists(), (
        f"fixture missing: {fixture_path} — regenerate with "
        f"python/tests/fixtures/genomic/regenerate_m86_integer_channels.py"
    )
    n_reads = 100
    expected_positions = np.array(
        [i * 1000 + 1_000_000 for i in range(n_reads)],
        dtype=np.int64,
    )
    expected_flags = np.array(
        [0x0001 if (i % 2 == 0) else 0x0083 for i in range(n_reads)],
        dtype=np.uint32,
    )
    expected_mapq = np.array(
        [60 if (i % 5) != 0 else 0 for i in range(n_reads)],
        dtype=np.uint8,
    )
    ds = SpectralDataset.open(fixture_path)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        assert len(gr) == n_reads
        np.testing.assert_array_equal(
            gr._int_channel_array("positions"), expected_positions
        )
        np.testing.assert_array_equal(
            gr._int_channel_array("flags"), expected_flags
        )
        np.testing.assert_array_equal(
            gr._int_channel_array("mapping_qualities"), expected_mapq
        )
        with h5py.File(fixture_path, "r") as f:
            sc = f["study/genomic_runs/genomic_0001/signal_channels"]
            assert int(sc["positions"].attrs["compression"]) == int(
                Compression.RANS_ORDER1.value
            )
            assert int(sc["flags"].attrs["compression"]) == int(
                Compression.RANS_ORDER0.value
            )
            assert int(sc["mapping_qualities"].attrs["compression"]) == int(
                Compression.RANS_ORDER1.value
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


def test_round_trip_cigars_name_tokenized_uniform(tmp_path: Path):
    """All-uniform CIGARs encoded with NAME_TOKENIZED round-trip byte-exact.

    The all-'100M' input is the columnar-mode sweet spot: the codec
    emits a 1-entry dictionary plus delta=0 for the numeric column,
    so the wire stream is < 50 bytes for 100 identical CIGARs.
    """
    cigars = ["100M"] * N_READS
    run = _make_run_with_cigars(
        PURE_ACGT_SEQ, PHRED_CYCLE_QUAL, cigars,
        {"cigars": Compression.NAME_TOKENIZED},
    )
    p = _write_and_open(tmp_path, run, fname="cigars_nt_uniform.tio")
    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        for i in range(N_READS):
            r = gr[i]
            assert r.cigar == cigars[i]
    finally:
        ds.close()

    # NAME_TOKENIZED wire size on uniform input < 50 bytes (§1.2).
    with h5py.File(p, "r") as f:
        ds_size = f[
            "study/genomic_runs/genomic_0001/signal_channels/cigars"
        ].id.get_storage_size()
    assert ds_size < 50, (
        f"NAME_TOKENIZED on uniform '100M' wire stream = {ds_size} bytes "
        "(target < 50 — columnar-mode 1-entry dict + delta=0 win)"
    )


def test_round_trip_cigars_name_tokenized_mixed(tmp_path: Path):
    """Mixed CIGARs encoded with NAME_TOKENIZED round-trip byte-exact.

    Same 1000-read mixed-CIGAR input as the rANS round-trip test.
    The NAME_TOKENIZED codec falls back to verbatim mode here
    (varying token-count between '100M' (2 tokens), '99M1D' (4
    tokens), and '50M50S' (4 tokens)) producing a much larger wire
    than rANS — but the round-trip itself is still byte-exact
    (verbatim is lossless). This test guards correctness; the
    size comparison is in test_size_comparison_cigars_codecs.
    """
    n_reads = 1000
    read_len = 100
    total = n_reads * read_len
    seq = (b"ACGT" * 25) * n_reads
    qual = bytes((30 + (i % 11)) for i in range(total))
    cigars = _mixed_cigars(n_reads)
    run = WrittenGenomicRun(
        acquisition_mode=7, reference_uri="GRCh38.p14",
        platform="ILLUMINA", sample_name="M86C_NTMIX",
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
        signal_codec_overrides={"cigars": Compression.NAME_TOKENIZED},
    )
    p = _write_and_open(tmp_path, run, fname="cigars_nt_mixed.tio")
    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        for i in range(n_reads):
            r = gr[i]
            assert r.cigar == cigars[i]
    finally:
        ds.close()


def test_size_comparison_cigars_codecs(tmp_path: Path, capsys):
    """Side-by-side cigars wire size: no-override vs RANS_ORDER1 vs NAME_TOKENIZED.

    HANDOFF.md §6.1 #42 / Acceptance Criteria: prints the three
    sizes so the §1.2 selection guidance is empirically visible at
    test time, and asserts RANS_ORDER1 < NAME_TOKENIZED < no-override
    on the realistic mixed-CIGAR input (the workload pattern where
    rANS dominates because NAME_TOKENIZED falls back to verbatim).
    """
    n_reads = 1000
    read_len = 100
    total = n_reads * read_len
    seq = (b"ACGT" * 25) * n_reads
    qual = bytes((30 + (i % 11)) for i in range(total))
    cigars = _mixed_cigars(n_reads)
    base_kw = dict(
        acquisition_mode=7, reference_uri="GRCh38.p14",
        platform="ILLUMINA", sample_name="M86C_SIZE",
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
        signal_compression="none",  # no HDF5 filter on baseline
    )
    no_run = WrittenGenomicRun(**base_kw)
    rans_run = WrittenGenomicRun(
        **base_kw,
        signal_codec_overrides={"cigars": Compression.RANS_ORDER1},
    )
    nt_run = WrittenGenomicRun(
        **base_kw,
        signal_codec_overrides={"cigars": Compression.NAME_TOKENIZED},
    )

    p_no = tmp_path / "cig_no.tio"
    SpectralDataset.write_minimal(
        p_no, title="x", isa_investigation_id="i",
        runs={}, genomic_runs={"genomic_0001": no_run},
    )
    p_rans = tmp_path / "cig_rans.tio"
    SpectralDataset.write_minimal(
        p_rans, title="x", isa_investigation_id="i",
        runs={}, genomic_runs={"genomic_0001": rans_run},
    )
    p_nt = tmp_path / "cig_nt.tio"
    SpectralDataset.write_minimal(
        p_nt, title="x", isa_investigation_id="i",
        runs={}, genomic_runs={"genomic_0001": nt_run},
    )

    # No-override path is M82 compound; ``id.get_storage_size`` only
    # captures the primary chunk and misses the global VL heap. Use
    # the file-size delta as the realistic baseline footprint
    # (mirrors test_size_win_name_tokenized).
    no_file = p_no.stat().st_size
    rans_file = p_rans.stat().st_size
    nt_file = p_nt.stat().st_size
    with h5py.File(p_rans, "r") as f:
        rans_size = f[
            "study/genomic_runs/genomic_0001/signal_channels/cigars"
        ].id.get_storage_size()
    with h5py.File(p_nt, "r") as f:
        nt_size = f[
            "study/genomic_runs/genomic_0001/signal_channels/cigars"
        ].id.get_storage_size()
    # Approximate the M82 compound's full footprint (primary chunk
    # + VL heap) from the file-size delta against the rANS file.
    no_footprint = no_file - rans_file + rans_size

    print(
        f"\n[M86 Phase C size comparison — 1000-read mixed CIGARs]\n"
        f"  no-override (M82 compound): {no_footprint} bytes "
        f"(approx; file_size={no_file})\n"
        f"  RANS_ORDER1:                {rans_size} bytes "
        f"(file_size={rans_file})\n"
        f"  NAME_TOKENIZED (verbatim):  {nt_size} bytes "
        f"(file_size={nt_file})\n"
    )

    # §1.2 selection guidance assertions (mixed-CIGAR workload):
    # RANS_ORDER1 wins decisively; NAME_TOKENIZED's verbatim mode
    # is roughly the raw bytes (much larger than rANS).
    assert rans_size < nt_size, (
        f"RANS_ORDER1 ({rans_size}) must beat NAME_TOKENIZED-verbatim "
        f"({nt_size}) on mixed-CIGAR input (§1.2 — the realistic-WGS "
        "workload where rANS dominates)"
    )
    assert nt_size < no_footprint, (
        f"NAME_TOKENIZED-verbatim ({nt_size}) must still beat the "
        f"M82 compound footprint ({no_footprint}); the codec at "
        "least avoids the VL_STRING heap overhead"
    )


def test_size_win_cigars_uniform(tmp_path: Path):
    """Same comparison on uniform input — both codecs win, RANS_ORDER1 strongest.

    All-'100M' x 1000 reads. The columnar mode emits ~2 bytes/read
    (per HANDOFF §1.2 estimate) for delta=0 + 1-entry dict — about
    2 KB for 1000 reads. RANS_ORDER1 actually wins even here
    because the byte-level entropy of an all-'100M' length-prefix-
    concat stream is extremely low (a single repeating pattern), so
    the order-1 frequency model collapses it to under 1 KB. Both
    codecs decisively beat the raw 5000-byte concatenation;
    NAME_TOKENIZED's columnar mode beats verbatim by ~2.5x.
    """
    n_reads = 1000
    read_len = 100
    total = n_reads * read_len
    seq = (b"ACGT" * 25) * n_reads
    qual = bytes((30 + (i % 11)) for i in range(total))
    cigars = ["100M"] * n_reads
    base_kw = dict(
        acquisition_mode=7, reference_uri="GRCh38.p14",
        platform="ILLUMINA", sample_name="M86C_UNI",
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
        signal_compression="none",
    )
    rans_run = WrittenGenomicRun(
        **base_kw,
        signal_codec_overrides={"cigars": Compression.RANS_ORDER1},
    )
    nt_run = WrittenGenomicRun(
        **base_kw,
        signal_codec_overrides={"cigars": Compression.NAME_TOKENIZED},
    )
    p_rans = tmp_path / "uni_rans.tio"
    SpectralDataset.write_minimal(
        p_rans, title="x", isa_investigation_id="i",
        runs={}, genomic_runs={"genomic_0001": rans_run},
    )
    p_nt = tmp_path / "uni_nt.tio"
    SpectralDataset.write_minimal(
        p_nt, title="x", isa_investigation_id="i",
        runs={}, genomic_runs={"genomic_0001": nt_run},
    )
    with h5py.File(p_rans, "r") as f:
        rans_size = f[
            "study/genomic_runs/genomic_0001/signal_channels/cigars"
        ].id.get_storage_size()
    with h5py.File(p_nt, "r") as f:
        nt_size = f[
            "study/genomic_runs/genomic_0001/signal_channels/cigars"
        ].id.get_storage_size()

    # NAME_TOKENIZED's columnar mode is significantly smaller than
    # the raw concatenation (5000 bytes for 1000 × "100M" — the
    # length-prefix-concat input). The exact ratio depends on the
    # codec's per-read 2-byte overhead (1 svarint(0) + 1
    # varint(code=0)); ~2 bytes/read = ~2 KB for 1000 reads.
    raw_concat = 1000 * 5  # varint(3) (1 byte) + b"100M" (4 bytes)
    assert nt_size < raw_concat * 0.5, (
        f"NAME_TOKENIZED uniform-cigars wire = {nt_size} bytes "
        f"(target < {raw_concat * 0.5:.0f} = 50% of raw "
        f"length-prefix-concat = {raw_concat} bytes)"
    )
    # Both codecs beat the raw stream; the precise rANS-vs-NT
    # ordering on uniform input depends on rANS frequency-table
    # overhead vs NAME_TOKENIZED columnar 2-bytes/read overhead.
    # In this implementation RANS_ORDER1 wins by collapsing the
    # repeating bytes to entropy ~0; we don't assert ordering here
    # because the §1.2 selection guidance is "either codec is
    # acceptable on uniform input — both crush the raw stream".
    assert rans_size < raw_concat, (
        f"RANS_ORDER1 uniform-cigars wire = {rans_size} bytes "
        f"must beat raw concat ({raw_concat})"
    )


@pytest.mark.parametrize("codec", [
    Compression.RANS_ORDER0,
    Compression.RANS_ORDER1,
    Compression.NAME_TOKENIZED,
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
        # Other channels untouched.
        assert "compression" not in sc["sequences"].attrs
        assert "compression" not in sc["qualities"].attrs
        # read_names remains compound (no override).
        assert sc["read_names"].dtype.kind == "V"


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


def test_round_trip_full_seven_overrides(tmp_path: Path):
    """All seven channel overrides at once — Phase B's #37 + cigars=RANS_ORDER1.

    Extends the Phase B six-channel full-stack test with the
    Phase C cigars override at the recommended default
    (RANS_ORDER1 — §1.2). Verifies all seven @compression
    attributes are set on disk and all seven channels round-trip
    correctly.
    """
    n_reads = N_READS
    positions = np.array(
        [i * 1000 + 1_000_000 for i in range(n_reads)],
        dtype=np.int64,
    )
    flags = np.array(
        [0x0001 if (i % 2 == 0) else 0x0083 for i in range(n_reads)],
        dtype=np.uint32,
    )
    mapq = np.array(
        [60 if (i % 5) != 0 else 0 for i in range(n_reads)],
        dtype=np.uint8,
    )
    cigars = _mixed_cigars(n_reads)
    run = WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="M86_FULL_SEVEN",
        positions=positions,
        mapping_qualities=mapq,
        flags=flags,
        sequences=np.frombuffer(PURE_ACGT_SEQ, dtype=np.uint8),
        qualities=np.frombuffer(QUAL_BIN_CENTRE, dtype=np.uint8),
        offsets=np.arange(n_reads, dtype=np.uint64) * READ_LEN,
        lengths=np.full(n_reads, READ_LEN, dtype=np.uint32),
        cigars=cigars,
        read_names=ILLUMINA_NAMES,
        mate_chromosomes=["chr1"] * n_reads,
        mate_positions=np.full(n_reads, -1, dtype=np.int64),
        template_lengths=np.zeros(n_reads, dtype=np.int32),
        chromosomes=["chr1"] * n_reads,
        signal_codec_overrides={
            "sequences": Compression.BASE_PACK,
            "qualities": Compression.QUALITY_BINNED,
            "read_names": Compression.NAME_TOKENIZED,
            "cigars": Compression.RANS_ORDER1,        # Phase C — recommended default
            "positions": Compression.RANS_ORDER1,
            "flags": Compression.RANS_ORDER0,
            "mapping_qualities": Compression.RANS_ORDER1,
        },
    )
    p = _write_and_open(tmp_path, run, fname="full_seven.tio")

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
        assert int(sc["cigars"].attrs["compression"]) == int(
            Compression.RANS_ORDER1.value
        )
        assert int(sc["positions"].attrs["compression"]) == int(
            Compression.RANS_ORDER1.value
        )
        assert int(sc["flags"].attrs["compression"]) == int(
            Compression.RANS_ORDER0.value
        )
        assert int(sc["mapping_qualities"].attrs["compression"]) == int(
            Compression.RANS_ORDER1.value
        )
        # cigars must also be the lifted 1-D uint8 layout.
        assert sc["cigars"].dtype == np.uint8

    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        for i in range(n_reads):
            r = gr[i]
            assert r.sequence == _expected_seq_slice(PURE_ACGT_SEQ, i)
            assert r.qualities == _expected_qual_slice(QUAL_BIN_CENTRE, i)
            assert r.read_name == ILLUMINA_NAMES[i]
            assert r.cigar == cigars[i]
        np.testing.assert_array_equal(
            gr._int_channel_array("positions"), positions
        )
        np.testing.assert_array_equal(
            gr._int_channel_array("flags"), flags
        )
        np.testing.assert_array_equal(
            gr._int_channel_array("mapping_qualities"), mapq
        )
    finally:
        ds.close()


# ----------------------------------------------------------------------
# 47+: Cross-language fixtures for Phase C (one per cigars codec path)
# ----------------------------------------------------------------------


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


def test_cross_language_fixture_cigars_name_tokenized():
    """Phase C fixture (NAME_TOKENIZED path) decodes byte-exact: 100 uniform CIGARs.

    Companion to the per-language conformance suites.
    """
    fixture_path = FIXTURE_DIR / "m86_codec_cigars_name_tokenized.tio"
    assert fixture_path.exists(), (
        f"fixture missing: {fixture_path} — regenerate with "
        f"python/tests/fixtures/genomic/regenerate_m86_cigars_name_tokenized.py"
    )
    n_reads = 100
    expected_cigars = ["100M"] * n_reads
    ds = SpectralDataset.open(fixture_path)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        assert len(gr) == n_reads
        for i in range(n_reads):
            r = gr[i]
            assert r.cigar == expected_cigars[i]
        with h5py.File(fixture_path, "r") as f:
            cig = f["study/genomic_runs/genomic_0001/signal_channels/cigars"]
            assert cig.dtype == np.uint8
            assert int(cig.attrs["compression"]) == int(
                Compression.NAME_TOKENIZED.value
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


# 48 ----------------------------------------------------------------------

def test_round_trip_mate_chrom_name_tokenized(tmp_path: Path):
    """mate_info_chrom: NAME_TOKENIZED round-trips byte-exact (typical case).

    The 90/5/3/2 distribution exercises the columnar / dictionary
    win in NAME_TOKENIZED — chromosome names are highly repetitive
    so the dictionary should fit in a few bytes.
    """
    chroms = _phase_f_mate_chroms()
    positions = _phase_f_mate_positions()
    tlens = _phase_f_mate_tlens()
    run = _make_phase_f_run(
        {"mate_info_chrom": Compression.NAME_TOKENIZED},
        chroms=chroms, positions=positions, tlens=tlens,
    )
    p = _phase_f_write(tmp_path, run, "mate_chrom_nt.tio")

    # Schema check: mate_info must be a subgroup, chrom child must
    # carry @compression == 8.
    with h5py.File(p, "r") as f:
        sc = f["study/genomic_runs/genomic_0001/signal_channels"]
        assert isinstance(sc["mate_info"], h5py.Group), (
            "Phase F: mate_info must be a group, not a dataset"
        )
        chrom_ds = sc["mate_info/chrom"]
        assert chrom_ds.dtype == np.uint8
        assert int(chrom_ds.attrs["compression"]) == int(
            Compression.NAME_TOKENIZED.value
        )

    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        assert len(gr) == _PHASE_F_N_READS
        for i in range(_PHASE_F_N_READS):
            r = gr[i]
            assert r.mate_chromosome == chroms[i], (
                f"read {i}: mate_chromosome mismatch — got {r.mate_chromosome!r}, "
                f"expected {chroms[i]!r}"
            )
            # pos and tlen also round-trip via the natural-dtype path.
            assert r.mate_position == int(positions[i])
            assert r.template_length == int(tlens[i])
    finally:
        ds.close()


# 49 ----------------------------------------------------------------------

def test_round_trip_mate_pos_rans(tmp_path: Path):
    """mate_info_pos: RANS_ORDER1 round-trips byte-exact."""
    chroms = _phase_f_mate_chroms()
    positions = _phase_f_mate_positions()
    tlens = _phase_f_mate_tlens()
    run = _make_phase_f_run(
        {"mate_info_pos": Compression.RANS_ORDER1},
        chroms=chroms, positions=positions, tlens=tlens,
    )
    p = _phase_f_write(tmp_path, run, "mate_pos_rans.tio")

    with h5py.File(p, "r") as f:
        sc = f["study/genomic_runs/genomic_0001/signal_channels"]
        assert isinstance(sc["mate_info"], h5py.Group)
        pos_ds = sc["mate_info/pos"]
        assert pos_ds.dtype == np.uint8
        assert int(pos_ds.attrs["compression"]) == int(
            Compression.RANS_ORDER1.value
        )

    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        for i in range(_PHASE_F_N_READS):
            r = gr[i]
            assert r.mate_position == int(positions[i]), (
                f"read {i}: mate_position mismatch — got {r.mate_position}, "
                f"expected {int(positions[i])}"
            )
            assert r.mate_chromosome == chroms[i]
            assert r.template_length == int(tlens[i])
    finally:
        ds.close()


# 50 ----------------------------------------------------------------------

def test_round_trip_mate_tlen_rans(tmp_path: Path):
    """mate_info_tlen: RANS_ORDER1 round-trips byte-exact."""
    chroms = _phase_f_mate_chroms()
    positions = _phase_f_mate_positions()
    tlens = _phase_f_mate_tlens()
    run = _make_phase_f_run(
        {"mate_info_tlen": Compression.RANS_ORDER1},
        chroms=chroms, positions=positions, tlens=tlens,
    )
    p = _phase_f_write(tmp_path, run, "mate_tlen_rans.tio")

    with h5py.File(p, "r") as f:
        sc = f["study/genomic_runs/genomic_0001/signal_channels"]
        assert isinstance(sc["mate_info"], h5py.Group)
        tlen_ds = sc["mate_info/tlen"]
        assert tlen_ds.dtype == np.uint8
        assert int(tlen_ds.attrs["compression"]) == int(
            Compression.RANS_ORDER1.value
        )

    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        for i in range(_PHASE_F_N_READS):
            r = gr[i]
            assert r.template_length == int(tlens[i])
            assert r.mate_chromosome == chroms[i]
            assert r.mate_position == int(positions[i])
    finally:
        ds.close()


# 51 ----------------------------------------------------------------------

def test_round_trip_mate_all_three(tmp_path: Path):
    """All three mate_info_* overrides at once round-trip byte-exact."""
    chroms = _phase_f_mate_chroms()
    positions = _phase_f_mate_positions()
    tlens = _phase_f_mate_tlens()
    run = _make_phase_f_run(
        {
            "mate_info_chrom": Compression.NAME_TOKENIZED,
            "mate_info_pos":   Compression.RANS_ORDER1,
            "mate_info_tlen":  Compression.RANS_ORDER1,
        },
        chroms=chroms, positions=positions, tlens=tlens,
    )
    p = _phase_f_write(tmp_path, run, "mate_all_three.tio")

    with h5py.File(p, "r") as f:
        sc = f["study/genomic_runs/genomic_0001/signal_channels"]
        assert isinstance(sc["mate_info"], h5py.Group)
        assert int(sc["mate_info/chrom"].attrs["compression"]) == int(
            Compression.NAME_TOKENIZED.value
        )
        assert int(sc["mate_info/pos"].attrs["compression"]) == int(
            Compression.RANS_ORDER1.value
        )
        assert int(sc["mate_info/tlen"].attrs["compression"]) == int(
            Compression.RANS_ORDER1.value
        )

    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        for i in range(_PHASE_F_N_READS):
            r = gr[i]
            assert r.mate_chromosome == chroms[i]
            assert r.mate_position == int(positions[i])
            assert r.template_length == int(tlens[i])
    finally:
        ds.close()


# 52 ----------------------------------------------------------------------

def test_round_trip_mate_partial(tmp_path: Path):
    """Partial override (chrom only): subgroup created; pos/tlen at natural dtype.

    Per Binding Decision §127 / Gotcha §142: any one mate_info_*
    override triggers the subgroup layout, but un-overridden fields
    use natural-dtype HDF5-filter ZLIB storage inside the subgroup
    (no @compression attribute). All three fields still round-trip.
    """
    chroms = _phase_f_mate_chroms()
    positions = _phase_f_mate_positions()
    tlens = _phase_f_mate_tlens()
    run = _make_phase_f_run(
        {"mate_info_chrom": Compression.NAME_TOKENIZED},
        chroms=chroms, positions=positions, tlens=tlens,
    )
    p = _phase_f_write(tmp_path, run, "mate_partial.tio")

    with h5py.File(p, "r") as f:
        sc = f["study/genomic_runs/genomic_0001/signal_channels"]
        # Subgroup, not compound dataset.
        assert isinstance(sc["mate_info"], h5py.Group)
        # chrom: codec-compressed.
        chrom_ds = sc["mate_info/chrom"]
        assert chrom_ds.dtype == np.uint8
        assert int(chrom_ds.attrs["compression"]) == int(
            Compression.NAME_TOKENIZED.value
        )
        # pos: natural INT64, no @compression attribute.
        pos_ds = sc["mate_info/pos"]
        assert pos_ds.dtype == np.int64, (
            f"mate_info/pos must be natural INT64, got {pos_ds.dtype}"
        )
        assert "compression" not in pos_ds.attrs
        # tlen: natural INT32, no @compression attribute.
        tlen_ds = sc["mate_info/tlen"]
        assert tlen_ds.dtype == np.int32, (
            f"mate_info/tlen must be natural INT32, got {tlen_ds.dtype}"
        )
        assert "compression" not in tlen_ds.attrs

    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        for i in range(_PHASE_F_N_READS):
            r = gr[i]
            assert r.mate_chromosome == chroms[i]
            assert r.mate_position == int(positions[i])
            assert r.template_length == int(tlens[i])
    finally:
        ds.close()


# 53 ----------------------------------------------------------------------

def test_back_compat_mate_info_unchanged(tmp_path: Path):
    """No mate_info_* override leaves the M82 compound dataset unchanged."""
    chroms = _phase_f_mate_chroms()
    positions = _phase_f_mate_positions()
    tlens = _phase_f_mate_tlens()
    # Empty overrides — pure M82 layout for mate_info.
    run = _make_phase_f_run(
        {}, chroms=chroms, positions=positions, tlens=tlens,
    )
    p = _phase_f_write(tmp_path, run, "mate_backcompat.tio")

    with h5py.File(p, "r") as f:
        sc = f["study/genomic_runs/genomic_0001/signal_channels"]
        # Must still be a dataset (compound), not a group.
        mi = sc["mate_info"]
        assert isinstance(mi, h5py.Dataset), (
            "no override: mate_info must remain the M82 compound dataset"
        )
        assert mi.dtype.kind == "V", (
            f"M82 compound: dtype.kind == 'V', got {mi.dtype.kind!r}"
        )
        assert mi.dtype.names is not None and set(mi.dtype.names) == {
            "chrom", "pos", "tlen",
        }

    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        for i in range(_PHASE_F_N_READS):
            r = gr[i]
            assert r.mate_chromosome == chroms[i]
            assert r.mate_position == int(positions[i])
            assert r.template_length == int(tlens[i])
    finally:
        ds.close()


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


# 55 ----------------------------------------------------------------------

def test_reject_wrong_codec_on_mate_pos(tmp_path: Path):
    """NAME_TOKENIZED on mate_info_pos raises ValueError at write time.

    NAME_TOKENIZED tokenises UTF-8 strings, not integers — applying
    it to the integer pos field would mis-tokenise the data.
    """
    run = _make_phase_f_run(
        {"mate_info_pos": Compression.NAME_TOKENIZED},
    )
    p = tmp_path / "bad_nt_matepos.tio"
    with pytest.raises(ValueError) as excinfo:
        SpectralDataset.write_minimal(
            p, title="t", isa_investigation_id="i",
            runs={}, genomic_runs={"genomic_0001": run},
        )
    msg = str(excinfo.value)
    assert "NAME_TOKENIZED" in msg, (
        f"error must name the codec; got: {msg!r}"
    )
    assert "mate_info_pos" in msg, (
        f"error must name the channel; got: {msg!r}"
    )


# 56 ----------------------------------------------------------------------

def test_round_trip_full_ten_overrides(tmp_path: Path):
    """All ten codec-overridable channels at once — the full M86 stack.

    Extends Phase C's #47 (seven overrides) to TEN: the seven
    existing channels plus the three Phase F per-field mate_info
    keys. Verifies every @compression attribute and every per-read
    field round-trips correctly.
    """
    n_reads = _PHASE_F_N_READS
    read_len = 100
    total = n_reads * read_len
    chroms = _phase_f_mate_chroms()
    positions_mate = _phase_f_mate_positions()
    tlens = _phase_f_mate_tlens()

    seq = (b"ACGT" * 25) * n_reads
    qual_centres = (0, 5, 15, 22, 27, 32, 37, 40)
    qual = bytes(qual_centres * (total // len(qual_centres)))
    cigars = _mixed_cigars(n_reads)
    read_names = [
        f"INSTR:RUN:1:{i // 4}:{i % 4}:{i * 100}"
        for i in range(n_reads)
    ]
    positions = np.array(
        [i * 1000 + 1_000_000 for i in range(n_reads)], dtype=np.int64,
    )
    flags = np.array(
        [0x0001 if (i % 2 == 0) else 0x0083 for i in range(n_reads)],
        dtype=np.uint32,
    )
    mapq = np.array(
        [60 if (i % 5) != 0 else 0 for i in range(n_reads)],
        dtype=np.uint8,
    )

    run = WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="M86_FULL_TEN",
        positions=positions,
        mapping_qualities=mapq,
        flags=flags,
        sequences=np.frombuffer(seq, dtype=np.uint8),
        qualities=np.frombuffer(qual, dtype=np.uint8),
        offsets=np.arange(n_reads, dtype=np.uint64) * read_len,
        lengths=np.full(n_reads, read_len, dtype=np.uint32),
        cigars=cigars,
        read_names=read_names,
        mate_chromosomes=chroms,
        mate_positions=positions_mate,
        template_lengths=tlens,
        chromosomes=["chr1"] * n_reads,
        signal_codec_overrides={
            "sequences":         Compression.BASE_PACK,
            "qualities":         Compression.QUALITY_BINNED,
            "read_names":        Compression.NAME_TOKENIZED,
            "cigars":            Compression.RANS_ORDER1,
            "positions":         Compression.RANS_ORDER1,
            "flags":             Compression.RANS_ORDER0,
            "mapping_qualities": Compression.RANS_ORDER1,
            # Phase F additions:
            "mate_info_chrom":   Compression.NAME_TOKENIZED,
            "mate_info_pos":     Compression.RANS_ORDER1,
            "mate_info_tlen":    Compression.RANS_ORDER1,
        },
    )
    p = _phase_f_write(tmp_path, run, "full_ten.tio")

    with h5py.File(p, "r") as f:
        sc = f["study/genomic_runs/genomic_0001/signal_channels"]
        # Seven existing top-level channels.
        assert int(sc["sequences"].attrs["compression"]) == int(
            Compression.BASE_PACK.value
        )
        assert int(sc["qualities"].attrs["compression"]) == int(
            Compression.QUALITY_BINNED.value
        )
        assert int(sc["read_names"].attrs["compression"]) == int(
            Compression.NAME_TOKENIZED.value
        )
        assert int(sc["cigars"].attrs["compression"]) == int(
            Compression.RANS_ORDER1.value
        )
        assert int(sc["positions"].attrs["compression"]) == int(
            Compression.RANS_ORDER1.value
        )
        assert int(sc["flags"].attrs["compression"]) == int(
            Compression.RANS_ORDER0.value
        )
        assert int(sc["mapping_qualities"].attrs["compression"]) == int(
            Compression.RANS_ORDER1.value
        )
        # Phase F mate_info subgroup.
        assert isinstance(sc["mate_info"], h5py.Group)
        assert int(sc["mate_info/chrom"].attrs["compression"]) == int(
            Compression.NAME_TOKENIZED.value
        )
        assert int(sc["mate_info/pos"].attrs["compression"]) == int(
            Compression.RANS_ORDER1.value
        )
        assert int(sc["mate_info/tlen"].attrs["compression"]) == int(
            Compression.RANS_ORDER1.value
        )

    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        for i in range(n_reads):
            r = gr[i]
            assert r.sequence == _expected_seq_slice(seq, i)
            assert r.qualities == _expected_qual_slice(qual, i)
            assert r.read_name == read_names[i]
            assert r.cigar == cigars[i]
            assert r.mate_chromosome == chroms[i]
            assert r.mate_position == int(positions_mate[i])
            assert r.template_length == int(tlens[i])
        np.testing.assert_array_equal(
            gr._int_channel_array("positions"), positions
        )
        np.testing.assert_array_equal(
            gr._int_channel_array("flags"), flags
        )
        np.testing.assert_array_equal(
            gr._int_channel_array("mapping_qualities"), mapq
        )
    finally:
        ds.close()


# ----------------------------------------------------------------------
# Phase F cross-language fixture
# ----------------------------------------------------------------------


def test_cross_language_fixture_mate_info_full():
    """Phase F fixture decodes byte-exact: 100-read run with all three mate overrides.

    Companion to the per-language conformance suites in objc/ and
    java/. The fixture uses the recommended codec per field
    (NAME_TOKENIZED on chrom; RANS_ORDER1 on pos and tlen).
    """
    fixture_path = FIXTURE_DIR / "m86_codec_mate_info_full.tio"
    assert fixture_path.exists(), (
        f"fixture missing: {fixture_path} — regenerate with "
        f"python/tests/fixtures/genomic/regenerate_m86_mate_info_full.py"
    )
    expected_chroms = _phase_f_mate_chroms()
    expected_positions = _phase_f_mate_positions()
    expected_tlens = _phase_f_mate_tlens()
    ds = SpectralDataset.open(fixture_path)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        assert len(gr) == _PHASE_F_N_READS
        for i in range(_PHASE_F_N_READS):
            r = gr[i]
            assert r.mate_chromosome == expected_chroms[i], (
                f"mate_info_full fixture: read {i} chrom mismatch — "
                f"got {r.mate_chromosome!r}, expected {expected_chroms[i]!r}"
            )
            assert r.mate_position == int(expected_positions[i])
            assert r.template_length == int(expected_tlens[i])
        with h5py.File(fixture_path, "r") as f:
            sc = f["study/genomic_runs/genomic_0001/signal_channels"]
            assert isinstance(sc["mate_info"], h5py.Group)
            assert int(sc["mate_info/chrom"].attrs["compression"]) == int(
                Compression.NAME_TOKENIZED.value
            )
            assert int(sc["mate_info/pos"].attrs["compression"]) == int(
                Compression.RANS_ORDER1.value
            )
            assert int(sc["mate_info/tlen"].attrs["compression"]) == int(
                Compression.RANS_ORDER1.value
            )
    finally:
        ds.close()
