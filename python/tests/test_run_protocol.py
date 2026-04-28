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


class TestPhase2CanonicalRuns:
    """Phase 2: dataset.runs is the canonical access pattern."""

    def test_runs_property_returns_unified_mapping(self, tmp_path):
        path = _make_mixed_dataset(tmp_path / "f.tio")
        with SpectralDataset.open(path) as ds:
            unified = ds.runs
            assert "ms_0001" in unified
            assert "genomic_0001" in unified
            for name, run in unified.items():
                assert isinstance(run, Run)

    def test_all_runs_unified_alias_still_works(self, tmp_path):
        """Phase 1 added all_runs_unified; Phase 2 promotes it to
        runs and keeps the alias for the brief transition window."""
        path = _make_mixed_dataset(tmp_path / "f.tio")
        with SpectralDataset.open(path) as ds:
            assert dict(ds.all_runs_unified) == dict(ds.runs)


class TestPhase2WriteMinimalMixed:
    """Phase 2: write_minimal accepts a mixed dict of WrittenRun +
    WrittenGenomicRun in the ``runs`` kwarg, dispatching by
    isinstance() to the right write path."""

    def test_mixed_runs_dict_produces_correct_layout(self, tmp_path):
        # Build a fresh fixture using the new canonical write API.
        n_ms = 2
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
        )
        n_g = 2
        L = 4
        g_run = WrittenGenomicRun(
            acquisition_mode=7,
            reference_uri="GRCh38.p14",
            platform="ILLUMINA",
            sample_name="NA12878",
            positions=np.array([100, 200], dtype=np.int64),
            mapping_qualities=np.full(n_g, 60, dtype=np.uint8),
            flags=np.full(n_g, 0x0003, dtype=np.uint32),
            sequences=np.frombuffer(b"ACGT" * n_g, dtype=np.uint8),
            qualities=np.frombuffer(bytes([30] * (n_g * L)), dtype=np.uint8),
            offsets=np.arange(n_g, dtype=np.uint64) * L,
            lengths=np.full(n_g, L, dtype=np.uint32),
            cigars=[f"{L}M"] * n_g,
            read_names=[f"r{i}" for i in range(n_g)],
            mate_chromosomes=[""] * n_g,
            mate_positions=np.full(n_g, -1, dtype=np.int64),
            template_lengths=np.zeros(n_g, dtype=np.int32),
            chromosomes=["chr1"] * n_g,
        )
        path = tmp_path / "mixed.tio"
        SpectralDataset.write_minimal(
            path,
            title="Phase2 mixed write",
            isa_investigation_id="ISA-PHASE2",
            runs={
                "ms_0001": ms_run,        # WrittenRun
                "genomic_0001": g_run,    # WrittenGenomicRun (mixed!)
            },
            # No genomic_runs= kwarg — split happens internally.
        )
        with SpectralDataset.open(path) as ds:
            assert "ms_0001" in ds.ms_runs
            assert "genomic_0001" in ds.genomic_runs
            assert "ms_0001" in ds.runs
            assert "genomic_0001" in ds.runs

    def test_legacy_two_kwarg_form_still_works(self, tmp_path):
        """Backward compat: callers using pre-Phase-2 separate
        kwargs continue to work unchanged."""
        path = _make_mixed_dataset(tmp_path / "f.tio")
        with SpectralDataset.open(path) as ds:
            assert "ms_0001" in ds.ms_runs
            assert "genomic_0001" in ds.genomic_runs

    def test_name_collision_between_kwargs_raises(self, tmp_path):
        # If the caller mixes runs + genomic_runs and the SAME name
        # appears in both, raise rather than silently picking one.
        n_g = 1
        L = 4
        g_run = WrittenGenomicRun(
            acquisition_mode=7, reference_uri="x", platform="x",
            sample_name="x",
            positions=np.array([1], dtype=np.int64),
            mapping_qualities=np.array([60], dtype=np.uint8),
            flags=np.array([0x0003], dtype=np.uint32),
            sequences=np.frombuffer(b"ACGT", dtype=np.uint8),
            qualities=np.frombuffer(bytes([30] * L), dtype=np.uint8),
            offsets=np.array([0], dtype=np.uint64),
            lengths=np.array([L], dtype=np.uint32),
            cigars=[f"{L}M"],
            read_names=["r0"],
            mate_chromosomes=[""],
            mate_positions=np.array([-1], dtype=np.int64),
            template_lengths=np.array([0], dtype=np.int32),
            chromosomes=["chr1"],
        )
        with pytest.raises(ValueError, match="appears in both"):
            SpectralDataset.write_minimal(
                tmp_path / "collision.tio",
                title="x", isa_investigation_id="x",
                runs={"x": g_run},
                genomic_runs={"x": g_run},
            )
