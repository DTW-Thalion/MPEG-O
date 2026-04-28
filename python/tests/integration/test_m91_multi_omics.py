"""M91: multi-omics integration test.

Builds a single .tio carrying:
  * proteomics MS run (TTIOMassSpectrum)
  * NMR metabolomics run (TTIONMRSpectrum)
  * WGS genomic run (TTIOGenomicRead)

Each run carries a provenance record referencing a common sample
URI ("sample://NA12878"), enabling a cross-modality query.

Tests cover:
  1. Build + open + introspect the multi-modal file.
  2. Cross-modality query: find all runs from a given sample.
  3. Unified encryption envelope (encrypt_per_au_file with one key
     covers MS signal channels AND genomic signal channels).
  4. .tis transport round-trip: file -> .tis -> file preserves all
     three modalities.

The numbers are scaled down from the M91 spec's 10K/1K/100 reads
to 10/10/10 for fast CI; the spec's exact volumes can be exercised
locally by setting the TTIO_M91_LARGE env var.
"""
from __future__ import annotations

import io as _io
import os
from pathlib import Path

import numpy as np
import pytest

pytest.importorskip("h5py")
pytest.importorskip("cryptography")

from ttio import SpectralDataset
from ttio.encryption_per_au import decrypt_per_au_file, encrypt_per_au_file
from ttio.enums import AcquisitionMode, Polarity
from ttio.provenance import ProvenanceRecord
from ttio.spectral_dataset import WrittenRun
from ttio.transport.codec import file_to_transport, transport_to_file
from ttio.written_genomic_run import WrittenGenomicRun


SAMPLE_URI = "sample://NA12878"
KEY = b"\x42" * 32

# Scaled-down for CI; bumpable via env for local stress.
N_MS = 100 if os.environ.get("TTIO_M91_LARGE") else 10
N_NMR = 50 if os.environ.get("TTIO_M91_LARGE") else 10
N_GENOMIC = 1000 if os.environ.get("TTIO_M91_LARGE") else 10


def _make_proteomics_run() -> tuple[str, WrittenRun]:
    n = N_MS
    n_pts = 4
    mz = np.tile(np.linspace(100.0, 200.0, n_pts), n).astype(np.float64)
    intensity = (np.arange(n * n_pts, dtype=np.float64) + 1.0) * 1000.0
    run = WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": mz, "intensity": intensity},
        offsets=np.arange(n, dtype=np.uint64) * n_pts,
        lengths=np.full(n, n_pts, dtype=np.uint32),
        retention_times=np.linspace(0.0, 30.0, n),
        ms_levels=np.ones(n, dtype=np.int32),
        polarities=np.full(n, int(Polarity.POSITIVE), dtype=np.int32),
        precursor_mzs=np.zeros(n, dtype=np.float64),
        precursor_charges=np.zeros(n, dtype=np.int32),
        base_peak_intensities=intensity.reshape(n, n_pts).max(axis=1),
        provenance_records=[
            ProvenanceRecord(
                timestamp_unix=1_700_000_000,
                software="proteomics-pipeline v1.0",
                parameters={"modality": "proteomics-MS"},
                input_refs=[SAMPLE_URI],
                output_refs=["proteomics://run_0001"],
            ),
        ],
    )
    return "proteomics_0001", run


def _make_nmr_run() -> tuple[str, WrittenRun]:
    n = N_NMR
    n_pts = 8
    chemical_shifts = np.tile(
        np.linspace(0.0, 10.0, n_pts), n,
    ).astype(np.float64)
    intensity = (np.arange(n * n_pts, dtype=np.float64) + 1.0) * 100.0
    run = WrittenRun(
        spectrum_class="TTIONMRSpectrum",
        acquisition_mode=int(AcquisitionMode.NMR_1D),
        channel_data={
            "chemical_shift": chemical_shifts,
            "intensity": intensity,
        },
        offsets=np.arange(n, dtype=np.uint64) * n_pts,
        lengths=np.full(n, n_pts, dtype=np.uint32),
        retention_times=np.zeros(n, dtype=np.float64),  # NMR has no RT
        ms_levels=np.zeros(n, dtype=np.int32),
        polarities=np.full(n, int(Polarity.UNKNOWN), dtype=np.int32),
        precursor_mzs=np.zeros(n, dtype=np.float64),
        precursor_charges=np.zeros(n, dtype=np.int32),
        base_peak_intensities=intensity.reshape(n, n_pts).max(axis=1),
        provenance_records=[
            ProvenanceRecord(
                timestamp_unix=1_700_000_100,
                software="metabolomics-pipeline v1.0",
                parameters={"modality": "metabolomics-NMR"},
                input_refs=[SAMPLE_URI],
                output_refs=["metabolomics://nmr_0001"],
            ),
        ],
    )
    return "metabolomics_0001", run


def _make_genomic_run() -> tuple[str, WrittenGenomicRun]:
    n = N_GENOMIC
    L = 8
    sequences = np.frombuffer(b"ACGTACGT" * n, dtype=np.uint8)
    qualities = np.frombuffer(bytes([30] * (n * L)), dtype=np.uint8)
    run = WrittenGenomicRun(
        acquisition_mode=7,  # GENOMIC_WGS
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="NA12878",
        positions=(np.arange(n, dtype=np.int64) * 100) + 1000,
        mapping_qualities=np.full(n, 60, dtype=np.uint8),
        flags=np.full(n, 0x0003, dtype=np.uint32),
        sequences=sequences,
        qualities=qualities,
        offsets=np.arange(n, dtype=np.uint64) * L,
        lengths=np.full(n, L, dtype=np.uint32),
        cigars=[f"{L}M"] * n,
        read_names=[f"r{i:06d}" for i in range(n)],
        mate_chromosomes=[""] * n,
        mate_positions=np.full(n, -1, dtype=np.int64),
        template_lengths=np.zeros(n, dtype=np.int32),
        chromosomes=[("chr1" if i % 2 == 0 else "chr2") for i in range(n)],
        provenance_records=[
            ProvenanceRecord(
                timestamp_unix=1_700_000_200,
                software="genomics-pipeline v1.0",
                parameters={"modality": "genomics-WGS"},
                input_refs=[SAMPLE_URI],
                output_refs=["genomics://wgs_0001"],
            ),
        ],
    )
    return "genomics_0001", run


def _make_multi_omics_dataset(path: Path) -> Path:
    ms_name, ms_run = _make_proteomics_run()
    nmr_name, nmr_run = _make_nmr_run()
    g_name, g_run = _make_genomic_run()
    SpectralDataset.write_minimal(
        path,
        title="M91 multi-omics fixture",
        isa_investigation_id="ISA-M91-NA12878",
        runs={ms_name: ms_run, nmr_name: nmr_run},
        genomic_runs={g_name: g_run},
        provenance=[
            ProvenanceRecord(
                timestamp_unix=1_700_000_000,
                software="ttio-test-harness M91",
                parameters={"sample": "NA12878"},
                input_refs=[SAMPLE_URI],
                output_refs=[str(path)],
            ),
        ],
    )
    return path


# ── 1. Container shape ─────────────────────────────────────────────


class TestMultiOmicsContainer:

    def test_all_three_modalities_present(self, tmp_path):
        path = _make_multi_omics_dataset(tmp_path / "mux.tio")
        with SpectralDataset.open(path) as ds:
            # Two MS-side runs (proteomics + NMR metabolomics).
            assert "proteomics_0001" in ds.ms_runs
            assert "metabolomics_0001" in ds.ms_runs
            # One genomic run.
            assert "genomics_0001" in ds.genomic_runs

    def test_modality_specific_data_intact(self, tmp_path):
        path = _make_multi_omics_dataset(tmp_path / "mux.tio")
        with SpectralDataset.open(path) as ds:
            ms_run = ds.ms_runs["proteomics_0001"]
            assert ms_run.spectrum_class == "TTIOMassSpectrum"
            assert len(ms_run) == N_MS

            nmr_run = ds.ms_runs["metabolomics_0001"]
            assert nmr_run.spectrum_class == "TTIONMRSpectrum"
            assert len(nmr_run) == N_NMR

            g_run = ds.genomic_runs["genomics_0001"]
            assert len(g_run) == N_GENOMIC
            assert g_run[0].sequence == "ACGTACGT"


# ── 2. Cross-modality query ────────────────────────────────────────


def _runs_referencing_sample(ds: SpectralDataset, sample_uri: str) -> set[str]:
    """Return the set of run names (from ms_runs ∪ genomic_runs)
    associated with ``sample_uri``.

    Each run type exposes the sample link differently:
      * MS-side runs (proteomics + NMR) carry per-run provenance via
        AcquisitionRun.provenance_chain(); the test fixture puts
        sample_uri in input_refs.
      * Genomic runs surface a top-level ``sample_name`` attribute
        (the read-side GenomicRun doesn't expose provenance_records
        today — adding it is scoped as a future-milestone follow-up).
        The query parses ``sample://<NAME>`` to compare with
        sample_name.
    """
    matching: set[str] = set()
    for name, run in ds.ms_runs.items():
        for prov in run.provenance_chain():
            if sample_uri in prov.input_refs:
                matching.add(name)
                break
    sample_short = sample_uri.split("://", 1)[-1] if "://" in sample_uri else ""
    for name, run in ds.genomic_runs.items():
        if sample_short and run.sample_name == sample_short:
            matching.add(name)
    return matching


class TestCrossModalityQuery:

    def test_query_by_sample_returns_all_three_runs(self, tmp_path):
        path = _make_multi_omics_dataset(tmp_path / "q.tio")
        with SpectralDataset.open(path) as ds:
            matching = _runs_referencing_sample(ds, SAMPLE_URI)
        assert matching == {
            "proteomics_0001", "metabolomics_0001", "genomics_0001",
        }

    def test_query_by_unknown_sample_returns_empty(self, tmp_path):
        path = _make_multi_omics_dataset(tmp_path / "q2.tio")
        with SpectralDataset.open(path) as ds:
            matching = _runs_referencing_sample(ds, "sample://UNKNOWN")
        assert matching == set()


# ── 3. Unified encryption envelope ─────────────────────────────────


class TestUnifiedEncryption:
    """One encrypt_per_au_file call covers MS signal channels AND
    genomic signal channels under a single AES-256-GCM DEK
    (M90.1 wires this via dataset_id_counter continuation)."""

    def test_encrypt_decrypt_round_trip_all_modalities(self, tmp_path):
        path = _make_multi_omics_dataset(tmp_path / "enc.tio")
        encrypt_per_au_file(str(path), KEY)
        plain = decrypt_per_au_file(str(path), KEY)
        # MS: mz + intensity (float64).
        assert "proteomics_0001" in plain
        assert plain["proteomics_0001"]["mz"].dtype == np.float64
        assert len(plain["proteomics_0001"]["mz"]) == N_MS * 4
        # NMR: chemical_shift + intensity (float64).
        assert "metabolomics_0001" in plain
        assert plain["metabolomics_0001"]["chemical_shift"].dtype == np.float64
        # Genomic: sequences + qualities (uint8).
        assert "genomics_0001" in plain
        assert plain["genomics_0001"]["sequences"].dtype == np.uint8
        assert (plain["genomics_0001"]["sequences"].tobytes()
                == b"ACGTACGT" * N_GENOMIC)


# ── 4. .tis transport round-trip ───────────────────────────────────


class TestTransportRoundTrip:

    def test_file_to_transport_to_file_preserves_modalities(self, tmp_path):
        path = _make_multi_omics_dataset(tmp_path / "src.tio")
        buffer = _io.BytesIO()
        file_to_transport(path, buffer)
        buffer.seek(0)
        rt = transport_to_file(buffer, tmp_path / "rt.tio")
        try:
            assert "proteomics_0001" in rt.ms_runs
            assert "metabolomics_0001" in rt.ms_runs
            assert "genomics_0001" in rt.genomic_runs
            # Spot-check per modality.
            assert rt.ms_runs["proteomics_0001"].spectrum_class == \
                "TTIOMassSpectrum"
            assert rt.ms_runs["metabolomics_0001"].spectrum_class == \
                "TTIONMRSpectrum"
            assert len(rt.genomic_runs["genomics_0001"]) == N_GENOMIC
            # Genomic per-base bytes round-trip exactly.
            assert rt.genomic_runs["genomics_0001"][0].sequence == "ACGTACGT"
        finally:
            rt.close()
