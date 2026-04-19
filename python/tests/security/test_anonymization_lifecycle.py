"""Anonymization lifecycle matrix (v0.9 M61).

7 scenarios × 4 providers = 28 cells covering every policy in
:class:`AnonymizationPolicy`. The anonymizer was made provider-aware
in M64.5 phase B (just a ``provider=`` passthrough on top of
``write_minimal``); this matrix proves every policy lands correctly
on Memory, SQLite, and Zarr backends.

Scenarios (per HANDOFF M61 §"Anonymization lifecycle"):

* ``test_saav_redaction`` — ``redact_saav_spectra`` removes the
  identified SAAV spectrum and leaves the rest intact.
* ``test_intensity_masking`` — ``mask_intensity_below_quantile``
  zeros peaks below the chosen quantile.
* ``test_mz_coarsening`` — ``coarsen_mz_decimals`` rounds m/z
  to N decimals.
* ``test_chemical_shift_coarsening`` — same for NMR runs.
* ``test_rare_metabolite_masking`` — ``mask_rare_metabolites``
  zeros intensities of rare-CHEBI annotations.
* ``test_metadata_stripping`` — ``strip_metadata_fields`` clears
  the title.
* ``test_original_unmodified`` — anonymization writes a fresh
  output without touching the source file.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pytest

from mpeg_o import (
    AcquisitionMode,
    Identification,
    SpectralDataset,
    WrittenRun,
)
from mpeg_o.anonymization import AnonymizationPolicy, anonymize

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "integration"))
from _provider_matrix import (  # type: ignore[import-not-found]
    PROVIDERS as _PROVIDERS,
    maybe_skip_provider as _maybe_skip_provider,
    provider_url as _provider_url,
)


def _build_ms(provider: str, tmp_path: Path,
                 *, identifications: list[Identification] | None = None,
                 n: int = 5, n_pts: int = 8) -> str:
    rng = np.random.default_rng(123)
    mz = np.tile(np.linspace(100.0, 200.0, n_pts), n).astype(np.float64)
    intensity = rng.uniform(0.0, 1e6, size=n * n_pts).astype(np.float64)
    run = WrittenRun(
        spectrum_class="MPGOMassSpectrum", acquisition_mode=0,
        channel_data={"mz": mz, "intensity": intensity},
        offsets=np.arange(n, dtype=np.uint64) * n_pts,
        lengths=np.full(n, n_pts, dtype=np.uint32),
        retention_times=np.linspace(0.0, 4.0, n),
        ms_levels=np.ones(n, dtype=np.int32),
        polarities=np.ones(n, dtype=np.int32),
        precursor_mzs=np.zeros(n),
        precursor_charges=np.zeros(n, dtype=np.int32),
        base_peak_intensities=intensity.reshape(n, n_pts).max(axis=1),
    )
    url = _provider_url(provider, tmp_path, "anon")
    SpectralDataset.write_minimal(
        url, title="anon-source", isa_investigation_id="ISA-ANON",
        runs={"run_0001": run},
        identifications=identifications,
        provider=provider,
    )
    return url


def _build_nmr(provider: str, tmp_path: Path) -> str:
    n = 1
    n_pts = 32
    cs = np.linspace(-1.0, 12.0, n_pts).astype(np.float64)
    intensity = np.linspace(0.0, 1.0, n_pts).astype(np.float64)
    run = WrittenRun(
        spectrum_class="MPGONMRSpectrum",
        acquisition_mode=int(AcquisitionMode.NMR_1D),
        channel_data={"chemical_shift": cs, "intensity": intensity},
        offsets=np.array([0], dtype=np.uint64),
        lengths=np.array([n_pts], dtype=np.uint32),
        retention_times=np.zeros(n),
        ms_levels=np.zeros(n, dtype=np.int32),
        polarities=np.zeros(n, dtype=np.int32),
        precursor_mzs=np.zeros(n),
        precursor_charges=np.zeros(n, dtype=np.int32),
        base_peak_intensities=np.zeros(n),
        nucleus_type="1H",
    )
    url = _provider_url(provider, tmp_path, "anon_nmr")
    SpectralDataset.write_minimal(
        url, title="nmr-source", isa_investigation_id="ISA-ANON-NMR",
        runs={"nmr_run": run}, provider=provider,
    )
    return url


@pytest.mark.parametrize("provider", _PROVIDERS)
class TestAnonymizationLifecycle:

    def test_saav_redaction(self, provider: str, tmp_path: Path) -> None:
        _maybe_skip_provider(provider)
        ids = [
            Identification("run_0001", 2, "p.Glu67Lys SAAV", 0.9, []),
            Identification("run_0001", 0, "P12345", 0.95, []),
        ]
        src = _build_ms(provider, tmp_path, identifications=ids)
        out = _provider_url(provider, tmp_path, "saav_anon")
        with SpectralDataset.open(src) as ds:
            result = anonymize(
                ds, out,
                AnonymizationPolicy(redact_saav_spectra=True),
                provider=provider,
            )
        assert result.spectra_redacted == 1
        with SpectralDataset.open(out) as anon:
            assert len(anon.ms_runs["run_0001"]) == 4

    def test_intensity_masking(self, provider: str, tmp_path: Path) -> None:
        _maybe_skip_provider(provider)
        src = _build_ms(provider, tmp_path)
        out = _provider_url(provider, tmp_path, "intens_anon")
        with SpectralDataset.open(src) as ds:
            result = anonymize(
                ds, out,
                AnonymizationPolicy(mask_intensity_below_quantile=0.5),
                provider=provider,
            )
        assert result.intensities_zeroed > 0
        with SpectralDataset.open(out) as anon:
            spec = anon.ms_runs["run_0001"][0]
            # At least one zero somewhere across the masked spectra.
            zero_count = int(np.sum(spec.signal_arrays["intensity"].data == 0.0))
            assert zero_count > 0

    def test_mz_coarsening(self, provider: str, tmp_path: Path) -> None:
        _maybe_skip_provider(provider)
        src = _build_ms(provider, tmp_path)
        out = _provider_url(provider, tmp_path, "mz_anon")
        with SpectralDataset.open(src) as ds:
            result = anonymize(
                ds, out,
                AnonymizationPolicy(coarsen_mz_decimals=0),
                provider=provider,
            )
        assert result.mz_values_coarsened > 0
        with SpectralDataset.open(out) as anon:
            spec = anon.ms_runs["run_0001"][0]
            mz = spec.signal_arrays["mz"].data
            assert np.all(mz == np.round(mz, 0))

    def test_chemical_shift_coarsening(self, provider: str, tmp_path: Path) -> None:
        _maybe_skip_provider(provider)
        src = _build_nmr(provider, tmp_path)
        out = _provider_url(provider, tmp_path, "cs_anon")
        with SpectralDataset.open(src) as ds:
            result = anonymize(
                ds, out,
                AnonymizationPolicy(coarsen_chemical_shift_decimals=1),
                provider=provider,
            )
        assert result.chemical_shift_values_coarsened > 0
        with SpectralDataset.open(out) as anon:
            spec = anon.ms_runs["nmr_run"][0]
            cs = spec.signal_arrays["chemical_shift"].data
            assert np.all(cs == np.round(cs, 1))

    def test_rare_metabolite_masking(self, provider: str, tmp_path: Path) -> None:
        _maybe_skip_provider(provider)
        ids = [
            Identification("run_0001", 0, "CHEBI:99999", 0.95, []),
            Identification("run_0001", 1, "CHEBI:17234", 0.95, []),
        ]
        src = _build_ms(provider, tmp_path, identifications=ids)
        out = _provider_url(provider, tmp_path, "rare_anon")
        prevalence = {"CHEBI:99999": 0.001, "CHEBI:17234": 0.50}
        with SpectralDataset.open(src) as ds:
            result = anonymize(
                ds, out,
                AnonymizationPolicy(
                    mask_rare_metabolites=True,
                    rare_metabolite_threshold=0.05,
                    rare_metabolite_table=prevalence,
                ),
                provider=provider,
            )
        assert result.metabolites_masked == 1
        with SpectralDataset.open(out) as anon:
            spec0 = anon.ms_runs["run_0001"][0]
            assert float(np.max(spec0.signal_arrays["intensity"].data)) == 0.0
            spec1 = anon.ms_runs["run_0001"][1]
            assert float(np.max(spec1.signal_arrays["intensity"].data)) > 0.0

    def test_metadata_stripping(self, provider: str, tmp_path: Path) -> None:
        _maybe_skip_provider(provider)
        src = _build_ms(provider, tmp_path)
        out = _provider_url(provider, tmp_path, "meta_anon")
        with SpectralDataset.open(src) as ds:
            result = anonymize(
                ds, out,
                AnonymizationPolicy(strip_metadata_fields=True),
                provider=provider,
            )
        assert result.metadata_fields_stripped == 1
        with SpectralDataset.open(out) as anon:
            assert anon.title == ""

    def test_original_unmodified(self, provider: str, tmp_path: Path) -> None:
        _maybe_skip_provider(provider)
        src = _build_ms(provider, tmp_path)
        out = _provider_url(provider, tmp_path, "untouched_anon")
        with SpectralDataset.open(src) as ds:
            original_count = len(ds.ms_runs["run_0001"])
            anonymize(
                ds, out,
                AnonymizationPolicy(strip_metadata_fields=True, coarsen_mz_decimals=0),
                provider=provider,
            )
        with SpectralDataset.open(src) as orig:
            assert len(orig.ms_runs["run_0001"]) == original_count
            assert orig.title == "anon-source"
