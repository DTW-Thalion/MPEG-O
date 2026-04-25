"""Generate the M78 mzTab features conformance fixture.

Two files: ``proteomics.mztab`` (PEH/PEP, mzTab 1.0) and
``metabolomics.mztab`` (SFH/SMF + SEH/SME + SMH/SML, mzTab-M 2.0.0-M).

The generator is deterministic — no RNG — so re-running this script
on any platform produces byte-identical fixtures.

Usage::

    cd conformance/mztab_features
    python generate.py
"""
from __future__ import annotations

from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(REPO / "python" / "src"))

from ttio import Feature, Identification, Quantification  # noqa: E402
from ttio.exporters import mztab  # noqa: E402


def proteomics_payload():
    idents = [
        Identification(
            run_name="run_a", spectrum_index=42,
            chemical_entity="P12345",
            confidence_score=78.5,
            evidence_chain=["[MS, MS:1001083, mascot, ]", "PSM_ID=1"],
        ),
    ]
    quants = [
        Quantification(chemical_entity="P12345", sample_ref="S1", abundance=1.0e6),
        Quantification(chemical_entity="P12345", sample_ref="S2", abundance=2.5e6),
    ]
    feats = [
        Feature(
            feature_id="pep_1",
            run_name="run_a",
            chemical_entity="AAAAPEPTIDER",
            retention_time_seconds=302.5,
            exp_mass_to_charge=615.3291,
            charge=2,
            abundances={"S1": 1.5e6, "S2": 2.25e6},
            evidence_refs=["ms_run[1]:scan=42"],
        ),
        Feature(
            feature_id="pep_2",
            run_name="run_a",
            chemical_entity="QWERTYK",
            retention_time_seconds=450.1,
            exp_mass_to_charge=412.2012,
            charge=1,
            abundances={"S1": 8.0e5},
            evidence_refs=["ms_run[1]:scan=51"],
        ),
    ]
    return idents, quants, feats


def metabolomics_payload():
    feats = [
        Feature(
            feature_id="smf_1",
            run_name="metabolomics",
            chemical_entity="CHEBI:15377",
            retention_time_seconds=85.3,
            exp_mass_to_charge=181.0707,
            charge=1,
            adduct_ion="[M+H]1+",
            abundances={"sample_a": 1.2e4, "sample_b": 1.1e4},
            evidence_refs=["sme_1"],
        ),
        Feature(
            feature_id="smf_2",
            run_name="metabolomics",
            chemical_entity="CHEBI:16865",
            retention_time_seconds=210.9,
            exp_mass_to_charge=147.0532,
            charge=1,
            adduct_ion="[M+Na]1+",
            abundances={"sample_a": 3.3e3},
            evidence_refs=["sme_2"],
        ),
    ]
    idents = [
        Identification(
            run_name="metabolomics", spectrum_index=0,
            chemical_entity="CHEBI:15377",
            confidence_score=1.0,
            evidence_chain=["SME_ID=sme_1", "name=glucose", "formula=C6H12O6"],
        ),
        Identification(
            run_name="metabolomics", spectrum_index=0,
            chemical_entity="CHEBI:16865",
            confidence_score=0.5,
            evidence_chain=["SME_ID=sme_2", "name=glutamate"],
        ),
    ]
    return idents, feats


def main() -> None:
    p_idents, p_quants, p_feats = proteomics_payload()
    mztab.write(
        HERE / "proteomics.mztab",
        identifications=p_idents,
        quantifications=p_quants,
        features=p_feats,
        version="1.0",
        title="M78 conformance (proteomics)",
    )
    m_idents, m_feats = metabolomics_payload()
    mztab.write(
        HERE / "metabolomics.mztab",
        identifications=m_idents,
        features=m_feats,
        version="2.0.0-M",
        title="M78 conformance (metabolomics)",
    )
    print(f"wrote {HERE}/proteomics.mztab")
    print(f"wrote {HERE}/metabolomics.mztab")


if __name__ == "__main__":
    main()
