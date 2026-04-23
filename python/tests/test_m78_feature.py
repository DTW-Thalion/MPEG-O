"""M78: Feature value class + mzTab PEH/PEP + SFH/SMF/SEH/SME round-trip."""
from __future__ import annotations

from pathlib import Path

import pytest

from mpeg_o import Feature
from mpeg_o.exporters import mztab as mztab_writer
from mpeg_o.importers import mztab as mztab_reader
from mpeg_o.identification import Identification
from mpeg_o.quantification import Quantification


# --------------------------------------------------------------------------- #
# Value-class invariants.
# --------------------------------------------------------------------------- #

def test_feature_defaults_are_empty_containers():
    feat = Feature(
        feature_id="f1",
        run_name="run_a",
        chemical_entity="PEPTIDER",
    )
    assert feat.retention_time_seconds == 0.0
    assert feat.exp_mass_to_charge == 0.0
    assert feat.charge == 0
    assert feat.adduct_ion == ""
    assert feat.abundances == {}
    assert feat.evidence_refs == []


def test_feature_is_frozen():
    feat = Feature(feature_id="f1", run_name="r", chemical_entity="X")
    with pytest.raises((AttributeError, TypeError)):
        feat.charge = 3  # type: ignore[misc]


def test_feature_equality():
    a = Feature(
        feature_id="f1", run_name="r", chemical_entity="X",
        charge=2, exp_mass_to_charge=500.25,
        abundances={"s1": 1.0}, evidence_refs=["e1"],
    )
    b = Feature(
        feature_id="f1", run_name="r", chemical_entity="X",
        charge=2, exp_mass_to_charge=500.25,
        abundances={"s1": 1.0}, evidence_refs=["e1"],
    )
    assert a == b


def test_feature_exposed_from_package_root():
    import mpeg_o
    assert hasattr(mpeg_o, "Feature")
    assert "Feature" in mpeg_o.__all__


# --------------------------------------------------------------------------- #
# mzTab-P 1.0 — PEH/PEP round-trip.
# --------------------------------------------------------------------------- #

def _mztab_p_feats() -> list[Feature]:
    return [
        Feature(
            feature_id="pep_1",
            run_name="run_a",
            chemical_entity="AAAAPEPTIDER",
            retention_time_seconds=302.5,
            exp_mass_to_charge=615.3291,
            charge=2,
            abundances={"sample_1": 1.5e6, "sample_2": 2.25e6},
            evidence_refs=["ms_run[1]:scan=42"],
        ),
        Feature(
            feature_id="pep_2",
            run_name="run_a",
            chemical_entity="QWERTYK",
            retention_time_seconds=450.1,
            exp_mass_to_charge=412.2012,
            charge=1,
            abundances={"sample_1": 8.0e5},
            evidence_refs=["ms_run[1]:scan=51"],
        ),
    ]


def test_pep_round_trip_preserves_feature_fields(tmp_path: Path) -> None:
    feats = _mztab_p_feats()
    out = tmp_path / "pep.mztab"
    result = mztab_writer.write(
        out,
        features=feats,
        version="1.0",
        title="M78 PEP round-trip",
    )
    assert result.n_pep_rows == 2
    assert result.n_psm_rows == 0

    parsed = mztab_reader.read(out)
    assert parsed.version == "1.0"
    assert len(parsed.features) == 2
    got = {f.chemical_entity: f for f in parsed.features}
    assert got["AAAAPEPTIDER"].charge == 2
    assert got["AAAAPEPTIDER"].exp_mass_to_charge == pytest.approx(615.3291, rel=1e-4)
    assert got["AAAAPEPTIDER"].retention_time_seconds == pytest.approx(302.5)
    # Abundances re-keyed by the assay sample names emitted in MTD.
    values = sorted(got["AAAAPEPTIDER"].abundances.values())
    assert values[0] == pytest.approx(1.5e6, rel=1e-4)
    assert values[1] == pytest.approx(2.25e6, rel=1e-4)


def test_pep_writer_adds_peh_header(tmp_path: Path) -> None:
    out = tmp_path / "pep.mztab"
    mztab_writer.write(out, features=_mztab_p_feats(), version="1.0")
    text = out.read_text(encoding="utf-8")
    lines = text.splitlines()
    assert any(ln.startswith("PEH\t") for ln in lines)
    peh = next(ln for ln in lines if ln.startswith("PEH\t")).split("\t")
    # Required columns.
    for col in ("sequence", "charge", "mass_to_charge",
                "retention_time", "spectra_ref"):
        assert col in peh
    # Abundance columns keyed per assay.
    assert any(c.startswith("peptide_abundance_assay[") for c in peh)


def test_empty_features_emits_no_peh(tmp_path: Path) -> None:
    out = tmp_path / "pep.mztab"
    mztab_writer.write(
        out,
        identifications=[Identification(
            run_name="run_a", spectrum_index=0,
            chemical_entity="PROT_X", confidence_score=0.9,
        )],
        version="1.0",
    )
    text = out.read_text(encoding="utf-8")
    assert "PEH\t" not in text
    assert "PEP\t" not in text


# --------------------------------------------------------------------------- #
# mzTab-M 2.0.0-M — SFH/SMF + SEH/SME round-trip.
# --------------------------------------------------------------------------- #

def _mztab_m_payload() -> tuple[list[Feature], list[Identification]]:
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
    return feats, idents


def test_smf_sme_round_trip_preserves_feature_fields(tmp_path: Path) -> None:
    feats, idents = _mztab_m_payload()
    out = tmp_path / "m.mztab"
    result = mztab_writer.write(
        out,
        identifications=idents,
        features=feats,
        version="2.0.0-M",
    )
    assert result.n_smf_rows == 2
    assert result.n_sme_rows == 2

    parsed = mztab_reader.read(out)
    assert parsed.version == "2.0.0-M"
    assert len(parsed.features) == 2

    by_adduct = {f.adduct_ion: f for f in parsed.features}
    assert "[M+H]1+" in by_adduct
    glucose_feat = by_adduct["[M+H]1+"]
    assert glucose_feat.exp_mass_to_charge == pytest.approx(181.0707, rel=1e-4)
    assert glucose_feat.retention_time_seconds == pytest.approx(85.3)
    assert glucose_feat.charge == 1
    # Evidence refs carry the SME_ID values through the round-trip so
    # back-fill can upgrade the chemical_entity on reparse.
    assert "sme_1" in glucose_feat.evidence_refs
    # After SME parsing, the feature's chemical_entity resolves to the
    # identification's chemical_entity.
    assert glucose_feat.chemical_entity == "CHEBI:15377"


def test_smf_writer_adds_sfh_header(tmp_path: Path) -> None:
    feats, idents = _mztab_m_payload()
    out = tmp_path / "m.mztab"
    mztab_writer.write(
        out, identifications=idents, features=feats, version="2.0.0-M",
    )
    text = out.read_text(encoding="utf-8")
    lines = text.splitlines()
    assert any(ln.startswith("SFH\t") for ln in lines)
    assert any(ln.startswith("SEH\t") for ln in lines)
    sfh = next(ln for ln in lines if ln.startswith("SFH\t")).split("\t")
    for col in ("SMF_ID", "adduct_ion", "exp_mass_to_charge", "charge",
                "retention_time_in_seconds"):
        assert col in sfh


def test_sme_emits_rank_and_confidence(tmp_path: Path) -> None:
    feats, idents = _mztab_m_payload()
    out = tmp_path / "m.mztab"
    mztab_writer.write(
        out, identifications=idents, features=feats, version="2.0.0-M",
    )
    text = out.read_text(encoding="utf-8")
    sme_rows = [ln for ln in text.splitlines() if ln.startswith("SME\t")]
    assert len(sme_rows) == 2
    # rank is the last column; for confidence 1.0 rank==1, for 0.5 rank==2.
    ranks = sorted(int(r.split("\t")[-1]) for r in sme_rows)
    assert ranks == [1, 2]


def test_empty_features_metabolomics_omits_sfh(tmp_path: Path) -> None:
    out = tmp_path / "m.mztab"
    mztab_writer.write(
        out,
        identifications=[Identification(
            run_name="metabolomics", spectrum_index=0,
            chemical_entity="CHEBI:15377", confidence_score=0.9,
        )],
        quantifications=[Quantification(
            chemical_entity="CHEBI:15377", sample_ref="sample_a",
            abundance=1.0e4,
        )],
        version="2.0.0-M",
    )
    text = out.read_text(encoding="utf-8")
    assert "SFH\t" not in text
    assert "SMF\t" not in text
    assert "SML\t" in text
