"""M90.2: signatures over genomic datasets.

Validates that the existing dataset-level signature primitives
(sign_dataset / verify_dataset) work uniformly on genomic
sequences/qualities datasets, both via the h5py path and via the
provider-routed StorageDataset path.

Adds a higher-level helper sign_genomic_run / verify_genomic_run
that signs every signal channel + the genomic_index columns in one
call, mirroring how ms_run signing is normally done loop-by-channel
in caller code.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

pytest.importorskip("cryptography")
pytest.importorskip("h5py")

import h5py

from ttio import SpectralDataset
from ttio.signatures import (
    sign_dataset, verify_dataset,
    sign_genomic_run, verify_genomic_run,
)
from ttio.written_genomic_run import WrittenGenomicRun


KEY = b"\x42" * 32  # HMAC-SHA256 key


def _make_genomic_dataset(path: Path) -> Path:
    n = 4
    L = 8
    run = WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="NA12878",
        positions=np.array([100, 200, 300, 400], dtype=np.int64),
        mapping_qualities=np.full(n, 60, dtype=np.uint8),
        flags=np.full(n, 0x0003, dtype=np.uint32),
        sequences=np.frombuffer(b"ACGTACGT" * n, dtype=np.uint8),
        qualities=np.frombuffer(bytes([30] * (n * L)), dtype=np.uint8),
        offsets=np.arange(n, dtype=np.uint64) * L,
        lengths=np.full(n, L, dtype=np.uint32),
        cigars=[f"{L}M"] * n,
        read_names=[f"r{i:03d}" for i in range(n)],
        mate_chromosomes=[""] * n,
        mate_positions=np.full(n, -1, dtype=np.int64),
        template_lengths=np.zeros(n, dtype=np.int32),
        chromosomes=["chr1", "chr1", "chr2", "chr2"],
    )
    SpectralDataset.write_minimal(
        path,
        title="M90.2 sig fixture",
        isa_investigation_id="ISA-M90-2",
        runs={},
        genomic_runs={"genomic_0001": run},
    )
    return path


class TestPerDatasetSign:
    """Existing sign_dataset / verify_dataset MUST work on genomic
    uint8 sequences/qualities datasets without modification — they
    delegate to read_canonical_bytes, which is dtype-agnostic."""

    def test_hmac_sequences_round_trip(self, tmp_path):
        path = _make_genomic_dataset(tmp_path / "src.tio")
        with h5py.File(path, "r+") as f:
            ds = f["/study/genomic_runs/genomic_0001/signal_channels/sequences"]
            sig = sign_dataset(ds, KEY)
            assert sig.startswith("v2:")
            assert verify_dataset(ds, KEY) is True

    def test_hmac_qualities_round_trip(self, tmp_path):
        path = _make_genomic_dataset(tmp_path / "q.tio")
        with h5py.File(path, "r+") as f:
            ds = f["/study/genomic_runs/genomic_0001/signal_channels/qualities"]
            sign_dataset(ds, KEY)
            assert verify_dataset(ds, KEY) is True

    def test_wrong_key_rejected(self, tmp_path):
        path = _make_genomic_dataset(tmp_path / "wk.tio")
        with h5py.File(path, "r+") as f:
            ds = f["/study/genomic_runs/genomic_0001/signal_channels/sequences"]
            sign_dataset(ds, KEY)
            assert verify_dataset(ds, b"\x00" * 32) is False


class TestRunLevelSignAndVerify:
    """M90.2 helper: sign_genomic_run signs every signal channel and
    every genomic_index column in one call. verify_genomic_run
    confirms all of them survived."""

    def test_round_trip_signs_all_channels(self, tmp_path):
        path = _make_genomic_dataset(tmp_path / "rt.tio")
        with h5py.File(path, "r+") as f:
            run_group = f["/study/genomic_runs/genomic_0001"]
            sigs = sign_genomic_run(run_group, KEY)
        # Every signed dataset gets a key->sig entry.
        # Expected: sequences, qualities + 5 index columns
        # (offsets, lengths, positions, mapping_qualities, flags).
        assert "signal_channels/sequences" in sigs
        assert "signal_channels/qualities" in sigs
        assert "genomic_index/positions" in sigs
        assert "genomic_index/mapping_qualities" in sigs
        assert "genomic_index/flags" in sigs
        assert "genomic_index/offsets" in sigs
        assert "genomic_index/lengths" in sigs

    def test_verify_returns_true_on_clean_run(self, tmp_path):
        path = _make_genomic_dataset(tmp_path / "v.tio")
        with h5py.File(path, "r+") as f:
            run_group = f["/study/genomic_runs/genomic_0001"]
            sign_genomic_run(run_group, KEY)
            assert verify_genomic_run(run_group, KEY) is True

    def test_verify_detects_tampered_channel(self, tmp_path):
        path = _make_genomic_dataset(tmp_path / "t.tio")
        with h5py.File(path, "r+") as f:
            run_group = f["/study/genomic_runs/genomic_0001"]
            sign_genomic_run(run_group, KEY)
            # Tamper with sequences: flip one byte.
            seqs = run_group["signal_channels/sequences"]
            current = seqs[()].copy()
            current[0] ^= 0x01
            seqs[...] = current
            assert verify_genomic_run(run_group, KEY) is False


class TestPqcSignatures:
    """ML-DSA-87 path on genomic datasets — uses liboqs or BC."""

    def test_ml_dsa_87_round_trip(self, tmp_path):
        # Skip if PQC is not available in this venv.
        try:
            from ttio import pqc
            kp = pqc.sig_keygen()
            priv = kp.private_key
            pub = kp.public_key
        except Exception as exc:
            pytest.skip(f"PQC not available: {exc}")

        path = _make_genomic_dataset(tmp_path / "pqc.tio")
        with h5py.File(path, "r+") as f:
            ds = f["/study/genomic_runs/genomic_0001/signal_channels/sequences"]
            sig = sign_dataset(ds, priv, algorithm="ml-dsa-87")
            assert sig.startswith("v3:")
            assert verify_dataset(ds, pub, algorithm="ml-dsa-87") is True
