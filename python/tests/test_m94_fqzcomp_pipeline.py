"""End-to-end M94 FQZCOMP_NX16 pipeline tests via SpectralDataset.write_minimal + open.

Mirrors M93's pattern: round-trip, format-version 1.5 trigger, default
codec auto-applies (Q5a=B), explicit override, signal_compression="none"
disables, REVERSE flag affects encoding.
"""
from __future__ import annotations

import h5py
import numpy as np
import pytest

from ttio import SpectralDataset, WrittenGenomicRun
from ttio.enums import AcquisitionMode, Compression


def _build_fqz_run(
    n_reads: int = 5,
    read_len: int = 10,
    flags_value: int = 0,
    *,
    quals_seed: int = 0,
    signal_codec_overrides: dict | None = None,
    signal_compression: str = "gzip",
) -> WrittenGenomicRun:
    if signal_codec_overrides is None:
        signal_codec_overrides = {"qualities": Compression.FQZCOMP_NX16}
    seq = b"ACGTACGTAC"[:read_len]
    sequences = np.frombuffer(seq * n_reads, dtype=np.uint8)
    if quals_seed == 0:
        # Constant Q30
        qualities = np.full(len(sequences), 30 + 33, dtype=np.uint8)
    else:
        import random
        rng = random.Random(quals_seed)
        qualities = np.array(
            [rng.randrange(20 + 33, 40 + 33) for _ in range(n_reads * read_len)],
            dtype=np.uint8,
        )
    return WrittenGenomicRun(
        acquisition_mode=int(AcquisitionMode.GENOMIC_WGS),
        reference_uri="m94-test-uri",
        platform="ILLUMINA",
        sample_name="m94",
        positions=np.array([1] * n_reads, dtype=np.int64),
        mapping_qualities=np.full(n_reads, 60, dtype=np.uint8),
        flags=np.full(n_reads, flags_value, dtype=np.uint32),
        sequences=sequences,
        qualities=qualities,
        offsets=np.arange(n_reads, dtype=np.uint64) * read_len,
        lengths=np.full(n_reads, read_len, dtype=np.uint32),
        cigars=[f"{read_len}M"] * n_reads,
        read_names=[f"r{i}" for i in range(n_reads)],
        mate_chromosomes=["*"] * n_reads,
        mate_positions=np.full(n_reads, -1, dtype=np.int64),
        template_lengths=np.zeros(n_reads, dtype=np.int32),
        chromosomes=["22"] * n_reads,
        signal_codec_overrides=signal_codec_overrides,
        signal_compression=signal_compression,
    )


def test_write_then_read_round_trip_with_fqzcomp_nx16(tmp_path):
    run = _build_fqz_run(n_reads=10, read_len=20, quals_seed=0xBEEF)
    path = tmp_path / "fqz_round_trip.tio"
    SpectralDataset.write_minimal(
        path,
        title="m94 round trip",
        isa_investigation_id="TTIO:m94:rt",
        runs={"run_0001": run},
    )
    with SpectralDataset.open(path) as ds:
        out_run = ds.runs["run_0001"]
        assert len(out_run) == 10
        for i in range(10):
            # Phred quality vector should round-trip byte-exact.
            decoded = out_run[i].qualities
            expected = bytes(run.qualities[i * 20:(i + 1) * 20].tobytes())
            assert decoded == expected


def test_format_version_is_1_5_when_fqzcomp_used(tmp_path):
    run = _build_fqz_run()
    path = tmp_path / "fqz_fv_1_5.tio"
    SpectralDataset.write_minimal(
        path,
        title="m94 fv 1.5",
        isa_investigation_id="TTIO:m94:fv5",
        runs={"run_0001": run},
    )
    with h5py.File(path, "r") as f:
        version = f.attrs["ttio_format_version"]
        if isinstance(version, bytes):
            version = version.decode("ascii")
        assert version == "1.5"


def test_default_v1_5_applies_fqzcomp_when_no_override_and_v1_5_candidate(tmp_path):
    """Q5a=B (gated on v1.5 candidacy): empty qualities override +
    signal_compression="gzip" + REF_DIFF active on sequences (the
    classic v1.5-stack case) → qualities gets FQZCOMP_NX16 (10)
    automatically.

    The v1.5-candidacy gate preserves byte-parity with M82-only writes
    that don't use any v1.5 codec — those stay on the legacy
    uncompressed-qualities path."""
    # Build a run whose sequences will go through REF_DIFF (reference
    # provided + signal_codec_overrides empty + signal_compression="gzip"
    # auto-applies REF_DIFF → run is a v1.5 candidate → qualities also
    # auto-applies FQZCOMP_NX16).
    n_reads = 5
    read_len = 10
    seq = b"ACGTACGTAC"[:read_len]
    sequences = np.frombuffer(seq * n_reads, dtype=np.uint8)
    qualities = np.full(len(sequences), 30 + 33, dtype=np.uint8)
    run = WrittenGenomicRun(
        acquisition_mode=int(AcquisitionMode.GENOMIC_WGS),
        reference_uri="m94-test-uri",
        platform="ILLUMINA",
        sample_name="m94",
        positions=np.array([1] * n_reads, dtype=np.int64),
        mapping_qualities=np.full(n_reads, 60, dtype=np.uint8),
        flags=np.zeros(n_reads, dtype=np.uint32),
        sequences=sequences,
        qualities=qualities,
        offsets=np.arange(n_reads, dtype=np.uint64) * read_len,
        lengths=np.full(n_reads, read_len, dtype=np.uint32),
        cigars=[f"{read_len}M"] * n_reads,
        read_names=[f"r{i}" for i in range(n_reads)],
        mate_chromosomes=["*"] * n_reads,
        mate_positions=np.full(n_reads, -1, dtype=np.int64),
        template_lengths=np.zeros(n_reads, dtype=np.int32),
        chromosomes=["22"] * n_reads,
        signal_codec_overrides={},  # auto-default kicks in for both channels
        signal_compression="gzip",
        embed_reference=True,
        reference_chrom_seqs={"22": b"ACGTACGTAC" * 100},
    )
    path = tmp_path / "fqz_default.tio"
    SpectralDataset.write_minimal(
        path,
        title="m94 default",
        isa_investigation_id="TTIO:m94:default",
        runs={"run_0001": run},
    )
    with h5py.File(path, "r") as f:
        quals_ds = f["/study/genomic_runs/run_0001/signal_channels/qualities"]
        codec_id = int(quals_ds.attrs.get("compression", 0))
        assert codec_id == int(Compression.FQZCOMP_NX16)
        # And sequences should be REF_DIFF:
        seqs_ds = f["/study/genomic_runs/run_0001/signal_channels/sequences"]
        assert int(seqs_ds.attrs["compression"]) == int(Compression.REF_DIFF)


def test_default_v1_5_skipped_when_pure_m82_baseline(tmp_path):
    """M82 byte-parity guard: when no run signals v1.5 (no reference,
    no explicit v1.5 override) the qualities default is SKIPPED — the
    channel goes through the legacy uncompressed/zlib path. This is
    what preserves byte-parity with existing M82/M86 fixtures."""
    run = _build_fqz_run(signal_codec_overrides={})
    path = tmp_path / "fqz_baseline.tio"
    SpectralDataset.write_minimal(
        path,
        title="m94 baseline",
        isa_investigation_id="TTIO:m94:baseline",
        runs={"run_0001": run},
    )
    with h5py.File(path, "r") as f:
        quals_ds = f["/study/genomic_runs/run_0001/signal_channels/qualities"]
        codec_id = int(quals_ds.attrs.get("compression", 0))
        # Either the attr is absent (legacy uncompressed) or it's NOT
        # FQZCOMP_NX16 — the baseline behaviour is preserved.
        assert codec_id != int(Compression.FQZCOMP_NX16)


def test_default_v1_5_skipped_when_signal_compression_is_none(tmp_path):
    """signal_compression="none" disables auto-default."""
    run = _build_fqz_run(
        signal_codec_overrides={},
        signal_compression="none",
    )
    path = tmp_path / "fqz_no_default.tio"
    SpectralDataset.write_minimal(
        path,
        title="m94 no default",
        isa_investigation_id="TTIO:m94:nodef",
        runs={"run_0001": run},
    )
    with h5py.File(path, "r") as f:
        quals_ds = f["/study/genomic_runs/run_0001/signal_channels/qualities"]
        codec_id = int(quals_ds.attrs.get("compression", 0))
        assert codec_id != int(Compression.FQZCOMP_NX16)


def test_explicit_override_uses_fqzcomp(tmp_path):
    """Explicit Compression.FQZCOMP_NX16 override is honoured."""
    run = _build_fqz_run(
        signal_codec_overrides={"qualities": Compression.FQZCOMP_NX16},
    )
    path = tmp_path / "fqz_explicit.tio"
    SpectralDataset.write_minimal(
        path,
        title="m94 explicit",
        isa_investigation_id="TTIO:m94:explicit",
        runs={"run_0001": run},
    )
    with h5py.File(path, "r") as f:
        quals_ds = f["/study/genomic_runs/run_0001/signal_channels/qualities"]
        assert int(quals_ds.attrs["compression"]) == int(Compression.FQZCOMP_NX16)


def test_reverse_flag_changes_encoded_bytes(tmp_path):
    """Setting flags = SAM_REVERSE_FLAG (16) on every read MUST yield
    different encoded bytes than flags = 0 — proves the revcomp bit
    feeds the FQZCOMP_NX16 context model.
    """
    run_fwd = _build_fqz_run(
        n_reads=10, read_len=50, quals_seed=0xCAFE,
        flags_value=0,
    )
    run_rev = _build_fqz_run(
        n_reads=10, read_len=50, quals_seed=0xCAFE,
        flags_value=16,
    )

    path_fwd = tmp_path / "fwd.tio"
    path_rev = tmp_path / "rev.tio"
    SpectralDataset.write_minimal(
        path_fwd, title="fwd", isa_investigation_id="TTIO:m94:fwd",
        runs={"r": run_fwd},
    )
    SpectralDataset.write_minimal(
        path_rev, title="rev", isa_investigation_id="TTIO:m94:rev",
        runs={"r": run_rev},
    )

    with h5py.File(path_fwd, "r") as f:
        fwd_bytes = bytes(f["/study/genomic_runs/r/signal_channels/qualities"][...].tobytes())
    with h5py.File(path_rev, "r") as f:
        rev_bytes = bytes(f["/study/genomic_runs/r/signal_channels/qualities"][...].tobytes())

    assert fwd_bytes != rev_bytes


def test_reverse_flag_round_trips_correctly(tmp_path):
    """Round-trip with all-reverse flags: decoded qualities must match
    the original qualities exactly."""
    run = _build_fqz_run(
        n_reads=8, read_len=25, quals_seed=0xDEAD,
        flags_value=16,
    )
    path = tmp_path / "rev_rt.tio"
    SpectralDataset.write_minimal(
        path, title="rev rt", isa_investigation_id="TTIO:m94:rev_rt",
        runs={"run_0001": run},
    )
    with SpectralDataset.open(path) as ds:
        out_run = ds.runs["run_0001"]
        for i in range(8):
            decoded = out_run[i].qualities
            expected = bytes(run.qualities[i * 25:(i + 1) * 25].tobytes())
            assert decoded == expected


def test_format_version_stays_1_4_when_no_v1_5_codec(tmp_path):
    """Byte-parity guard: M82-only writes (no v1.5 codec) MUST stay at
    @ttio_format_version = "1.4"."""
    run = _build_fqz_run(signal_codec_overrides={"qualities": Compression.RANS_ORDER0})
    path = tmp_path / "fv_1_4.tio"
    SpectralDataset.write_minimal(
        path, title="m82 fv 1.4",
        isa_investigation_id="TTIO:m94:fv4",
        runs={"run_0001": run},
    )
    with h5py.File(path, "r") as f:
        version = f.attrs["ttio_format_version"]
        if isinstance(version, bytes):
            version = version.decode("ascii")
        assert version == "1.4"
