"""Phase 1 abstraction tests:
  * Run Protocol — both AcquisitionRun and GenomicRun conform.
  * GenomicRun.provenance_chain() — closes the M91 read-side gap.
  * SpectralDataset.runs_for_sample / runs_of_modality — modality-
    agnostic accessors.

The goal is: code that "iterates all runs from sample X" or "treats
any run as an indexed collection of measurements" should not need
to know the modality. Cross-modality logic in M91 had to fork on
ms_runs vs genomic_runs with different access patterns; Phase 1
collapses that to a single iteration.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

pytest.importorskip("h5py")

from ttio import SpectralDataset
from ttio.acquisition_run import AcquisitionRun
from ttio.enums import AcquisitionMode, Polarity
from ttio.genomic_run import GenomicRun
from ttio.protocols.run import Run
from ttio.provenance import ProvenanceRecord
from ttio.spectral_dataset import WrittenRun
from ttio.written_genomic_run import WrittenGenomicRun


SAMPLE_URI = "sample://NA12878"


def _make_mixed_dataset(path: Path) -> Path:
    n_ms = 3
    n_pts = 4
    mz = np.tile(np.linspace(100, 200, n_pts), n_ms).astype(np.float64)
    intensity = (np.arange(n_ms * n_pts, dtype=np.float64) + 1) * 1000.0
    ms_run = WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": mz, "intensity": intensity},
        offsets=np.arange(n_ms, dtype=np.uint64) * n_pts,
        lengths=np.full(n_ms, n_pts, dtype=np.uint32),
        retention_times=np.linspace(0.0, 4.0, n_ms),
        ms_levels=np.ones(n_ms, dtype=np.int32),
        polarities=np.full(n_ms, int(Polarity.POSITIVE), dtype=np.int32),
        precursor_mzs=np.zeros(n_ms),
        precursor_charges=np.zeros(n_ms, dtype=np.int32),
        base_peak_intensities=intensity.reshape(n_ms, n_pts).max(axis=1),
        provenance_records=[
            ProvenanceRecord(
                timestamp_unix=0, software="ms-pipeline",
                input_refs=[SAMPLE_URI],
                output_refs=["ms://run_0001"],
            ),
        ],
    )
    n_g = 4
    L = 8
    g_run = WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="NA12878",
        positions=np.array([100, 200, 300, 400], dtype=np.int64),
        mapping_qualities=np.full(n_g, 60, dtype=np.uint8),
        flags=np.full(n_g, 0x0003, dtype=np.uint32),
        sequences=np.frombuffer(b"ACGTACGT" * n_g, dtype=np.uint8),
        qualities=np.frombuffer(bytes([30] * (n_g * L)), dtype=np.uint8),
        offsets=np.arange(n_g, dtype=np.uint64) * L,
        lengths=np.full(n_g, L, dtype=np.uint32),
        cigars=[f"{L}M"] * n_g,
        read_names=[f"r{i}" for i in range(n_g)],
        mate_chromosomes=[""] * n_g,
        mate_positions=np.full(n_g, -1, dtype=np.int64),
        template_lengths=np.zeros(n_g, dtype=np.int32),
        chromosomes=["chr1", "chr1", "chr2", "chr2"],
        provenance_records=[
            ProvenanceRecord(
                timestamp_unix=0, software="genomics-pipeline",
                input_refs=[SAMPLE_URI],
                output_refs=["genomics://wgs_0001"],
            ),
        ],
    )
    SpectralDataset.write_minimal(
        path,
        title="phase1 fixture",
        isa_investigation_id="ISA-PHASE1",
        runs={"ms_0001": ms_run},
        genomic_runs={"genomic_0001": g_run},
    )
    return path


class TestRunProtocolConformance:
    """Both run types must satisfy the Run Protocol — no inheritance
    required; Protocol uses structural typing."""

    def test_acquisition_run_conforms(self, tmp_path):
        path = _make_mixed_dataset(tmp_path / "f.tio")
        with SpectralDataset.open(path) as ds:
            run = ds.ms_runs["ms_0001"]
            assert isinstance(run, Run), (
                "AcquisitionRun must satisfy the Run protocol "
                "(structural conformance via @runtime_checkable)"
            )

    def test_genomic_run_conforms(self, tmp_path):
        path = _make_mixed_dataset(tmp_path / "f.tio")
        with SpectralDataset.open(path) as ds:
            run = ds.genomic_runs["genomic_0001"]
            assert isinstance(run, Run)

    def test_protocol_methods_callable_uniformly(self, tmp_path):
        """Code that takes a Run and uses the protocol surface should
        work regardless of underlying modality."""
        path = _make_mixed_dataset(tmp_path / "f.tio")
        with SpectralDataset.open(path) as ds:
            for run in [
                ds.ms_runs["ms_0001"],
                ds.genomic_runs["genomic_0001"],
            ]:
                assert isinstance(run, Run)
                assert isinstance(run.name, str)
                assert isinstance(run.acquisition_mode, AcquisitionMode)
                assert len(run) > 0
                # Iteration yields measurement records (Spectrum or
                # AlignedRead). The protocol promises only that
                # __getitem__(i) works.
                first = run[0]
                assert first is not None
                # Provenance chain present and queryable.
                provs = run.provenance_chain()
                assert isinstance(provs, list)


class TestGenomicProvenanceChain:
    """M91's cross-modality query had to use sample_name attr for
    genomic because GenomicRun didn't expose provenance_chain().
    Phase 1 closes that gap."""

    def test_genomic_run_has_provenance_chain(self, tmp_path):
        path = _make_mixed_dataset(tmp_path / "f.tio")
        with SpectralDataset.open(path) as ds:
            gr = ds.genomic_runs["genomic_0001"]
            chain = gr.provenance_chain()
            assert len(chain) == 1
            assert SAMPLE_URI in chain[0].input_refs
            assert chain[0].software == "genomics-pipeline"

    def test_empty_genomic_provenance_returns_empty(self, tmp_path):
        # Build a genomic-only fixture WITHOUT provenance.
        path = tmp_path / "noprov.tio"
        n = 2
        L = 4
        run = WrittenGenomicRun(
            acquisition_mode=7,
            reference_uri="x", platform="x", sample_name="x",
            positions=np.array([1, 2], dtype=np.int64),
            mapping_qualities=np.full(n, 60, dtype=np.uint8),
            flags=np.full(n, 0x0003, dtype=np.uint32),
            sequences=np.frombuffer(b"ACGT" * n, dtype=np.uint8),
            qualities=np.frombuffer(bytes([30] * (n * L)), dtype=np.uint8),
            offsets=np.arange(n, dtype=np.uint64) * L,
            lengths=np.full(n, L, dtype=np.uint32),
            cigars=[f"{L}M"] * n,
            read_names=[f"r{i}" for i in range(n)],
            mate_chromosomes=[""] * n,
            mate_positions=np.full(n, -1, dtype=np.int64),
            template_lengths=np.zeros(n, dtype=np.int32),
            chromosomes=["chr1"] * n,
            # No provenance_records — should round-trip as empty list.
        )
        SpectralDataset.write_minimal(
            path, title="x", isa_investigation_id="x",
            runs={}, genomic_runs={"genomic_0001": run},
        )
        with SpectralDataset.open(path) as ds:
            gr = ds.genomic_runs["genomic_0001"]
            assert gr.provenance_chain() == []


class TestCrossModalityHelpers:
    """SpectralDataset gains modality-agnostic accessors."""

    def test_runs_for_sample_finds_all(self, tmp_path):
        path = _make_mixed_dataset(tmp_path / "f.tio")
        with SpectralDataset.open(path) as ds:
            matching = ds.runs_for_sample(SAMPLE_URI)
            assert "ms_0001" in matching
            assert "genomic_0001" in matching
            # Returned values conform to the Run protocol.
            for name, run in matching.items():
                assert isinstance(run, Run)

    def test_runs_for_sample_unknown_returns_empty(self, tmp_path):
        path = _make_mixed_dataset(tmp_path / "f.tio")
        with SpectralDataset.open(path) as ds:
            assert ds.runs_for_sample("sample://UNKNOWN") == {}

    def test_runs_of_modality_filters_by_class(self, tmp_path):
        path = _make_mixed_dataset(tmp_path / "f.tio")
        with SpectralDataset.open(path) as ds:
            ms_only = ds.runs_of_modality(AcquisitionRun)
            g_only = ds.runs_of_modality(GenomicRun)
            assert set(ms_only.keys()) == {"ms_0001"}
            assert set(g_only.keys()) == {"genomic_0001"}

    def test_runs_of_modality_returns_run_protocol_values(self, tmp_path):
        path = _make_mixed_dataset(tmp_path / "f.tio")
        with SpectralDataset.open(path) as ds:
            for run in ds.runs_of_modality(AcquisitionRun).values():
                assert isinstance(run, Run)
            for run in ds.runs_of_modality(GenomicRun).values():
                assert isinstance(run, Run)
