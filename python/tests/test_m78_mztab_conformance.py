"""M78 cross-language conformance: parse the shared fixtures and
verify feature + identification content survives unchanged.

Companion Java / ObjC suites read the same fixtures under
``conformance/mztab_features/`` and assert the same invariants.
"""
from __future__ import annotations

from pathlib import Path

import pytest

from mpeg_o.importers import mztab

CONFORMANCE_DIR = Path(__file__).resolve().parents[2] / "conformance" / "mztab_features"


@pytest.fixture
def proteomics_fixture() -> Path:
    path = CONFORMANCE_DIR / "proteomics.mztab"
    if not path.is_file():
        pytest.skip(f"fixture not present: {path}")
    return path


@pytest.fixture
def metabolomics_fixture() -> Path:
    path = CONFORMANCE_DIR / "metabolomics.mztab"
    if not path.is_file():
        pytest.skip(f"fixture not present: {path}")
    return path


def test_proteomics_fixture_has_two_peptide_features(proteomics_fixture: Path) -> None:
    parsed = mztab.read(proteomics_fixture)
    assert parsed.version == "1.0"
    assert len(parsed.features) == 2
    seq_to_feat = {f.chemical_entity: f for f in parsed.features}
    assert "AAAAPEPTIDER" in seq_to_feat
    assert "QWERTYK" in seq_to_feat
    assert seq_to_feat["AAAAPEPTIDER"].charge == 2
    assert seq_to_feat["AAAAPEPTIDER"].exp_mass_to_charge == pytest.approx(615.329, rel=1e-3)
    assert seq_to_feat["QWERTYK"].charge == 1


def test_metabolomics_fixture_has_two_small_molecule_features(
    metabolomics_fixture: Path,
) -> None:
    parsed = mztab.read(metabolomics_fixture)
    assert parsed.version == "2.0.0-M"
    assert len(parsed.features) == 2
    by_adduct = {f.adduct_ion: f for f in parsed.features}
    assert "[M+H]1+" in by_adduct
    assert "[M+Na]1+" in by_adduct
    # After SME back-fill, the chemical entity resolves to the SME's
    # database_identifier rather than the bare SME_ID.
    assert by_adduct["[M+H]1+"].chemical_entity == "CHEBI:15377"
    assert by_adduct["[M+Na]1+"].chemical_entity == "CHEBI:16865"


def test_metabolomics_fixture_sme_rows_preserve_confidence(
    metabolomics_fixture: Path,
) -> None:
    parsed = mztab.read(metabolomics_fixture)
    sme_idents = [i for i in parsed.identifications
                  if any(e.startswith("SME_ID=") for e in i.evidence_chain)]
    assert len(sme_idents) == 2
    # rank 1 → confidence 1.0; rank 2 → 0.5. Ordering by confidence
    # descending gives the winning annotation first.
    confs = sorted([i.confidence_score for i in sme_idents], reverse=True)
    assert confs[0] == pytest.approx(1.0)
    assert confs[1] == pytest.approx(0.5)
