"""``Feature`` — detected peak / peptide-feature / small-molecule feature record."""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True, slots=True)
class Feature:
    """A feature-level observation: a peak detected in one run, with
    retention time + m/z + charge + per-sample abundances.

    ``Feature`` sits between :class:`Identification` (spectrum-level)
    and :class:`Quantification` (entity-level): it is the row-level
    record required by mzTab's PEP section (peptide-level
    quantification in the 1.0 proteomics dialect) and by mzTab-M's
    SMF/SME sections (small-molecule feature + evidence in the
    2.0.0-M metabolomics dialect).

    Parameters
    ----------
    feature_id : str
        Identifier unique within a single file (typically the mzTab
        ``PEP_ID`` or ``SMF_ID`` value as a string).
    run_name : str
        Acquisition run this feature was detected in.
    chemical_entity : str
        Peptide sequence, CHEBI accession, chemical name, or formula
        — whatever the source file assigned.
    retention_time_seconds : float
        Apex retention time in seconds. ``0.0`` if the source did not
        record one.
    exp_mass_to_charge : float
        Experimental (observed) precursor m/z. ``0.0`` if unavailable.
    charge : int
        Precursor charge state. ``0`` if unknown.
    adduct_ion : str, default ""
        Adduct annotation (e.g. ``"[M+H]1+"``). Empty for proteomics
        peptide features.
    abundances : dict[str, float], default {}
        Per-sample abundances keyed by sample/study-variable label.
    evidence_refs : list[str], default []
        References that support this feature — mzTab-M ``SME_ID``
        values for metabolomics, ``spectra_ref`` entries for
        proteomics.

    Notes
    -----
    API status: Provisional (v0.12.0 M78).

    Cross-language equivalents
    --------------------------
    Objective-C: ``MPGOFeature`` · Java:
    ``com.dtwthalion.mpgo.Feature``.
    """

    feature_id: str
    run_name: str
    chemical_entity: str
    retention_time_seconds: float = 0.0
    exp_mass_to_charge: float = 0.0
    charge: int = 0
    adduct_ion: str = ""
    abundances: dict[str, float] = field(default_factory=dict)
    evidence_refs: list[str] = field(default_factory=list)
