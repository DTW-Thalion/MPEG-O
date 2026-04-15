"""Tests for :class:`SpectralDataset` against real ObjC reference fixtures
plus a Python-only round-trip using :meth:`SpectralDataset.write_minimal`.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from mpeg_o import (
    AcquisitionRun,
    Identification,
    MassSpectrum,
    NMRSpectrum,
    ProvenanceRecord,
    Quantification,
    SpectralDataset,
    WrittenRun,
)
from mpeg_o.enums import AcquisitionMode


def test_reads_minimal_ms_fixture(minimal_ms_fixture: Path) -> None:
    with SpectralDataset.open(minimal_ms_fixture) as ds:
        assert ds.feature_flags.version == "1.1"
        assert "base_v1" in ds.feature_flags.features
        assert ds.title == "minimal MS"
        assert ds.isa_investigation_id == "MPGO:minimal"
        assert list(ds.ms_runs.keys()) == ["run_0001"]
        run = ds.ms_runs["run_0001"]
        assert isinstance(run, AcquisitionRun)
        assert len(run) == 10
        assert run.spectrum_class == "MPGOMassSpectrum"
        assert run.acquisition_mode is AcquisitionMode.MS1_DDA
        assert run.channel_names == ("intensity", "mz")
        assert not ds.is_encrypted

        # lazy per-spectrum access
        s0 = run[0]
        assert isinstance(s0, MassSpectrum)
        assert s0.index == 0
        assert s0.run_name == "run_0001"
        assert len(s0.mz_array.data) == len(s0.intensity_array.data) > 0
        # mz values should be strictly positive for synthetic fixtures
        assert s0.mz_array.data[0] > 0


def test_reads_full_ms_fixture_with_compound_metadata(full_ms_fixture: Path) -> None:
    with SpectralDataset.open(full_ms_fixture) as ds:
        assert ds.title == "full MS with annotations"
        idents = ds.identifications()
        assert len(idents) == 10
        assert all(isinstance(i, Identification) for i in idents)
        assert idents[0].chemical_entity.startswith("CHEBI:")
        assert idents[0].evidence_chain  # non-empty list

        quants = ds.quantifications()
        assert len(quants) == 5
        assert all(isinstance(q, Quantification) for q in quants)

        prov = ds.provenance()
        assert len(prov) == 2
        assert all(isinstance(p, ProvenanceRecord) for p in prov)
        assert prov[0].software  # non-empty


def test_reads_nmr_1d_fixture(nmr_1d_fixture: Path) -> None:
    with SpectralDataset.open(nmr_1d_fixture) as ds:
        assert "nmr_run" in ds.ms_runs
        run = ds.ms_runs["nmr_run"]
        assert run.spectrum_class == "MPGONMRSpectrum"
        assert run.nucleus_type == "1H"
        assert run.acquisition_mode is AcquisitionMode.NMR_1D
        s = run[0]
        assert isinstance(s, NMRSpectrum)
        assert s.nucleus == "1H"
        assert len(s.chemical_shift_array.data) == len(s.intensity_array.data)


def test_detects_encrypted_fixture(encrypted_fixture: Path) -> None:
    with SpectralDataset.open(encrypted_fixture) as ds:
        assert ds.is_encrypted
        assert ds.encrypted_algorithm == "aes-256-gcm"


def _make_run(n_spectra: int, points_per: int) -> WrittenRun:
    offsets = np.arange(n_spectra, dtype=np.uint64) * points_per
    lengths = np.full(n_spectra, points_per, dtype=np.uint32)
    rts = np.linspace(0.0, 10.0, n_spectra, dtype=np.float64)
    ms_levels = np.ones(n_spectra, dtype=np.int32)
    polarities = np.ones(n_spectra, dtype=np.int32)  # positive
    prec_mzs = np.zeros(n_spectra, dtype=np.float64)
    prec_charges = np.zeros(n_spectra, dtype=np.int32)
    mz = np.tile(np.linspace(100.0, 200.0, points_per), n_spectra).astype(np.float64)
    intensity = np.tile(np.linspace(1.0, 1000.0, points_per), n_spectra).astype(np.float64)
    base_peaks = np.full(n_spectra, 1000.0, dtype=np.float64)
    return WrittenRun(
        spectrum_class="MPGOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": mz, "intensity": intensity},
        offsets=offsets,
        lengths=lengths,
        retention_times=rts,
        ms_levels=ms_levels,
        polarities=polarities,
        precursor_mzs=prec_mzs,
        precursor_charges=prec_charges,
        base_peak_intensities=base_peaks,
    )


def test_write_minimal_round_trip(tmp_path: Path) -> None:
    out = tmp_path / "py_written.mpgo"
    run = _make_run(n_spectra=5, points_per=8)
    idents = [
        Identification(run_name="run_0001", spectrum_index=0,
                       chemical_entity="CHEBI:15000", confidence_score=0.7,
                       evidence_chain=["MS:1002217"]),
    ]
    quants = [
        Quantification(chemical_entity="CHEBI:15000",
                       sample_ref="sample_A", abundance=12345.6,
                       normalization_method="tic"),
    ]
    prov = [
        ProvenanceRecord(timestamp_unix=1710000000, software="mpeg-o-py/0.3.0a1",
                         parameters={"run": "test"}, input_refs=[],
                         output_refs=["file:py_written.mpgo"]),
    ]
    SpectralDataset.write_minimal(
        out,
        title="python round trip",
        isa_investigation_id="MPGO:pyrt",
        runs={"run_0001": run},
        identifications=idents,
        quantifications=quants,
        provenance=prov,
    )
    assert out.is_file()

    with SpectralDataset.open(out) as ds:
        assert ds.title == "python round trip"
        assert ds.isa_investigation_id == "MPGO:pyrt"
        assert ds.feature_flags.version == "1.1"
        assert "run_0001" in ds.ms_runs
        r = ds.ms_runs["run_0001"]
        assert len(r) == 5
        s = r[2]
        assert isinstance(s, MassSpectrum)
        assert len(s.mz_array.data) == 8
        assert s.ms_level == 1

        got_idents = ds.identifications()
        assert len(got_idents) == 1
        assert got_idents[0].chemical_entity == "CHEBI:15000"
        assert got_idents[0].evidence_chain == ["MS:1002217"]

        got_quants = ds.quantifications()
        assert got_quants[0].abundance == pytest.approx(12345.6)

        got_prov = ds.provenance()
        assert got_prov[0].software == "mpeg-o-py/0.3.0a1"
        assert got_prov[0].parameters == {"run": "test"}
