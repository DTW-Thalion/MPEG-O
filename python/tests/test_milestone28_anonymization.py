"""Milestone 28 — spectral anonymization.

Per-policy tests + integration round-trip that verifies the output is
a valid .tio readable by SpectralDataset.open with the opt_anonymized
feature flag and a provenance record documenting what was done.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ttio import SpectralDataset, WrittenRun
from ttio.anonymization import AnonymizationPolicy, anonymize
from ttio.feature_flags import OPT_ANONYMIZED
from ttio.identification import Identification


def _build_source(tmp_path: Path, *, n_spectra: int = 5, ids: list[Identification] | None = None) -> SpectralDataset:
    n = 10
    mz = np.linspace(100.0, 200.0, n, dtype=np.float64)
    it = np.arange(n, dtype=np.float64) * 100 + 50
    total = n * n_spectra
    channel = {"mz": np.tile(mz, n_spectra), "intensity": np.tile(it, n_spectra)}
    offsets = np.arange(n_spectra, dtype=np.uint64) * n
    lengths = np.full(n_spectra, n, dtype=np.uint32)
    run = WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=0,
        channel_data=channel,
        offsets=offsets, lengths=lengths,
        retention_times=np.linspace(0.0, 10.0, n_spectra, dtype=np.float64),
        ms_levels=np.ones(n_spectra, dtype=np.int32),
        polarities=np.ones(n_spectra, dtype=np.int32),
        precursor_mzs=np.zeros(n_spectra, dtype=np.float64),
        precursor_charges=np.zeros(n_spectra, dtype=np.int32),
        base_peak_intensities=np.full(n_spectra, 950.0, dtype=np.float64),
    )
    path = tmp_path / "m28_source.tio"
    SpectralDataset.write_minimal(
        path,
        title="M28 Source",
        isa_investigation_id="ISA-M28",
        runs={"run_0001": run},
        identifications=ids,
    )
    return SpectralDataset.open(path)


def test_feature_flag() -> None:
    assert OPT_ANONYMIZED == "opt_anonymized"


def test_redact_saav_spectra(tmp_path: Path) -> None:
    ids = [
        Identification("run_0001", 1, "CHEBI:12345", 0.9, []),
        Identification("run_0001", 3, "p.Ala123Thr SAAV", 0.85, []),
    ]
    ds = _build_source(tmp_path, n_spectra=5, ids=ids)
    out = tmp_path / "m28_saav.tio"
    policy = AnonymizationPolicy(redact_saav_spectra=True)
    try:
        result = anonymize(ds, out, policy)
    finally:
        ds.close()
    assert result.spectra_redacted == 1
    assert "redact_saav_spectra" in result.policies_applied
    with SpectralDataset.open(out) as anon:
        assert len(anon.ms_runs["run_0001"]) == 4


def test_mask_intensity_below_quantile(tmp_path: Path) -> None:
    ds = _build_source(tmp_path, n_spectra=1)
    out = tmp_path / "m28_intensity.tio"
    policy = AnonymizationPolicy(mask_intensity_below_quantile=0.5)
    try:
        result = anonymize(ds, out, policy)
    finally:
        ds.close()
    assert result.intensities_zeroed > 0
    with SpectralDataset.open(out) as anon:
        spec = anon.ms_runs["run_0001"][0]
        assert float(np.min(spec.signal_arrays["intensity"].data)) == 0.0


def test_coarsen_mz_decimals(tmp_path: Path) -> None:
    ds = _build_source(tmp_path, n_spectra=1)
    out = tmp_path / "m28_mz.tio"
    policy = AnonymizationPolicy(coarsen_mz_decimals=0)
    try:
        result = anonymize(ds, out, policy)
    finally:
        ds.close()
    assert result.mz_values_coarsened > 0
    with SpectralDataset.open(out) as anon:
        spec = anon.ms_runs["run_0001"][0]
        mz = spec.signal_arrays["mz"].data
        assert np.all(mz == np.round(mz, 0))


def test_mask_rare_metabolites(tmp_path: Path) -> None:
    table = {"CHEBI:99999": 0.001}
    ids = [Identification("run_0001", 0, "CHEBI:99999", 0.95, [])]
    ds = _build_source(tmp_path, n_spectra=2, ids=ids)
    out = tmp_path / "m28_rare.tio"
    policy = AnonymizationPolicy(
        mask_rare_metabolites=True,
        rare_metabolite_threshold=0.05,
        rare_metabolite_table=table,
    )
    try:
        result = anonymize(ds, out, policy)
    finally:
        ds.close()
    assert result.metabolites_masked == 1
    with SpectralDataset.open(out) as anon:
        spec0 = anon.ms_runs["run_0001"][0]
        assert float(np.max(spec0.signal_arrays["intensity"].data)) == 0.0
        spec1 = anon.ms_runs["run_0001"][1]
        assert float(np.max(spec1.signal_arrays["intensity"].data)) > 0.0


def test_strip_metadata_fields(tmp_path: Path) -> None:
    ds = _build_source(tmp_path, n_spectra=1)
    out = tmp_path / "m28_strip.tio"
    policy = AnonymizationPolicy(strip_metadata_fields=True)
    try:
        result = anonymize(ds, out, policy)
    finally:
        ds.close()
    assert result.metadata_fields_stripped == 1
    with SpectralDataset.open(out) as anon:
        assert anon.title == ""


def test_provenance_and_feature_flag(tmp_path: Path) -> None:
    ds = _build_source(tmp_path, n_spectra=2)
    out = tmp_path / "m28_prov.tio"
    policy = AnonymizationPolicy(coarsen_mz_decimals=1)
    try:
        anonymize(ds, out, policy)
    finally:
        ds.close()
    with SpectralDataset.open(out) as anon:
        assert anon.feature_flags.has("opt_anonymized")
        prov = anon.provenance()
        assert len(prov) >= 1
        assert prov[0].software == "ttio anonymizer v0.4"


def test_original_unmodified(tmp_path: Path) -> None:
    ds = _build_source(tmp_path, n_spectra=3)
    out = tmp_path / "m28_unmod.tio"
    policy = AnonymizationPolicy(redact_saav_spectra=True)
    original_count = len(ds.ms_runs["run_0001"])
    try:
        anonymize(ds, out, policy)
    finally:
        ds.close()
    with SpectralDataset.open(tmp_path / "m28_source.tio") as original:
        assert len(original.ms_runs["run_0001"]) == original_count
