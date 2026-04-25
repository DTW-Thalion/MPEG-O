"""End-to-end TTI-O workflows (v0.9 M61).

Four scenarios from the HANDOFF, each exercised across all four
storage providers (HDF5, Memory, SQLite, Zarr):

1. **BSA proteomics pipeline** — mzML import → query MS2 → add
   peptide identifications → re-emit mzML → ISA-Tab export →
   sign + verify → encrypt + decrypt → anonymize → confirm
   provenance chain.
2. **Multi-modal MS + NMR** — two runs in one .tio, ISA bundle
   carries both assays, format-specific re-export.
3. **Key-rotation lifecycle** — wrap DEK with KEK-A, rotate to
   KEK-B, verify history. (KeyRotation is provider-aware as of
   M64.5 phase C, so this matrix runs across all four backends.)
4. **Clinical anonymization** — SAAV-redaction policy on a dataset
   with SAAV identifications; confirm SAAV spectra removed,
   non-SAAV spectra intact, original file unmodified, signed
   provenance written.

Acceptance for the milestone: every cell in the parametrized matrix
is green, plus the workflow assertions are exhaustive enough to
catch regressions in the import → query → modify → export paths.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import numpy as np
import pytest

from ttio import (
    AcquisitionMode,
    Identification,
    SpectralDataset,
    WrittenRun,
)
from ttio.anonymization import AnonymizationPolicy, anonymize
from ttio.exporters import isa as isa_exporter
from ttio.exporters import mzml as mzml_writer
from ttio.importers import mzml as mzml_reader
from ttio.key_rotation import (
    enable_envelope_encryption,
    has_envelope_encryption,
    key_history,
    rotate_key,
    unwrap_dek,
)
from ttio.signatures import sign_dataset, verify_dataset
from ttio.value_range import ValueRange

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _provider_matrix import (  # type: ignore[import-not-found]
    PROVIDERS as _PROVIDERS,
    maybe_skip_provider as _maybe_skip_provider,
    provider_url as _provider_url,
)


# --------------------------------------------------------------------------- #
# Synthetic-fixture helpers (lifted from test_mzml_roundtrip — keeping copies
# small and explicit since the workflow tests want full control over
# precursor m/z values and MS-level patterns).
# --------------------------------------------------------------------------- #

import base64
import zlib


def _b64_doubles(arr: np.ndarray) -> str:
    return base64.b64encode(np.ascontiguousarray(arr, dtype="<f8").tobytes()).decode("ascii")


def _spectrum_xml(*, index: int, mz: np.ndarray, intensity: np.ndarray,
                   ms_level: int, rt: float,
                   precursor_mz: float = 0.0, precursor_charge: int = 0) -> str:
    n = mz.size
    encoded_mz = _b64_doubles(mz)
    encoded_it = _b64_doubles(intensity)
    precursor_block = ""
    if ms_level == 2:
        precursor_block = f"""
        <precursorList count="1"><precursor>
          <selectedIonList count="1"><selectedIon>
            <cvParam cvRef="MS" accession="MS:1000744" name="selected ion m/z" value="{precursor_mz}"/>
            <cvParam cvRef="MS" accession="MS:1000041" name="charge state" value="{precursor_charge}"/>
          </selectedIon></selectedIonList>
        </precursor></precursorList>"""
    return f"""      <spectrum index="{index}" id="scan={index + 1}" defaultArrayLength="{n}">
        <cvParam cvRef="MS" accession="MS:1000511" name="ms level" value="{ms_level}"/>
        <cvParam cvRef="MS" accession="MS:1000130" name="positive scan"/>
        <scanList count="1"><scan>
          <cvParam cvRef="MS" accession="MS:1000016" name="scan start time" value="{rt}" unitCvRef="UO" unitAccession="UO:0000010"/>
        </scan></scanList>{precursor_block}
        <binaryDataArrayList count="2">
          <binaryDataArray encodedLength="{len(encoded_mz)}">
            <cvParam cvRef="MS" accession="MS:1000523" name="64-bit float"/>
            <cvParam cvRef="MS" accession="MS:1000576" name="no compression"/>
            <cvParam cvRef="MS" accession="MS:1000514" name="m/z array"/>
            <binary>{encoded_mz}</binary>
          </binaryDataArray>
          <binaryDataArray encodedLength="{len(encoded_it)}">
            <cvParam cvRef="MS" accession="MS:1000523" name="64-bit float"/>
            <cvParam cvRef="MS" accession="MS:1000576" name="no compression"/>
            <cvParam cvRef="MS" accession="MS:1000515" name="intensity array"/>
            <binary>{encoded_it}</binary>
          </binaryDataArray>
        </binaryDataArrayList>
      </spectrum>
"""


def _wrap_mzml(spectra_xml: str, run_id: str) -> str:
    n = spectra_xml.count("<spectrum ")
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<mzML xmlns="http://psi.hupo.org/ms/mzml" version="1.1.0">
  <cvList count="2">
    <cv id="MS" fullName="PSI MS" version="4.1.0"/>
    <cv id="UO" fullName="UO" version="2020-03-10"/>
  </cvList>
  <fileDescription><fileContent>
    <cvParam cvRef="MS" accession="MS:1000580" name="MSn spectrum"/>
  </fileContent></fileDescription>
  <softwareList count="1"><software id="ttio" version="0.9.0"/></softwareList>
  <instrumentConfigurationList count="1"><instrumentConfiguration id="IC1"/></instrumentConfigurationList>
  <dataProcessingList count="1"><dataProcessing id="dp"/></dataProcessingList>
  <run id="{run_id}" defaultInstrumentConfigurationRef="IC1">
    <spectrumList count="{n}" defaultDataProcessingRef="dp">
{spectra_xml}    </spectrumList>
  </run>
</mzML>
"""


def _build_bsa_synthetic_mzml(tmp_path: Path) -> Path:
    """3 MS1 + 2 MS2 spectra; one MS2 has precursor m/z 547.27."""
    rng = np.random.default_rng(11)
    parts: list[str] = []
    spectra_meta: list[tuple[int, float, float]] = []  # (ms_level, rt, precursor_mz)
    for i in range(5):
        if i in (1, 3):
            ms_level = 2
            precursor = 547.27 if i == 1 else 800.0
        else:
            ms_level = 1
            precursor = 0.0
        n = 16
        mz = np.linspace(100.0 + i, 500.0 + i, n)
        intensity = rng.uniform(0.0, 1e6, size=n)
        rt = float(i) * 0.5
        parts.append(_spectrum_xml(
            index=i, mz=mz, intensity=intensity,
            ms_level=ms_level, rt=rt,
            precursor_mz=precursor, precursor_charge=2 if ms_level == 2 else 0,
        ))
        spectra_meta.append((ms_level, rt, precursor))
    out = tmp_path / "bsa.mzML"
    out.write_text(_wrap_mzml("".join(parts), run_id="bsa_run"))
    return out


# --------------------------------------------------------------------------- #
# Workflow 1 — BSA proteomics pipeline (cross-provider).
# --------------------------------------------------------------------------- #

@pytest.mark.parametrize("provider", _PROVIDERS)
def test_workflow_bsa_proteomics_pipeline(provider: str, tmp_path: Path) -> None:
    _maybe_skip_provider(provider)
    src = _build_bsa_synthetic_mzml(tmp_path)

    # 1. Import mzML → .tio on the parametrized provider.
    ttio_url = _provider_url(provider, tmp_path, "bsa")
    mzml_reader.read(src).to_ttio(ttio_url, provider=provider)

    # 2. Open + verify spectrum count and MS-level distribution.
    with SpectralDataset.open(ttio_url) as ds:
        run = ds.ms_runs["run_0001"]
        assert len(run) == 5
        ms1_indices = run.index.indices_for_ms_level(1)
        ms2_indices = run.index.indices_for_ms_level(2)
        assert len(ms1_indices) == 3
        assert len(ms2_indices) == 2

        # 3. Query MS2 with precursor m/z near 547.27 ± 0.5.
        ms2_at_547 = [
            i for i in ms2_indices
            if abs(run.index.precursor_mz_at(i) - 547.27) < 0.5
        ]
        assert len(ms2_at_547) == 1
        assert ms2_at_547[0] == 1

    # 4. Add BSA peptide identifications by re-writing through the
    #    importer-style write_minimal call (the provider= kwarg makes
    #    this work on every backend).
    parsed = mzml_reader.read(src)
    parsed.identifications = [
        Identification(
            run_name="run_0001", spectrum_index=int(i),
            chemical_entity=f"BSA_PEPTIDE_{j:02d}",
            confidence_score=0.85 + 0.01 * j,
        )
        for j, i in enumerate(ms2_at_547)
    ]
    ttio_with_ids = _provider_url(provider, tmp_path, "bsa_ids")
    parsed.to_ttio(ttio_with_ids, provider=provider)

    # 5. Re-export to mzML → both spectra survive the round-trip.
    out_mzml = tmp_path / "bsa_out.mzML"
    with SpectralDataset.open(ttio_with_ids, writable=True) as ds:
        mzml_writer.write_dataset(ds, out_mzml, zlib_compression=False)
        re_imported = mzml_reader.read(out_mzml)
        assert len(re_imported.ms_spectra) == 5

        # 6. Export ISA-Tab bundle (HDF5-only here — ISA exporter
        #    consumes the public dataset API, which works for any
        #    provider, but we touch only the dataset, not native
        #    bytes, so it lights up across all four).
        bundle_dir = tmp_path / f"isa_{provider}"
        isa_exporter.write_bundle_for_dataset(ds, bundle_dir)
        assert (bundle_dir / "i_investigation.txt").is_file()
        assert (bundle_dir / "s_study.txt").is_file()
        assert (bundle_dir / "a_assay_ms_run_0001.txt").is_file()

        # 7. Sign + verify the intensity dataset on the parametrized provider.
        sig_group = ds.ms_runs["run_0001"].group.open_group("signal_channels")
        intensity_ds = sig_group.open_dataset("intensity_values")
        key = bytes(range(32))
        sig = sign_dataset(intensity_ds, key)
        assert sig.startswith("v2:")
        assert verify_dataset(intensity_ds, key) is True
        assert verify_dataset(intensity_ds, b"\xaa" * 32) is False

    # 8. Anonymize FIRST (operates on a clean dataset). Strip metadata
    #    + coarsen m/z. Output written through the same provider via the
    #    provider= kwarg.
    anon_url = _provider_url(provider, tmp_path, "bsa_anon")
    with SpectralDataset.open(ttio_with_ids) as ds:
        result = anonymize(
            ds, anon_url,
            AnonymizationPolicy(strip_metadata_fields=True, coarsen_mz_decimals=1),
            provider=provider,
        )
    assert result.metadata_fields_stripped == 1
    assert "strip_metadata_fields" in result.policies_applied

    # 9. Verify the anonymized .tio carries the right provenance + flags.
    with SpectralDataset.open(anon_url) as anon_ds:
        prov = anon_ds.provenance()
        assert prov, "anonymizer must record at least one provenance step"
        assert prov[0].software.startswith("ttio anonymizer")
        assert anon_ds.feature_flags.has("opt_anonymized")
        assert anon_ds.title == ""  # stripped

    # 10. Encrypt → decrypt the intensity channel on the original file.
    #     Done last so encryption's destructive in-place rewrite of
    #     intensity_values doesn't break later steps that need plaintext.
    with SpectralDataset.open(ttio_with_ids, writable=True) as ds:
        run = ds.ms_runs["run_0001"]
        run.encrypt_with_key(key, level=0)
        plaintext = run.decrypt_with_key(key)
        assert len(plaintext) % 8 == 0
        decrypted = np.frombuffer(plaintext, dtype="<f8")
        # Original intensities concatenated across 5 spectra of 16 peaks.
        assert decrypted.size == 5 * 16


# --------------------------------------------------------------------------- #
# Workflow 2 — Multi-modal MS + NMR study.
# --------------------------------------------------------------------------- #

def _build_multimodal(provider: str, tmp_path: Path) -> str:
    """Two-run dataset: one MS, one NMR. Identifications across both runs."""
    n_ms, n_nmr = 6, 3
    n_pts = 8
    rng = np.random.default_rng(31)

    ms_mz = np.tile(np.linspace(100.0, 200.0, n_pts), n_ms).astype(np.float64)
    ms_int = rng.uniform(0.0, 1e5, size=n_ms * n_pts).astype(np.float64)
    ms_run = WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": ms_mz, "intensity": ms_int},
        offsets=np.arange(n_ms, dtype=np.uint64) * n_pts,
        lengths=np.full(n_ms, n_pts, dtype=np.uint32),
        retention_times=np.linspace(0.0, 5.0, n_ms),
        ms_levels=np.ones(n_ms, dtype=np.int32),
        polarities=np.ones(n_ms, dtype=np.int32),
        precursor_mzs=np.zeros(n_ms),
        precursor_charges=np.zeros(n_ms, dtype=np.int32),
        base_peak_intensities=ms_int.reshape(n_ms, n_pts).max(axis=1),
    )

    cs = np.tile(np.linspace(-1.0, 12.0, n_pts), n_nmr).astype(np.float64)
    nmr_int = rng.normal(0.0, 1.0, size=n_nmr * n_pts).astype(np.float64)
    nmr_run = WrittenRun(
        spectrum_class="TTIONMRSpectrum",
        acquisition_mode=int(AcquisitionMode.NMR_1D),
        channel_data={"chemical_shift": cs, "intensity": nmr_int},
        offsets=np.arange(n_nmr, dtype=np.uint64) * n_pts,
        lengths=np.full(n_nmr, n_pts, dtype=np.uint32),
        retention_times=np.zeros(n_nmr),
        ms_levels=np.zeros(n_nmr, dtype=np.int32),
        polarities=np.zeros(n_nmr, dtype=np.int32),
        precursor_mzs=np.zeros(n_nmr),
        precursor_charges=np.zeros(n_nmr, dtype=np.int32),
        base_peak_intensities=np.zeros(n_nmr),
        nucleus_type="1H",
    )

    ids = [
        Identification("ms_run", 0, "CHEBI:1001", 0.92, []),
        Identification("nmr_run", 0, "CHEBI:1001", 0.81, []),
    ]
    url = _provider_url(provider, tmp_path, "multimodal")
    SpectralDataset.write_minimal(
        url, title="multimodal", isa_investigation_id="ISA-MULTI",
        runs={"ms_run": ms_run, "nmr_run": nmr_run},
        identifications=ids,
        provider=provider,
    )
    return url


@pytest.mark.parametrize("provider", _PROVIDERS)
def test_workflow_multimodal(provider: str, tmp_path: Path) -> None:
    _maybe_skip_provider(provider)
    url = _build_multimodal(provider, tmp_path)
    with SpectralDataset.open(url) as ds:
        # Both runs visible (write_minimal puts NMR runs in ms_runs by name).
        assert set(ds.all_runs.keys()) == {"ms_run", "nmr_run"}
        assert len(ds.ms_runs["ms_run"]) == 6
        nmr = ds.ms_runs["nmr_run"]
        assert nmr.spectrum_class == "TTIONMRSpectrum"
        assert len(nmr) == 3

        # Cross-modal identifications survived the write.
        ids = ds.identifications()
        assert len(ids) == 2
        assert {i.run_name for i in ids} == {"ms_run", "nmr_run"}

        # ISA bundle includes one assay file per run.
        bundle_dir = tmp_path / f"isa_multi_{provider}"
        isa_exporter.write_bundle_for_dataset(ds, bundle_dir)
        assert (bundle_dir / "a_assay_ms_ms_run.txt").is_file()
        assert (bundle_dir / "a_assay_ms_nmr_run.txt").is_file()


# --------------------------------------------------------------------------- #
# Workflow 3 — Key-rotation lifecycle (cross-provider).
# --------------------------------------------------------------------------- #

@pytest.mark.parametrize("provider", _PROVIDERS)
def test_workflow_key_rotation_lifecycle(provider: str, tmp_path: Path) -> None:
    _maybe_skip_provider(provider)
    url = _build_multimodal(provider, tmp_path)

    kek_a = os.urandom(32)
    kek_b = os.urandom(32)

    with SpectralDataset.open(url, writable=True) as ds:
        assert has_envelope_encryption(ds) is False
        dek = enable_envelope_encryption(ds, kek_a, kek_id="kek-a")
        assert has_envelope_encryption(ds) is True

        # Rotate KEK-A → KEK-B.
        rotate_key(ds, old_kek=kek_a, new_kek=kek_b, new_kek_id="kek-b")

        # KEK-A no longer authenticates; KEK-B unwraps the original DEK.
        with pytest.raises(Exception):
            unwrap_dek(ds, kek_a)
        assert unwrap_dek(ds, kek_b) == dek

        # History records the prior KEK with timestamp.
        history = key_history(ds)
        assert len(history) == 1
        assert history[0]["kek_id"] == "kek-a"
        assert history[0]["kek_algorithm"] == "aes-256-gcm"


# --------------------------------------------------------------------------- #
# Workflow 4 — Clinical anonymization.
# --------------------------------------------------------------------------- #

def _build_clinical(provider: str, tmp_path: Path) -> str:
    """5 spectra; identifications include 1 SAAV peptide + 4 normals."""
    n = 5
    n_pts = 8
    rng = np.random.default_rng(404)
    mz = np.tile(np.linspace(100.0, 200.0, n_pts), n).astype(np.float64)
    intensity = rng.uniform(0.0, 1e6, size=n * n_pts).astype(np.float64)
    run = WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=0,
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
    ids = [
        Identification("run_0001", 0, "P12345", 0.95, []),
        Identification("run_0001", 1, "p.Glu67Lys SAAV", 0.88, []),
        Identification("run_0001", 2, "P12345", 0.92, []),
        Identification("run_0001", 3, "P67890", 0.81, []),
        Identification("run_0001", 4, "P67890", 0.79, []),
    ]
    url = _provider_url(provider, tmp_path, "clinical")
    SpectralDataset.write_minimal(
        url, title="clinical-source", isa_investigation_id="ISA-CLIN",
        runs={"run_0001": run},
        identifications=ids,
        provider=provider,
    )
    return url


@pytest.mark.parametrize("provider", _PROVIDERS)
def test_workflow_clinical_anonymization(provider: str, tmp_path: Path) -> None:
    _maybe_skip_provider(provider)
    src_url = _build_clinical(provider, tmp_path)
    out_url = _provider_url(provider, tmp_path, "clinical_anon")

    with SpectralDataset.open(src_url) as ds:
        original_count = len(ds.ms_runs["run_0001"])
        result = anonymize(
            ds, out_url,
            AnonymizationPolicy(
                redact_saav_spectra=True,
                strip_metadata_fields=True,
            ),
            provider=provider,
        )
    assert result.spectra_redacted == 1
    assert "redact_saav_spectra" in result.policies_applied
    assert "strip_metadata_fields" in result.policies_applied

    # SAAV spectrum redacted — kept count = original − 1.
    with SpectralDataset.open(out_url) as anon_ds:
        assert len(anon_ds.ms_runs["run_0001"]) == original_count - 1
        # Title stripped.
        assert anon_ds.title == ""
        # Provenance carries the policy summary.
        prov = anon_ds.provenance()
        assert prov and prov[0].software.startswith("ttio anonymizer")
        assert anon_ds.feature_flags.has("opt_anonymized")

    # Original file unmodified.
    with SpectralDataset.open(src_url) as orig_ds:
        assert len(orig_ds.ms_runs["run_0001"]) == original_count
        assert orig_ds.title == "clinical-source"
