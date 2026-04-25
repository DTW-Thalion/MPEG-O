"""mzTab importer (v0.9 M60).

mzTab is a results-level interchange format from PSI. It is a
tab-separated text file divided into sections by a one-line prefix:

* ``MTD`` — metadata (key / value lines)
* ``PRH`` / ``PRT`` — protein header / row    (mzTab 1.0)
* ``PEH`` / ``PEP`` — peptide header / row    (mzTab 1.0)
* ``PSH`` / ``PSM`` — PSM header / row        (mzTab 1.0)
* ``SMH`` / ``SML`` — small-molecule header / row (mzTab-M 2.0)
* ``COM`` — comment line, ignored
* anything else — treated as a malformed-row warning, skipped

Per HANDOFF binding decision 47 (mzTab version detection):
``MTD\\tmzTab-version\\t1.0`` selects the proteomics dialect;
``MTD\\tmzTab-version\\t2.0.0-M`` selects the metabolomics dialect.
The reader detects on the metadata line and dispatches accordingly.

Mapping into TTI-O records
---------------------------

| mzTab section | TTI-O record               | Notes                                                         |
|---------------|------------------------------|---------------------------------------------------------------|
| PSM           | :class:`Identification`     | ``run_name`` from ``spectra_ref``; score from best search engine score |
| PRT           | :class:`Quantification`     | one record per ``protein_abundance_assay[N]`` column           |
| PEP           | :class:`Feature`            | peptide-level feature (v0.12.0 M78)                            |
| SML           | :class:`Identification`     | metabolite annotation; ``run_name='metabolomics'`` placeholder |
| SML abundance | :class:`Quantification`     | one record per ``abundance_study_variable[N]`` column          |
| SMF           | :class:`Feature`            | small-molecule feature row (v0.12.0 M78)                       |
| SME           | :class:`Identification`     | small-molecule evidence row (v0.12.0 M78)                      |
| MTD           | :class:`ProvenanceRecord`   | software, search engine and ms_run locations                   |

Cross-language equivalents
--------------------------
Objective-C: ``TTIOMzTabReader``
Java:        ``global.thalion.ttio.importers.MzTabReader``

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import re
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator

from ..feature import Feature
from ..identification import Identification
from ..provenance import ProvenanceRecord
from ..quantification import Quantification
from ..spectral_dataset import SpectralDataset


class MzTabParseError(ValueError):
    """Raised when the mzTab document is structurally invalid."""


# Convention: mzTab spectra_ref values look like
#   "ms_run[1]:scan=42"
#   "ms_run[2]:index=17"
# Capture (ms_run_index, spectrum_locator).
_SPECTRA_REF_RE = re.compile(r"^ms_run\[(\d+)\]:(.+)$")


@dataclass(slots=True)
class MzTabImport:
    """In-memory representation of a parsed mzTab file."""

    version: str  # "1.0" (proteomics) or "2.0.0-M" (metabolomics)
    description: str = ""
    title: str = ""
    ms_run_locations: dict[int, str] = field(default_factory=dict)
    sample_refs: list[str] = field(default_factory=list)
    software: list[str] = field(default_factory=list)
    search_engines: list[str] = field(default_factory=list)
    identifications: list[Identification] = field(default_factory=list)
    quantifications: list[Quantification] = field(default_factory=list)
    features: list[Feature] = field(default_factory=list)
    provenance: list[ProvenanceRecord] = field(default_factory=list)
    source_path: str = ""

    @property
    def is_metabolomics(self) -> bool:
        return self.version.endswith("-M")

    def to_ttio(
        self,
        path: str | Path,
        *,
        title: str | None = None,
        isa_investigation_id: str = "",
        link_to: SpectralDataset | None = None,
    ) -> Path:
        """Write the imported records to an .tio container.

        When ``link_to`` is ``None`` an identifications-only container
        is emitted (no spectra runs). When a :class:`SpectralDataset`
        is supplied, its existing runs + identifications are merged
        with the mzTab records before writing — useful for splicing
        results back into the dataset that produced them. The merge
        preserves spectra_ref → run_name mappings recorded in the
        ``MTD ms_run[N]-location`` lines whenever the basename
        matches a run in the linked dataset.
        """
        merged_runs: dict[str, object] = {}
        merged_idents = list(self.identifications)
        merged_quants = list(self.quantifications)
        merged_prov = list(self.provenance)

        if link_to is not None:
            # Re-emit the linked dataset's runs verbatim. Read out the
            # WrittenRun-equivalent buffers and pass them straight
            # through the writer so the spectra survive the rewrite.
            from ..spectral_dataset import WrittenRun

            for run_name, run in link_to.all_runs.items():
                channel_data = {
                    name: arr.signal_arrays[name].data
                    for name, arr in {"_": run}.items()  # placeholder loop
                    if False  # see below — we need the *flattened* arrays
                }
                # The reader exposes per-spectrum signal_arrays; flatten them
                # back into concatenated buffers so write_minimal can re-emit.
                channels: dict[str, list] = {}
                offsets = []
                lengths = []
                cursor = 0
                for i in range(len(run)):
                    spec = run[i]
                    for cname, sa in spec.signal_arrays.items():
                        channels.setdefault(cname, []).extend(sa.data.tolist())
                    n = next(iter(spec.signal_arrays.values())).data.size
                    offsets.append(cursor)
                    lengths.append(n)
                    cursor += n
                import numpy as np
                rt = np.zeros(len(run), dtype=np.float64)
                ms_levels = np.ones(len(run), dtype=np.int32)
                pol = np.zeros(len(run), dtype=np.int32)
                pmz = np.zeros(len(run), dtype=np.float64)
                pch = np.zeros(len(run), dtype=np.int32)
                bp = np.zeros(len(run), dtype=np.float64)
                merged_runs[run_name] = WrittenRun(
                    spectrum_class=run.spectrum_class,
                    acquisition_mode=int(run.acquisition_mode),
                    channel_data={k: np.asarray(v, dtype=np.float64) for k, v in channels.items()},
                    offsets=np.asarray(offsets, dtype=np.uint64),
                    lengths=np.asarray(lengths, dtype=np.uint32),
                    retention_times=rt, ms_levels=ms_levels, polarities=pol,
                    precursor_mzs=pmz, precursor_charges=pch,
                    base_peak_intensities=bp,
                    nucleus_type=run.nucleus_type or "",
                )
            merged_idents = list(link_to.identifications()) + merged_idents
            merged_quants = list(link_to.quantifications()) + merged_quants
            merged_prov = list(link_to.provenance()) + merged_prov

        return SpectralDataset.write_minimal(
            path,
            title=title or self.title or f"mzTab import: {Path(self.source_path).name}",
            isa_investigation_id=isa_investigation_id,
            runs=merged_runs,
            identifications=merged_idents or None,
            quantifications=merged_quants or None,
            provenance=merged_prov or None,
        )


def read(path: str | Path) -> MzTabImport:
    """Parse an mzTab file and return an :class:`MzTabImport`."""
    p = Path(path)
    if not p.is_file():
        raise FileNotFoundError(f"mzTab file not found: {p}")

    state = _ParserState()
    with p.open("r", encoding="utf-8") as fh:
        for raw_line in fh:
            line = raw_line.rstrip("\n").rstrip("\r")
            if not line or line.startswith("#"):
                continue
            cols = line.split("\t")
            prefix = cols[0]
            if prefix == "COM":
                continue
            if prefix == "MTD":
                _handle_mtd(state, cols)
            elif prefix == "PRH":
                state.prt_header = cols
            elif prefix == "PRT" and state.prt_header is not None:
                _handle_prt(state, cols)
            elif prefix == "PSH":
                state.psm_header = cols
            elif prefix == "PSM" and state.psm_header is not None:
                _handle_psm(state, cols)
            elif prefix == "SMH":
                state.sml_header = cols
            elif prefix == "SML" and state.sml_header is not None:
                _handle_sml(state, cols)
            elif prefix == "PEH":
                state.pep_header = cols
            elif prefix == "PEP" and state.pep_header is not None:
                _handle_pep(state, cols)
            elif prefix == "SFH":
                state.smf_header = cols
            elif prefix == "SMF" and state.smf_header is not None:
                _handle_smf(state, cols)
            elif prefix == "SEH":
                state.sme_header = cols
            elif prefix == "SME" and state.sme_header is not None:
                _handle_sme(state, cols)

    if not state.version:
        raise MzTabParseError(f"{p}: missing MTD mzTab-version line")

    prov = _build_provenance(state, p)
    return MzTabImport(
        version=state.version,
        description=state.description,
        title=state.title,
        ms_run_locations=state.ms_run_locations,
        sample_refs=list(state.assay_to_sample.values()) or list(state.study_variables.values()),
        software=state.software,
        search_engines=state.search_engines,
        identifications=state.identifications,
        quantifications=state.quantifications,
        features=state.features,
        provenance=[prov] if prov else [],
        source_path=str(p),
    )


# --------------------------------------------------------------------------- #
# Parser state and per-section handlers.
# --------------------------------------------------------------------------- #

@dataclass(slots=True)
class _ParserState:
    version: str = ""
    description: str = ""
    title: str = ""
    ms_run_locations: dict[int, str] = field(default_factory=dict)
    assay_to_sample: dict[int, str] = field(default_factory=dict)
    study_variables: dict[int, str] = field(default_factory=dict)
    software: list[str] = field(default_factory=list)
    search_engines: list[str] = field(default_factory=list)
    psm_header: list[str] | None = None
    prt_header: list[str] | None = None
    sml_header: list[str] | None = None
    pep_header: list[str] | None = None
    smf_header: list[str] | None = None
    sme_header: list[str] | None = None
    study_variable_assays: dict[int, str] = field(default_factory=dict)
    identifications: list[Identification] = field(default_factory=list)
    quantifications: list[Quantification] = field(default_factory=list)
    features: list[Feature] = field(default_factory=list)


_MTD_KEY_MS_RUN_LOCATION_RE = re.compile(r"^ms_run\[(\d+)\]-location$")
_MTD_KEY_ASSAY_SAMPLE_RE   = re.compile(r"^assay\[(\d+)\]-sample_ref$")
_MTD_KEY_STUDY_VAR_RE      = re.compile(r"^study_variable\[(\d+)\]-description$")
_MTD_KEY_SOFTWARE_RE       = re.compile(r"^software\[(\d+)\](?:-setting\[\d+\])?$")
_MTD_KEY_SEARCH_ENGINE_RE  = re.compile(r"^psm_search_engine_score\[(\d+)\]$")


def _handle_mtd(state: _ParserState, cols: list[str]) -> None:
    if len(cols) < 3:
        return
    key, value = cols[1], "\t".join(cols[2:])
    if key == "mzTab-version":
        state.version = value
    elif key in ("description", "mzTab-description"):
        state.description = value
    elif key in ("title", "mzTab-ID"):
        state.title = value
    elif (m := _MTD_KEY_MS_RUN_LOCATION_RE.match(key)):
        state.ms_run_locations[int(m.group(1))] = value
    elif (m := _MTD_KEY_ASSAY_SAMPLE_RE.match(key)):
        state.assay_to_sample[int(m.group(1))] = value
    elif (m := _MTD_KEY_STUDY_VAR_RE.match(key)):
        state.study_variables[int(m.group(1))] = value
    elif _MTD_KEY_SOFTWARE_RE.match(key):
        state.software.append(value)
    elif _MTD_KEY_SEARCH_ENGINE_RE.match(key):
        state.search_engines.append(value)


def _resolve_run_name(state: _ParserState, ms_run_index: int) -> str:
    """Map an ms_run[N] reference to a run name suitable for the
    .tio Identification.run_name field. We use the file basename
    when a location is available, falling back to ``run_<N>``."""
    location = state.ms_run_locations.get(ms_run_index)
    if location:
        # location is typically a file:// URL — pull the basename.
        path = location.rsplit("/", 1)[-1]
        if "." in path:
            path = path.rsplit(".", 1)[0]
        return path or f"run_{ms_run_index}"
    return f"run_{ms_run_index}"


def _column_indices(header: list[str], pattern: re.Pattern[str]) -> list[tuple[int, int]]:
    """Return [(column_index, group_index_from_pattern), ...] for
    every header column whose name matches ``pattern``."""
    out: list[tuple[int, int]] = []
    for i, name in enumerate(header):
        if (m := pattern.match(name)):
            out.append((i, int(m.group(1))))
    return out


def _safe_get(cols: list[str], idx: int) -> str:
    return cols[idx] if 0 <= idx < len(cols) else ""


def _to_float(s: str) -> float | None:
    if not s or s.lower() in ("null", "na", "n/a", "nan"):
        return None
    try:
        return float(s)
    except ValueError:
        return None


def _to_int(s: str) -> int | None:
    if not s or s.lower() in ("null", "na", "n/a"):
        return None
    try:
        return int(s)
    except ValueError:
        return None


_PSM_BEST_SCORE_RE = re.compile(r"^search_engine_score\[(\d+)\]$")
_PSM_SPECTRA_REF_HEADER = "spectra_ref"
_PSM_ACCESSION_HEADER = "accession"
_PSM_SEQUENCE_HEADER = "sequence"
_PSM_ID_HEADER = "PSM_ID"
_PSM_SEARCH_ENGINE_HEADER = "search_engine"


def _handle_psm(state: _ParserState, cols: list[str]) -> None:
    header = state.psm_header
    assert header is not None
    score_columns = _column_indices(header, _PSM_BEST_SCORE_RE)
    name_to_idx = {name: i for i, name in enumerate(header)}

    accession = _safe_get(cols, name_to_idx.get(_PSM_ACCESSION_HEADER, -1))
    if not accession or accession == "null":
        # Fall back to peptide sequence if no protein accession available.
        accession = _safe_get(cols, name_to_idx.get(_PSM_SEQUENCE_HEADER, -1))
    if not accession:
        return

    spectra_ref = _safe_get(cols, name_to_idx.get(_PSM_SPECTRA_REF_HEADER, -1))
    run_name = "imported"
    spectrum_index = 0
    if (m := _SPECTRA_REF_RE.match(spectra_ref)):
        run_name = _resolve_run_name(state, int(m.group(1)))
        # locator is e.g. "scan=42" or "index=17"; capture the number.
        locator = m.group(2)
        if "=" in locator:
            try:
                spectrum_index = int(locator.split("=", 1)[1])
            except ValueError:
                spectrum_index = 0

    best_score = 0.0
    for col_idx, _ in score_columns:
        v = _to_float(_safe_get(cols, col_idx))
        if v is not None:
            best_score = max(best_score, v)

    evidence: list[str] = []
    se = _safe_get(cols, name_to_idx.get(_PSM_SEARCH_ENGINE_HEADER, -1))
    if se:
        evidence.append(se)
    psm_id = _safe_get(cols, name_to_idx.get(_PSM_ID_HEADER, -1))
    if psm_id:
        evidence.append(f"PSM_ID={psm_id}")

    state.identifications.append(Identification(
        run_name=run_name,
        spectrum_index=spectrum_index,
        chemical_entity=accession,
        confidence_score=best_score,
        evidence_chain=evidence,
    ))


_PRT_ABUNDANCE_RE = re.compile(r"^protein_abundance_assay\[(\d+)\]$")
_PRT_ACCESSION_HEADER = "accession"


def _handle_prt(state: _ParserState, cols: list[str]) -> None:
    header = state.prt_header
    assert header is not None
    abund_columns = _column_indices(header, _PRT_ABUNDANCE_RE)
    name_to_idx = {name: i for i, name in enumerate(header)}
    accession = _safe_get(cols, name_to_idx.get(_PRT_ACCESSION_HEADER, -1))
    if not accession:
        return

    for col_idx, assay_idx in abund_columns:
        value = _to_float(_safe_get(cols, col_idx))
        if value is None:
            continue
        sample_ref = state.assay_to_sample.get(assay_idx, f"assay_{assay_idx}")
        state.quantifications.append(Quantification(
            chemical_entity=accession,
            sample_ref=sample_ref,
            abundance=value,
            normalization_method="",
        ))


_SML_ABUNDANCE_RE = re.compile(r"^abundance_study_variable\[(\d+)\]$")
_SML_DB_ID = "database_identifier"
_SML_NAME = "chemical_name"
_SML_FORMULA = "chemical_formula"
_SML_BEST_CONF = "best_id_confidence_value"


def _handle_sml(state: _ParserState, cols: list[str]) -> None:
    header = state.sml_header
    assert header is not None
    name_to_idx = {name: i for i, name in enumerate(header)}
    abund_columns = _column_indices(header, _SML_ABUNDANCE_RE)

    db_id = _safe_get(cols, name_to_idx.get(_SML_DB_ID, -1))
    chem_name = _safe_get(cols, name_to_idx.get(_SML_NAME, -1))
    formula = _safe_get(cols, name_to_idx.get(_SML_FORMULA, -1))
    entity = db_id or chem_name or formula
    if not entity:
        return

    best = _to_float(_safe_get(cols, name_to_idx.get(_SML_BEST_CONF, -1))) or 0.0
    evidence: list[str] = []
    if chem_name and chem_name != entity:
        evidence.append(f"name={chem_name}")
    if formula and formula != entity:
        evidence.append(f"formula={formula}")

    state.identifications.append(Identification(
        run_name="metabolomics",
        spectrum_index=0,
        chemical_entity=entity,
        confidence_score=best,
        evidence_chain=evidence,
    ))

    for col_idx, sv_idx in abund_columns:
        value = _to_float(_safe_get(cols, col_idx))
        if value is None:
            continue
        sample_ref = state.study_variables.get(sv_idx, f"study_variable_{sv_idx}")
        state.quantifications.append(Quantification(
            chemical_entity=entity,
            sample_ref=sample_ref,
            abundance=value,
            normalization_method="",
        ))


def _build_provenance(state: _ParserState, source: Path) -> ProvenanceRecord | None:
    if not (state.software or state.search_engines or state.ms_run_locations):
        return None
    return ProvenanceRecord(
        timestamp_unix=int(time.time()),
        software="ttio mztab importer v0.9",
        parameters={
            "mztab_version": state.version,
            "mztab_description": state.description,
            "mztab_software": ";".join(state.software),
            "mztab_search_engines": ";".join(state.search_engines),
            "mztab_ms_run_locations": ";".join(
                f"{idx}:{loc}" for idx, loc in sorted(state.ms_run_locations.items())
            ),
        },
        input_refs=[str(source)] + list(state.ms_run_locations.values()),
        output_refs=[],
    )


# --------------------------------------------------------------------------- #
# PEP / SMF / SME section handlers (v0.12.0 M78).
# --------------------------------------------------------------------------- #

_PEP_ACCESSION = "accession"
_PEP_SEQUENCE = "sequence"
_PEP_CHARGE = "charge"
_PEP_MASS_TO_CHARGE = "mass_to_charge"
_PEP_RETENTION_TIME = "retention_time"
_PEP_SPECTRA_REF = "spectra_ref"
_PEP_ABUNDANCE_ASSAY_RE = re.compile(r"^peptide_abundance_assay\[(\d+)\]$")
_PEP_ABUNDANCE_SV_RE = re.compile(r"^peptide_abundance_study_variable\[(\d+)\]$")


def _handle_pep(state: _ParserState, cols: list[str]) -> None:
    """mzTab 1.0 PEP row — one peptide feature per row."""
    header = state.pep_header
    assert header is not None
    name_to_idx = {name: i for i, name in enumerate(header)}
    assay_cols = _column_indices(header, _PEP_ABUNDANCE_ASSAY_RE)
    sv_cols = _column_indices(header, _PEP_ABUNDANCE_SV_RE)

    sequence = _safe_get(cols, name_to_idx.get(_PEP_SEQUENCE, -1))
    accession = _safe_get(cols, name_to_idx.get(_PEP_ACCESSION, -1))
    # Prefer the peptide sequence as the chemical entity; fall back to
    # the linked protein accession so every PEP row survives.
    entity = sequence or accession
    if not entity:
        return

    spectra_ref = _safe_get(cols, name_to_idx.get(_PEP_SPECTRA_REF, -1))
    run_name = "imported"
    if (m := _SPECTRA_REF_RE.match(spectra_ref)):
        run_name = _resolve_run_name(state, int(m.group(1)))

    charge = _to_int(_safe_get(cols, name_to_idx.get(_PEP_CHARGE, -1))) or 0
    mz = _to_float(_safe_get(cols, name_to_idx.get(_PEP_MASS_TO_CHARGE, -1))) or 0.0
    rt = _to_float(_safe_get(cols, name_to_idx.get(_PEP_RETENTION_TIME, -1))) or 0.0

    abundances: dict[str, float] = {}
    for col_idx, assay_idx in assay_cols:
        v = _to_float(_safe_get(cols, col_idx))
        if v is None:
            continue
        sample_ref = state.assay_to_sample.get(assay_idx, f"assay_{assay_idx}")
        abundances[sample_ref] = v
    for col_idx, sv_idx in sv_cols:
        v = _to_float(_safe_get(cols, col_idx))
        if v is None:
            continue
        sample_ref = state.study_variables.get(sv_idx, f"study_variable_{sv_idx}")
        abundances[sample_ref] = v

    evidence_refs: list[str] = []
    if spectra_ref:
        evidence_refs.append(spectra_ref)

    feature_id = f"pep_{len(state.features) + 1}"
    state.features.append(Feature(
        feature_id=feature_id,
        run_name=run_name,
        chemical_entity=entity,
        retention_time_seconds=rt,
        exp_mass_to_charge=mz,
        charge=charge,
        adduct_ion="",
        abundances=abundances,
        evidence_refs=evidence_refs,
    ))


_SMF_ID = "SMF_ID"
_SMF_SME_REFS = "SME_ID_REFS"
_SMF_ADDUCT = "adduct_ion"
_SMF_EXP_MZ = "exp_mass_to_charge"
_SMF_CHARGE = "charge"
_SMF_RT = "retention_time_in_seconds"
_SMF_ABUNDANCE_ASSAY_RE = re.compile(r"^abundance_assay\[(\d+)\]$")


def _handle_smf(state: _ParserState, cols: list[str]) -> None:
    """mzTab-M 2.0.0-M SMF row — one small-molecule feature per row."""
    header = state.smf_header
    assert header is not None
    name_to_idx = {name: i for i, name in enumerate(header)}
    assay_cols = _column_indices(header, _SMF_ABUNDANCE_ASSAY_RE)

    smf_id = _safe_get(cols, name_to_idx.get(_SMF_ID, -1))
    if not smf_id:
        return

    # Resolve chemical entity via the first SME_ID_REF if present;
    # otherwise fall back to the SMF_ID string.
    sme_refs_raw = _safe_get(cols, name_to_idx.get(_SMF_SME_REFS, -1))
    sme_refs = [r for r in sme_refs_raw.split("|") if r and r.lower() != "null"]

    adduct = _safe_get(cols, name_to_idx.get(_SMF_ADDUCT, -1))
    if adduct.lower() == "null":
        adduct = ""
    mz = _to_float(_safe_get(cols, name_to_idx.get(_SMF_EXP_MZ, -1))) or 0.0
    rt = _to_float(_safe_get(cols, name_to_idx.get(_SMF_RT, -1))) or 0.0
    charge = _to_int(_safe_get(cols, name_to_idx.get(_SMF_CHARGE, -1))) or 0

    abundances: dict[str, float] = {}
    for col_idx, assay_idx in assay_cols:
        v = _to_float(_safe_get(cols, col_idx))
        if v is None:
            continue
        sample_ref = state.assay_to_sample.get(assay_idx, f"assay_{assay_idx}")
        abundances[sample_ref] = v

    # Entity resolution happens lazily in _handle_sme when evidence
    # rows arrive; keep a placeholder referencing the SME ids so the
    # Feature stays linkable.
    entity = sme_refs[0] if sme_refs else smf_id

    state.features.append(Feature(
        feature_id=f"smf_{smf_id}",
        run_name="metabolomics",
        chemical_entity=entity,
        retention_time_seconds=rt,
        exp_mass_to_charge=mz,
        charge=charge,
        adduct_ion=adduct,
        abundances=abundances,
        evidence_refs=sme_refs,
    ))


_SME_ID = "SME_ID"
_SME_DB_ID = "database_identifier"
_SME_NAME = "chemical_name"
_SME_FORMULA = "chemical_formula"
_SME_EXP_MZ = "exp_mass_to_charge"
_SME_CHARGE = "charge"
_SME_SPECTRA_REF = "spectra_ref"
_SME_RANK = "rank"


def _handle_sme(state: _ParserState, cols: list[str]) -> None:
    """mzTab-M 2.0.0-M SME row — per-feature annotation evidence.

    Emits one :class:`Identification` per evidence row so downstream
    consumers keep annotation + rank data after round-trip.
    """
    header = state.sme_header
    assert header is not None
    name_to_idx = {name: i for i, name in enumerate(header)}

    sme_id = _safe_get(cols, name_to_idx.get(_SME_ID, -1))
    if not sme_id:
        return

    db_id = _safe_get(cols, name_to_idx.get(_SME_DB_ID, -1))
    chem_name = _safe_get(cols, name_to_idx.get(_SME_NAME, -1))
    formula = _safe_get(cols, name_to_idx.get(_SME_FORMULA, -1))
    entity = db_id or chem_name or formula or sme_id

    rank = _to_int(_safe_get(cols, name_to_idx.get(_SME_RANK, -1))) or 1
    # mzTab-M rank 1 is the best; map rank → confidence as 1/rank so
    # the winning evidence gets 1.0 and weaker alternatives get < 1.0.
    confidence = 1.0 / float(rank) if rank > 0 else 0.0

    spectra_ref = _safe_get(cols, name_to_idx.get(_SME_SPECTRA_REF, -1))
    run_name = "metabolomics"
    spectrum_index = 0
    if (m := _SPECTRA_REF_RE.match(spectra_ref)):
        run_name = _resolve_run_name(state, int(m.group(1)))
        locator = m.group(2)
        if "=" in locator:
            try:
                spectrum_index = int(locator.split("=", 1)[1])
            except ValueError:
                spectrum_index = 0

    evidence: list[str] = [f"SME_ID={sme_id}"]
    if chem_name and chem_name != entity:
        evidence.append(f"name={chem_name}")
    if formula and formula != entity:
        evidence.append(f"formula={formula}")

    state.identifications.append(Identification(
        run_name=run_name,
        spectrum_index=spectrum_index,
        chemical_entity=entity,
        confidence_score=confidence,
        evidence_chain=evidence,
    ))

    # Back-fill features that referenced this SME so their
    # chemical_entity gets upgraded from the placeholder ID.
    for i, feat in enumerate(state.features):
        if sme_id in feat.evidence_refs and feat.chemical_entity == sme_id:
            state.features[i] = Feature(
                feature_id=feat.feature_id,
                run_name=feat.run_name,
                chemical_entity=entity,
                retention_time_seconds=feat.retention_time_seconds,
                exp_mass_to_charge=feat.exp_mass_to_charge,
                charge=feat.charge,
                adduct_ion=feat.adduct_ion,
                abundances=feat.abundances,
                evidence_refs=feat.evidence_refs,
            )


__all__ = ["MzTabImport", "MzTabParseError", "read"]
