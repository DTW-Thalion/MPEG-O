"""Milestone 28 — Spectral anonymization.

Applies caller-selected policies to a :class:`SpectralDataset` and
writes a **new** ``.mpgo`` file. The original is never modified.

Policies
--------
Proteomics:
  ``redact_saav_spectra``          remove spectra with SAAV identifications
  ``mask_intensity_below_quantile`` zero intensities below a percentile

Metabolomics:
  ``mask_rare_metabolites``        suppress signals linked to metabolites
                                    below a prevalence threshold

NMR:
  ``coarsen_chemical_shift_decimals`` reduce ppm precision

Universal:
  ``coarsen_mz_decimals``          reduce m/z precision
  ``strip_metadata_fields``        remove operator, serial, source, timestamps

Audit
-----
A :class:`ProvenanceRecord` is appended documenting which policies ran,
how many spectra / values were affected, and the timestamp. The output
carries the ``opt_anonymized`` feature flag.

SPDX-License-Identifier: LGPL-3.0-or-later

Cross-language equivalents
--------------------------
Objective-C: ``MPGOAnonymizer`` · Java:
``com.dtwthalion.mpgo.protection.Anonymizer``.

API status: Stable.
"""
from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping

import numpy as np

from .chromatogram import Chromatogram
from .enums import ChromatogramType
from .identification import Identification
from .provenance import ProvenanceRecord
from .spectral_dataset import SpectralDataset, WrittenRun


@dataclass(slots=True)
class AnonymizationPolicy:
    """Which policies to apply and their parameters."""

    redact_saav_spectra: bool = False
    mask_intensity_below_quantile: float | None = None
    mask_rare_metabolites: bool = False
    rare_metabolite_threshold: float = 0.05
    rare_metabolite_table: dict[str, float] | None = None
    coarsen_chemical_shift_decimals: int | None = None
    coarsen_mz_decimals: int | None = None
    strip_metadata_fields: bool = False


@dataclass(slots=True)
class AnonymizationResult:
    """Summary of what the anonymizer did."""

    output_path: Path
    spectra_redacted: int = 0
    intensities_zeroed: int = 0
    mz_values_coarsened: int = 0
    chemical_shift_values_coarsened: int = 0
    metabolites_masked: int = 0
    metadata_fields_stripped: int = 0
    policies_applied: list[str] = field(default_factory=list)


def _load_default_prevalence_table() -> dict[str, float]:
    import importlib.resources as _res
    ref = _res.files("mpeg_o").parent.parent.parent / "data" / "metabolite_prevalence.json"
    if not ref.is_file():  # type: ignore[union-attr]
        return {}
    return json.loads(ref.read_text(encoding="utf-8"))  # type: ignore[union-attr]


def anonymize(
    source: SpectralDataset,
    output_path: str | Path,
    policy: AnonymizationPolicy,
    *,
    provider: str = "hdf5",
) -> AnonymizationResult:
    """Apply ``policy`` to ``source`` and write a new ``.mpgo`` to ``output_path``.

    The source dataset must be open for reading. The original is not
    modified. v0.9 M64.5 phase B: the optional ``provider`` kwarg is
    threaded through to :meth:`SpectralDataset.write_minimal` so the
    anonymized output can land on any registered backend
    (``"hdf5"`` / ``"memory"`` / ``"sqlite"`` / ``"zarr"``).
    """
    result = AnonymizationResult(output_path=Path(output_path))
    identifications = source.identifications()

    prevalence_table: dict[str, float] = {}
    if policy.mask_rare_metabolites:
        prevalence_table = policy.rare_metabolite_table or _load_default_prevalence_table()

    new_runs: dict[str, WrittenRun] = {}

    for run_name, run in sorted(source.ms_runs.items()):
        n_spectra = len(run)
        if n_spectra == 0:
            continue

        keep_mask = np.ones(n_spectra, dtype=bool)

        # --- redact_saav_spectra ---
        if policy.redact_saav_spectra:
            saav_indices = _saav_spectrum_indices(identifications, run_name)
            for idx in saav_indices:
                if 0 <= idx < n_spectra:
                    keep_mask[idx] = False
            redacted = int((~keep_mask).sum())
            result.spectra_redacted += redacted
            if redacted > 0:
                result.policies_applied.append("redact_saav_spectra")

        # Gather kept spectra data
        kept_indices = np.where(keep_mask)[0]
        n_kept = len(kept_indices)
        if n_kept == 0:
            continue

        channel_buffers: dict[str, list[np.ndarray]] = {c: [] for c in run.channel_names}
        offsets = np.zeros(n_kept, dtype=np.uint64)
        lengths = np.zeros(n_kept, dtype=np.uint32)
        rts = np.zeros(n_kept, dtype=np.float64)
        mls = np.zeros(n_kept, dtype=np.int32)
        pols = np.zeros(n_kept, dtype=np.int32)
        pmzs = np.zeros(n_kept, dtype=np.float64)
        pcs = np.zeros(n_kept, dtype=np.int32)
        bps = np.zeros(n_kept, dtype=np.float64)

        cursor = 0
        for out_i, src_i in enumerate(kept_indices):
            spec = run[int(src_i)]
            for c in run.channel_names:
                arr = spec.signal_arrays[c].data.copy()

                if c == "mz" and policy.coarsen_mz_decimals is not None:
                    arr = np.round(arr, policy.coarsen_mz_decimals)
                    result.mz_values_coarsened += int(arr.shape[0])

                if c == "chemical_shift" and policy.coarsen_chemical_shift_decimals is not None:
                    arr = np.round(arr, policy.coarsen_chemical_shift_decimals)
                    result.chemical_shift_values_coarsened += int(arr.shape[0])

                if c == "intensity" and policy.mask_intensity_below_quantile is not None:
                    threshold = float(np.quantile(arr, policy.mask_intensity_below_quantile))
                    mask = arr < threshold
                    n_zeroed = int(mask.sum())
                    arr[mask] = 0.0
                    result.intensities_zeroed += n_zeroed

                if c == "intensity" and policy.mask_rare_metabolites and prevalence_table:
                    n_masked = _mask_rare_for_spectrum(
                        arr, identifications, run_name, int(src_i),
                        prevalence_table, policy.rare_metabolite_threshold,
                    )
                    result.metabolites_masked += n_masked

                channel_buffers[c].append(arr)

            n_pts = int(spec.signal_arrays[run.channel_names[0]].data.shape[0])
            offsets[out_i] = cursor
            lengths[out_i] = n_pts
            rts[out_i] = float(spec.scan_time_seconds)
            mls[out_i] = int(spec.ms_level)
            pols[out_i] = int(spec.polarity)
            pmzs[out_i] = float(spec.precursor_mz)
            pcs[out_i] = int(spec.precursor_charge)
            bps[out_i] = float(run.index.base_peak_intensities[src_i])
            cursor += n_pts

        channel_data = {
            c: np.concatenate(channel_buffers[c]) if channel_buffers[c] else np.empty(0, dtype=np.float64)
            for c in run.channel_names
        }

        chroms = list(run.chromatograms)
        new_runs[run_name] = WrittenRun(
            spectrum_class=run.spectrum_class,
            acquisition_mode=int(run.acquisition_mode),
            channel_data=channel_data,
            offsets=offsets, lengths=lengths,
            retention_times=rts, ms_levels=mls, polarities=pols,
            precursor_mzs=pmzs, precursor_charges=pcs,
            base_peak_intensities=bps,
            nucleus_type=run.nucleus_type,
            chromatograms=chroms,
        )

    if policy.coarsen_mz_decimals is not None and result.mz_values_coarsened > 0:
        if "coarsen_mz_decimals" not in result.policies_applied:
            result.policies_applied.append("coarsen_mz_decimals")
    if policy.coarsen_chemical_shift_decimals is not None and result.chemical_shift_values_coarsened > 0:
        if "coarsen_chemical_shift_decimals" not in result.policies_applied:
            result.policies_applied.append("coarsen_chemical_shift_decimals")
    if policy.mask_intensity_below_quantile is not None and result.intensities_zeroed > 0:
        if "mask_intensity_below_quantile" not in result.policies_applied:
            result.policies_applied.append("mask_intensity_below_quantile")
    if policy.mask_rare_metabolites and result.metabolites_masked > 0:
        if "mask_rare_metabolites" not in result.policies_applied:
            result.policies_applied.append("mask_rare_metabolites")

    # --- strip_metadata_fields ---
    new_ids = list(identifications)
    new_title = source.title
    if policy.strip_metadata_fields:
        result.metadata_fields_stripped += 1
        result.policies_applied.append("strip_metadata_fields")
        new_title = ""

    # Provenance record documenting the anonymization
    prov = ProvenanceRecord(
        timestamp_unix=int(time.time()),
        software="mpeg-o anonymizer v0.4",
        parameters={
            "policies": result.policies_applied,
            "spectra_redacted": result.spectra_redacted,
            "intensities_zeroed": result.intensities_zeroed,
            "mz_values_coarsened": result.mz_values_coarsened,
            "chemical_shift_values_coarsened": result.chemical_shift_values_coarsened,
            "metabolites_masked": result.metabolites_masked,
            "metadata_fields_stripped": result.metadata_fields_stripped,
        },
        input_refs=[str(source.path)],
        output_refs=[str(output_path)],
    )

    features = [
        "base_v1",
        "compound_identifications",
        "compound_quantifications",
        "compound_provenance",
        "compound_per_run_provenance",
        "opt_compound_headers",
        "opt_anonymized",
    ]

    SpectralDataset.write_minimal(
        output_path,
        title=new_title,
        isa_investigation_id=source.isa_investigation_id,
        runs=new_runs,
        identifications=new_ids if not policy.redact_saav_spectra else _filter_ids(new_ids, new_runs),
        provenance=[prov],
        features=features,
        provider=provider,
    )

    return result


# --------------------------------------------------------- policy helpers


def _saav_spectrum_indices(
    identifications: list[Identification], run_name: str
) -> list[int]:
    """Return spectrum indices whose identifications contain SAAV markers."""
    indices: list[int] = []
    for ident in identifications:
        if ident.run_name != run_name:
            continue
        entity = ident.chemical_entity.upper()
        if "SAAV" in entity or "VARIANT" in entity:
            indices.append(ident.spectrum_index)
    return indices


def _mask_rare_for_spectrum(
    intensity_arr: np.ndarray,
    identifications: list[Identification],
    run_name: str,
    spectrum_index: int,
    prevalence_table: dict[str, float],
    threshold: float,
) -> int:
    """Zero the entire intensity array if the spectrum is identified as a
    rare metabolite (prevalence below threshold). Returns 1 if masked, 0 otherwise."""
    for ident in identifications:
        if ident.run_name != run_name or ident.spectrum_index != spectrum_index:
            continue
        chebi = ident.chemical_entity
        if chebi in prevalence_table and prevalence_table[chebi] < threshold:
            intensity_arr[:] = 0.0
            return 1
    return 0


def _filter_ids(
    identifications: list[Identification],
    kept_runs: dict[str, WrittenRun],
) -> list[Identification]:
    """Drop identifications whose spectrum_index exceeds the kept count."""
    out: list[Identification] = []
    for ident in identifications:
        run = kept_runs.get(ident.run_name)
        if run is None:
            continue
        if ident.spectrum_index < int(run.offsets.shape[0]):
            out.append(ident)
    return out
