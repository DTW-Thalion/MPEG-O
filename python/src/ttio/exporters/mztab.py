"""mzTab exporter (v0.9+).

Reverses the M60 importer: takes a :class:`SpectralDataset`'s
``identifications`` + ``quantifications`` (and optionally its
provenance records) and emits a mzTab file. Both the proteomics
1.0 dialect (MTD + PSH/PSM + PRH/PRT sections) and the
metabolomics 2.0.0-M dialect (MTD + SMH/SML) are supported.

SPDX-License-Identifier: Apache-2.0

Cross-language equivalents
--------------------------
Objective-C: ``TTIOMzTabWriter`` · Java:
``global.thalion.ttio.exporters.MzTabWriter``

API status: Provisional (v0.9+).
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Mapping

from ..feature import Feature
from ..identification import Identification
from ..provenance import ProvenanceRecord
from ..quantification import Quantification
from ..spectral_dataset import SpectralDataset


__all__ = ["write_dataset", "write", "dataset_to_bytes", "WriteResult"]


@dataclass(slots=True)
class WriteResult:
    """Paths + dialect emitted."""
    path: Path
    version: str
    n_psm_rows: int
    n_prt_rows: int
    n_sml_rows: int
    n_pep_rows: int = 0
    n_smf_rows: int = 0
    n_sme_rows: int = 0


# --------------------------------------------------------------------------- #
# Public entry points.
# --------------------------------------------------------------------------- #

def write_dataset(
    dataset: SpectralDataset,
    path: str | Path,
    *,
    version: str = "1.0",
    title: str = "",
    description: str = "",
    features: Iterable[Feature] | None = None,
) -> WriteResult:
    """Write ``dataset``'s identifications + quantifications as mzTab.

    ``identifications`` / ``quantifications`` are method accessors on
    :class:`SpectralDataset`; call them here so the writer's caller
    doesn't need to know. ``provenance`` may be a list *or* a method,
    depending on how the dataset was constructed. ``features`` is
    optional — :class:`SpectralDataset` does not yet store feature
    rows, so callers must thread them in explicitly.
    """
    ids = _maybe_call(dataset, "identifications")
    qts = _maybe_call(dataset, "quantifications")
    pvs = _maybe_call(dataset, "provenance")
    feats = list(features or _maybe_call(dataset, "features"))
    return write(
        path,
        identifications=list(ids),
        quantifications=list(qts),
        provenance=list(pvs),
        features=feats,
        version=version,
        title=title or getattr(dataset, "title", "") or "",
        description=description,
    )


def _maybe_call(obj: object, name: str) -> Iterable:
    attr = getattr(obj, name, None)
    if attr is None:
        return []
    if callable(attr):
        try:
            result = attr()
        except TypeError:
            result = attr
    else:
        result = attr
    return result if result is not None else []


def write(
    path: str | Path,
    *,
    identifications: Iterable[Identification] = (),
    quantifications: Iterable[Quantification] = (),
    provenance: Iterable[ProvenanceRecord] = (),
    features: Iterable[Feature] = (),
    version: str = "1.0",
    title: str = "",
    description: str = "",
    ms_run_locations: Mapping[int, str] | None = None,
) -> WriteResult:
    """Write mzTab text to ``path``. See :func:`dataset_to_bytes` for
    the content-model details."""
    blob = dataset_to_bytes(
        identifications=identifications,
        quantifications=quantifications,
        provenance=provenance,
        features=features,
        version=version,
        title=title,
        description=description,
        ms_run_locations=ms_run_locations,
    )
    out = Path(path)
    out.write_bytes(blob)
    # Count row kinds for the return receipt.
    text = blob.decode("utf-8", errors="replace")
    n_psm = sum(1 for ln in text.splitlines() if ln.startswith("PSM\t"))
    n_prt = sum(1 for ln in text.splitlines() if ln.startswith("PRT\t"))
    n_sml = sum(1 for ln in text.splitlines() if ln.startswith("SML\t"))
    n_pep = sum(1 for ln in text.splitlines() if ln.startswith("PEP\t"))
    n_smf = sum(1 for ln in text.splitlines() if ln.startswith("SMF\t"))
    n_sme = sum(1 for ln in text.splitlines() if ln.startswith("SME\t"))
    return WriteResult(
        path=out, version=version,
        n_psm_rows=n_psm, n_prt_rows=n_prt, n_sml_rows=n_sml,
        n_pep_rows=n_pep, n_smf_rows=n_smf, n_sme_rows=n_sme,
    )


def dataset_to_bytes(
    *,
    identifications: Iterable[Identification] = (),
    quantifications: Iterable[Quantification] = (),
    provenance: Iterable[ProvenanceRecord] = (),
    features: Iterable[Feature] = (),
    version: str = "1.0",
    title: str = "",
    description: str = "",
    ms_run_locations: Mapping[int, str] | None = None,
) -> bytes:
    """Build the mzTab text blob.

    Dialect rules (per HANDOFF binding decision 47):

    * ``version="1.0"`` — proteomics. Emit PSM rows for each
      :class:`Identification` and PRT rows for each
      :class:`Quantification`. Assay indices are derived from the
      ``sample_ref`` column: the first unique ``sample_ref`` value
      becomes ``protein_abundance_assay[1]``, the second ``[2]``, etc.
    * ``version="2.0.0-M"`` — metabolomics. Emit SML rows that carry
      both the identification and the (per-sample) abundances for
      the same ``chemical_entity`` on one row.

    Any provenance records are threaded into the MTD section as
    ``software[N]`` lines. Run names referenced by
    ``Identification.run_name`` turn into ``MTD\\tms_run[N]-location``
    entries; callers can override this mapping with
    ``ms_run_locations``.
    """
    if version not in ("1.0", "2.0.0-M"):
        raise ValueError(
            f"unsupported mzTab version {version!r}; expected '1.0' or '2.0.0-M'"
        )

    idents = list(identifications)
    quants = list(quantifications)
    provs = list(provenance)
    feats = list(features)

    lines: list[str] = []
    # Run names referenced downstream (PSM/SML). Also seed from the
    # caller's override mapping so deterministic fixtures work.
    run_name_to_idx: dict[str, int] = {}
    if ms_run_locations:
        for idx, loc in ms_run_locations.items():
            # Each provided location gets a placeholder run name so the
            # MTD block emits every one the caller declared.
            run_name_to_idx[f"ms_run[{idx}]"] = idx

    def _run_index(run_name: str) -> int:
        if run_name not in run_name_to_idx:
            run_name_to_idx[run_name] = len(run_name_to_idx) + 1
        return run_name_to_idx[run_name]

    # Pre-resolve indices so MTD ms_run lines come out in stable order.
    for ident in idents:
        _run_index(ident.run_name)
    for feat in feats:
        _run_index(feat.run_name)

    # Sample indices for quantification assays.
    sample_to_idx: dict[str, int] = {}
    def _sample_index(s: str) -> int:
        if s not in sample_to_idx:
            sample_to_idx[s] = len(sample_to_idx) + 1
        return sample_to_idx[s]
    for q in quants:
        _sample_index(q.sample_ref or "sample")
    for feat in feats:
        for sample in feat.abundances.keys():
            _sample_index(sample or "sample")

    # ── MTD ───────────────────────────────────────────────────────────
    lines.append(f"MTD\tmzTab-version\t{version}")
    lines.append(f"MTD\tmzTab-mode\tSummary")
    lines.append(f"MTD\tmzTab-type\tIdentification")
    if version == "1.0":
        lines.append("MTD\tmzTab-ID\tttio-export")
    if title:
        lines.append(f"MTD\ttitle\t{_escape_tsv(title)}")
    if description:
        lines.append(f"MTD\tdescription\t{_escape_tsv(description)}")
    lines.append("MTD\tsoftware[1]\t[MS, MS:1000799, custom unreleased software tool, ttio]")

    # Declare every ms_run in the metadata section, keyed by the
    # stable index assigned above.
    # Also honour explicit location overrides.
    locations = dict(ms_run_locations or {})
    for run_name, idx in sorted(run_name_to_idx.items(), key=lambda kv: kv[1]):
        loc = locations.get(idx, f"file://{run_name}.mzML")
        lines.append(f"MTD\tms_run[{idx}]-location\t{loc}")

    # Assay / sample declarations for quantifications.
    # The reader parses ``assay[N]-sample_ref`` (proteomics) and
    # ``study_variable[N]-description`` (metabolomics) so it can
    # round-trip the original sample label.
    if quants or feats:
        for sample, idx in sorted(sample_to_idx.items(), key=lambda kv: kv[1]):
            lines.append(f"MTD\tassay[{idx}]-sample_ref\t{_escape_tsv(sample)}")
            lines.append(f"MTD\tassay[{idx}]-quantification_reagent\t"
                         f"[MS, MS:1002038, unlabeled sample, {_escape_tsv(sample)}]")
            lines.append(f"MTD\tassay[{idx}]-ms_run_ref\tms_run[1]")
            if version == "2.0.0-M":
                lines.append(f"MTD\tstudy_variable[{idx}]-description\t{_escape_tsv(sample)}")
                lines.append(f"MTD\tstudy_variable[{idx}]-assay_refs\tassay[{idx}]")

    # Threaded provenance (optional software entries past index 1).
    for i, rec in enumerate(provs, start=2):
        lines.append(f"MTD\tsoftware[{i}]\t[MS, MS:1001456, software analysis, "
                     f"{_escape_tsv(rec.software)}]")

    lines.append("")  # blank separator

    n_psm = n_prt = n_sml = n_pep = n_smf = n_sme = 0

    if version == "1.0":
        # ── PSH + PSM (proteomics identifications) ─────────────────────
        if idents:
            psh = [
                "PSH", "sequence", "PSM_ID", "accession", "unique",
                "database", "database_version", "search_engine",
                "search_engine_score[1]", "modifications", "retention_time",
                "charge", "exp_mass_to_charge", "calc_mass_to_charge",
                "spectra_ref", "pre", "post", "start", "end",
            ]
            lines.append("\t".join(psh))
            for i, ident in enumerate(idents, start=1):
                run_idx = _run_index(ident.run_name)
                evidence = list(ident.evidence_chain or [])
                search_engine = evidence[0] if evidence else "[MS, MS:1001083, mascot, ]"
                row = [
                    "PSM",
                    "",  # sequence (unknown at this layer)
                    str(i),
                    _escape_tsv(ident.chemical_entity),
                    "null",
                    "null",
                    "null",
                    _escape_tsv(search_engine),
                    f"{float(ident.confidence_score):g}",
                    "null",
                    "null",
                    "null",
                    "null",
                    "null",
                    f"ms_run[{run_idx}]:index={int(ident.spectrum_index)}",
                    "null",
                    "null",
                    "null",
                    "null",
                ]
                lines.append("\t".join(row))
                n_psm += 1
            lines.append("")

        # ── PRH + PRT (proteomics quantifications) ─────────────────────
        if quants:
            # Group quantifications by chemical_entity so each protein
            # has one PRT row with per-assay abundance columns.
            entity_quants: dict[str, dict[int, float]] = {}
            for q in quants:
                sample_idx = sample_to_idx[q.sample_ref or "sample"]
                entity_quants.setdefault(q.chemical_entity, {})[sample_idx] = q.abundance

            n_assays = len(sample_to_idx)
            prh = [
                "PRH", "accession", "description", "taxid", "species",
                "database", "database_version", "search_engine",
                "best_search_engine_score[1]",
                "ambiguity_members", "modifications", "protein_coverage",
            ]
            for k in range(1, n_assays + 1):
                prh.append(f"protein_abundance_assay[{k}]")
            lines.append("\t".join(prh))

            for entity, abundances in entity_quants.items():
                row = [
                    "PRT", _escape_tsv(entity),
                    "", "null", "null", "null", "null", "null", "null",
                    "null", "null", "null",
                ]
                for k in range(1, n_assays + 1):
                    row.append(f"{abundances[k]:g}" if k in abundances else "null")
                lines.append("\t".join(row))
                n_prt += 1
            lines.append("")

        # ── PEH + PEP (proteomics peptide features, M78) ───────────────
        if feats:
            n_assays = len(sample_to_idx)
            peh = [
                "PEH", "sequence", "accession", "unique",
                "database", "database_version", "search_engine",
                "best_search_engine_score[1]",
                "modifications", "retention_time",
                "charge", "mass_to_charge", "uri", "spectra_ref",
            ]
            for k in range(1, n_assays + 1):
                peh.append(f"peptide_abundance_assay[{k}]")
            lines.append("\t".join(peh))
            for feat in feats:
                run_idx = _run_index(feat.run_name)
                spectra_ref = feat.evidence_refs[0] if feat.evidence_refs else (
                    f"ms_run[{run_idx}]:index=0"
                )
                row = [
                    "PEP",
                    _escape_tsv(feat.chemical_entity),
                    "null",
                    "null",
                    "null", "null",
                    "null",
                    "null",
                    "null",
                    f"{float(feat.retention_time_seconds):g}",
                    str(int(feat.charge)),
                    f"{float(feat.exp_mass_to_charge):g}",
                    "null",
                    _escape_tsv(spectra_ref),
                ]
                for k in range(1, n_assays + 1):
                    sample = next(
                        (s for s, idx in sample_to_idx.items() if idx == k), None
                    )
                    v = feat.abundances.get(sample) if sample else None
                    row.append(f"{v:g}" if v is not None else "null")
                lines.append("\t".join(row))
                n_pep += 1
            lines.append("")

    else:  # 2.0.0-M metabolomics
        # ── SMH + SML ──────────────────────────────────────────────────
        entity_quants: dict[str, dict[int, float]] = {}
        for q in quants:
            sample_idx = sample_to_idx[q.sample_ref or "sample"]
            entity_quants.setdefault(q.chemical_entity, {})[sample_idx] = q.abundance

        # Also include identifications whose entity doesn't have a quant
        # record so every identification survives round-trip.
        for ident in idents:
            entity_quants.setdefault(ident.chemical_entity, {})

        if entity_quants:
            n_svs = len(sample_to_idx)
            smh = [
                "SMH", "SML_ID", "SMF_ID_REFS",
                "database_identifier", "chemical_formula",
                "smiles", "inchi", "chemical_name",
                "uri", "theoretical_neutral_mass",
                "adduct_ions", "reliability", "best_id_confidence_measure",
                "best_id_confidence_value",
            ]
            for k in range(1, n_svs + 1):
                smh.append(f"abundance_study_variable[{k}]")
                smh.append(f"abundance_variation_study_variable[{k}]")
            lines.append("\t".join(smh))

            # Lookup identifications by entity for confidence values.
            confidence_by_entity: dict[str, float] = {}
            for ident in idents:
                current = confidence_by_entity.get(ident.chemical_entity, 0.0)
                confidence_by_entity[ident.chemical_entity] = max(
                    current, float(ident.confidence_score)
                )

            for sml_id, (entity, abundances) in enumerate(entity_quants.items(),
                                                            start=1):
                confidence = confidence_by_entity.get(entity, 0.0)
                row = [
                    "SML", str(sml_id), "null",
                    _escape_tsv(entity),
                    "null", "null", "null", "null",
                    "null", "null", "null",
                    "1", "[MS, MS:1001090, null, ]",
                    f"{confidence:g}",
                ]
                for k in range(1, n_svs + 1):
                    row.append(f"{abundances[k]:g}" if k in abundances else "null")
                    row.append("null")  # variation placeholder
                lines.append("\t".join(row))
                n_sml += 1
            lines.append("")

        # ── SFH + SMF (small-molecule features, M78) ───────────────────
        if feats:
            n_assays = len(sample_to_idx)
            sfh = [
                "SFH", "SMF_ID", "SME_ID_REFS", "SME_ID_REF_ambiguity_code",
                "adduct_ion", "isotopomer",
                "exp_mass_to_charge", "charge",
                "retention_time_in_seconds",
                "retention_time_in_seconds_start",
                "retention_time_in_seconds_end",
            ]
            for k in range(1, n_assays + 1):
                sfh.append(f"abundance_assay[{k}]")
            lines.append("\t".join(sfh))
            for feat in feats:
                sme_refs = "|".join(feat.evidence_refs) if feat.evidence_refs else "null"
                row = [
                    "SMF",
                    _escape_tsv(feat.feature_id),
                    _escape_tsv(sme_refs),
                    "null",
                    _escape_tsv(feat.adduct_ion) if feat.adduct_ion else "null",
                    "null",
                    f"{float(feat.exp_mass_to_charge):g}",
                    str(int(feat.charge)),
                    f"{float(feat.retention_time_seconds):g}",
                    "null",
                    "null",
                ]
                for k in range(1, n_assays + 1):
                    sample = next(
                        (s for s, idx in sample_to_idx.items() if idx == k), None
                    )
                    v = feat.abundances.get(sample) if sample else None
                    row.append(f"{v:g}" if v is not None else "null")
                lines.append("\t".join(row))
                n_smf += 1
            lines.append("")

        # ── SEH + SME (small-molecule evidence, M78) ───────────────────
        # Only emit when features are also present; plain SML-only
        # exports keep their annotations in the SML section so the
        # round-trip doesn't double-count identifications.
        sme_idents = [i for i in idents if any(e.startswith("SME_ID=") for e in i.evidence_chain)]
        plain_idents = [i for i in idents if i not in sme_idents]
        if feats and (sme_idents or plain_idents):
            seh = [
                "SEH", "SME_ID", "evidence_input_id",
                "database_identifier", "chemical_formula",
                "smiles", "inchi", "chemical_name", "uri",
                "derivatized_form", "adduct_ion",
                "exp_mass_to_charge", "charge", "calc_mass_to_charge",
                "spectra_ref", "identification_method", "ms_level",
                "id_confidence_measure[1]", "rank",
            ]
            lines.append("\t".join(seh))
            emitted = 0

            def _sme_row(sme_id: str, ident: Identification) -> None:
                nonlocal emitted
                # Derive display name / formula from evidence if present.
                name = ""
                formula = ""
                for e in ident.evidence_chain:
                    if e.startswith("name="):
                        name = e[5:]
                    elif e.startswith("formula="):
                        formula = e[8:]
                rank = 1
                score = float(ident.confidence_score)
                if score > 0:
                    inferred = 1.0 / score if score <= 1.0 else 1.0
                    rank = max(1, round(inferred))
                spectra_ref = (
                    f"ms_run[{_run_index(ident.run_name)}]:index="
                    f"{int(ident.spectrum_index)}"
                )
                row = [
                    "SME", _escape_tsv(sme_id),
                    "null",
                    _escape_tsv(ident.chemical_entity),
                    _escape_tsv(formula) if formula else "null",
                    "null", "null",
                    _escape_tsv(name) if name else "null",
                    "null", "null", "null",
                    "null", "null", "null",
                    _escape_tsv(spectra_ref),
                    "null", "null",
                    f"{score:g}",
                    str(rank),
                ]
                lines.append("\t".join(row))
                emitted += 1

            for ident in sme_idents:
                sme_id = next(
                    (e[len("SME_ID="):] for e in ident.evidence_chain
                     if e.startswith("SME_ID=")),
                    f"sme_{emitted + 1}",
                )
                _sme_row(sme_id, ident)
            for ident in plain_idents:
                _sme_row(f"sme_{emitted + 1}", ident)

            n_sme = emitted
            lines.append("")

    # trailing newline after the last row for POSIX-clean files
    text = "\n".join(lines)
    if not text.endswith("\n"):
        text += "\n"
    return text.encode("utf-8")


# --------------------------------------------------------------------------- #
# Helpers.
# --------------------------------------------------------------------------- #

def _escape_tsv(value: str) -> str:
    """mzTab is TSV; replace tab + newline so a cell never breaks the
    row/column grammar. Keeps the format round-trip-friendly without
    introducing quoting (mzTab doesn't specify a quote convention)."""
    return (value or "").replace("\t", " ").replace("\r", " ").replace("\n", " ")
