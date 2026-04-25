"""Tests for :class:`SpectralDataset` against real ObjC reference fixtures
plus a Python-only round-trip using :meth:`SpectralDataset.write_minimal`.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ttio import (
    AcquisitionRun,
    ActivationMethod,
    Identification,
    IsolationWindow,
    MassSpectrum,
    NMRSpectrum,
    ProvenanceRecord,
    Quantification,
    SpectralDataset,
    WrittenRun,
)
from ttio.enums import AcquisitionMode


def test_reads_minimal_ms_fixture(minimal_ms_fixture: Path) -> None:
    with SpectralDataset.open(minimal_ms_fixture) as ds:
        assert ds.feature_flags.version == "1.1"
        assert "base_v1" in ds.feature_flags.features
        assert ds.title == "minimal MS"
        assert ds.isa_investigation_id == "TTIO:minimal"
        assert list(ds.ms_runs.keys()) == ["run_0001"]
        run = ds.ms_runs["run_0001"]
        assert isinstance(run, AcquisitionRun)
        assert len(run) == 10
        assert run.spectrum_class == "TTIOMassSpectrum"
        assert run.acquisition_mode is AcquisitionMode.MS1_DDA
        assert run.channel_names == ("intensity", "mz")
        assert not ds.is_encrypted

        # lazy per-spectrum access
        s0 = run[0]
        assert isinstance(s0, MassSpectrum)
        assert s0.index_position == 0
        assert run.name == "run_0001"
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
        assert run.spectrum_class == "TTIONMRSpectrum"
        assert run.nucleus_type == "1H"
        assert run.acquisition_mode is AcquisitionMode.NMR_1D
        s = run[0]
        assert isinstance(s, NMRSpectrum)
        assert s.nucleus_type == "1H"
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
        spectrum_class="TTIOMassSpectrum",
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
    out = tmp_path / "py_written.tio"
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
        ProvenanceRecord(timestamp_unix=1710000000, software="ttio-py/0.3.0a1",
                         parameters={"run": "test"}, input_refs=[],
                         output_refs=["file:py_written.tio"]),
    ]
    SpectralDataset.write_minimal(
        out,
        title="python round trip",
        isa_investigation_id="TTIO:pyrt",
        runs={"run_0001": run},
        identifications=idents,
        quantifications=quants,
        provenance=prov,
    )
    assert out.is_file()

    with SpectralDataset.open(out) as ds:
        assert ds.title == "python round trip"
        assert ds.isa_investigation_id == "TTIO:pyrt"
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
        assert got_prov[0].software == "ttio-py/0.3.0a1"
        assert got_prov[0].parameters == {"run": "test"}


# --------------------------------------------------------------- M74 (Slice B)

def test_spectrum_index_round_trip_without_m74_columns(tmp_path: Path) -> None:
    """Legacy path: WrittenRun leaves the four M74 fields None, so the
    writer omits the columns and the reader sees ``None`` on the
    SpectrumIndex M74 fields."""
    out = tmp_path / "no_m74.tio"
    SpectralDataset.write_minimal(
        out, title="no m74", isa_investigation_id="TTIO:no_m74",
        runs={"run_0001": _make_run(n_spectra=3, points_per=4)},
    )
    with SpectralDataset.open(out) as ds:
        run = ds.ms_runs["run_0001"]
        idx = run.index
        assert idx.activation_methods is None
        assert idx.isolation_target_mzs is None
        assert idx.isolation_lower_offsets is None
        assert idx.isolation_upper_offsets is None
        assert idx.activation_method_at(0) is ActivationMethod.NONE
        assert idx.isolation_window_at(0) is None


def test_spectrum_index_round_trip_with_m74_columns(tmp_path: Path) -> None:
    """M74 path: WrittenRun supplies all four parallel arrays, writer
    emits the columns, and the reader reconstructs per-spectrum
    activation methods and isolation windows."""
    out = tmp_path / "with_m74.tio"
    run = _make_run(n_spectra=3, points_per=4)
    # Spectrum 0 is MS1 (NONE sentinel); 1 and 2 are MS2 with HCD + CID.
    run.activation_methods = np.array(
        [int(ActivationMethod.NONE),
         int(ActivationMethod.HCD),
         int(ActivationMethod.CID)], dtype=np.int32)
    run.isolation_target_mzs = np.array([0.0, 500.0, 750.5], dtype=np.float64)
    run.isolation_lower_offsets = np.array([0.0, 1.0, 0.5], dtype=np.float64)
    run.isolation_upper_offsets = np.array([0.0, 2.0, 0.75], dtype=np.float64)

    SpectralDataset.write_minimal(
        out, title="with m74", isa_investigation_id="TTIO:m74",
        runs={"run_0001": run},
    )
    with SpectralDataset.open(out) as ds:
        r = ds.ms_runs["run_0001"]
        idx = r.index
        assert idx.activation_methods is not None
        assert idx.isolation_target_mzs is not None
        assert idx.isolation_lower_offsets is not None
        assert idx.isolation_upper_offsets is not None

        assert idx.activation_method_at(0) is ActivationMethod.NONE
        assert idx.activation_method_at(1) is ActivationMethod.HCD
        assert idx.activation_method_at(2) is ActivationMethod.CID

        assert idx.isolation_window_at(0) is None  # all-zero sentinel
        w1 = idx.isolation_window_at(1)
        assert isinstance(w1, IsolationWindow)
        assert w1.target_mz == pytest.approx(500.0)
        assert w1.lower_offset == pytest.approx(1.0)
        assert w1.upper_offset == pytest.approx(2.0)
        w2 = idx.isolation_window_at(2)
        assert w2 is not None
        assert w2.target_mz == pytest.approx(750.5)
        assert w2.width == pytest.approx(1.25)


def test_m74_file_bumps_format_version_and_advertises_flag(
    tmp_path: Path,
) -> None:
    """Slice E: writing a dataset with M74 columns must bump
    ``@ttio_format_version`` from ``"1.1"`` to ``"1.3"`` and include
    ``opt_ms2_activation_detail`` in ``@ttio_features``. A dataset
    without M74 columns keeps the legacy ``"1.1"`` layout."""
    # Legacy: no M74 columns => format 1.1, flag absent
    legacy_path = tmp_path / "legacy.tio"
    SpectralDataset.write_minimal(
        legacy_path, title="legacy", isa_investigation_id="TTIO:legacy",
        runs={"run_0001": _make_run(n_spectra=2, points_per=4)},
    )
    with SpectralDataset.open(legacy_path) as ds:
        assert ds.feature_flags.version == "1.1"
        assert "opt_ms2_activation_detail" not in ds.feature_flags.features

    # M74: any run with activation_methods => format 1.3 + flag
    m74_path = tmp_path / "m74.tio"
    run = _make_run(n_spectra=2, points_per=4)
    run.activation_methods = np.array(
        [int(ActivationMethod.NONE), int(ActivationMethod.HCD)],
        dtype=np.int32,
    )
    run.isolation_target_mzs = np.array([0.0, 445.3], dtype=np.float64)
    run.isolation_lower_offsets = np.array([0.0, 0.5], dtype=np.float64)
    run.isolation_upper_offsets = np.array([0.0, 0.5], dtype=np.float64)
    SpectralDataset.write_minimal(
        m74_path, title="m74", isa_investigation_id="TTIO:m74",
        runs={"run_0001": run},
    )
    with SpectralDataset.open(m74_path) as ds:
        assert ds.feature_flags.version == "1.3"
        assert "opt_ms2_activation_detail" in ds.feature_flags.features
        # Columns still round-trip.
        idx = ds.ms_runs["run_0001"].index
        assert idx.activation_methods is not None
        assert idx.activation_method_at(1) is ActivationMethod.HCD


def test_written_run_rejects_partial_m74_population(tmp_path: Path) -> None:
    """All-or-nothing: populating some but not all of the four M74
    arrays is a schema error."""
    out = tmp_path / "partial_m74.tio"
    run = _make_run(n_spectra=2, points_per=4)
    run.activation_methods = np.array([0, 0], dtype=np.int32)
    # Deliberately omit the isolation_* trio.
    with pytest.raises(ValueError, match="M74 columns"):
        SpectralDataset.write_minimal(
            out, title="partial m74", isa_investigation_id="TTIO:part",
            runs={"run_0001": run},
        )
