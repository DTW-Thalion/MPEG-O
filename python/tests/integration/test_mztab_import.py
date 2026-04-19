"""mzTab importer integration tests (v0.9 M60).

Covers HANDOFF M60 acceptance:

* mzTab 1.0 (proteomics) PSM count, scores, spectrum refs match source.
* mzTab-M 2.0 (metabolomics) metabolite IDs match source.
* Quantification values round-trip via PRT abundance and SML
  abundance_study_variable columns.
* Provenance records created for the import operation (software,
  search engine, ms_run locations).
* Linking to an existing .mpgo: identifications get added on top of
  the linked dataset's existing records.
* Hard error on missing mzTab-version line.

Hermetic synthetic fixtures only. Cross-language counterparts:
``objc/Tests/TestMzTabReader.m``,
``java/.../importers/MzTabReaderTest.java``.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from mpeg_o import SpectralDataset, WrittenRun
from mpeg_o.importers.mztab import MzTabParseError, read as mztab_read


# --------------------------------------------------------------------------- #
# Fixture builders.
# --------------------------------------------------------------------------- #

_PROTEOMICS_FIXTURE = """\
COM	Synthetic mzTab 1.0 fixture for v0.9 M60.
MTD	mzTab-version	1.0
MTD	mzTab-mode	Complete
MTD	mzTab-type	Identification
MTD	description	Synthetic BSA digest results
MTD	ms_run[1]-location	file:///tmp/bsa_digest.mzML
MTD	software[1]	[MS, MS:1001456, X!Tandem, v2.4.0]
MTD	psm_search_engine_score[1]	[MS, MS:1001330, X!Tandem expect, ]
MTD	assay[1]-sample_ref	sample[1]
MTD	assay[2]-sample_ref	sample[2]

PRH	accession	description	taxid	species	database	database_version	search_engine	best_search_engine_score[1]	protein_abundance_assay[1]	protein_abundance_assay[2]
PRT	P02769	Bovine serum albumin	9913	Bos taurus	UniProtKB	2024_04	[MS, MS:1001456, X!Tandem, v2.4.0]	0.99	123456.7	98765.4

PSH	sequence	PSM_ID	accession	unique	database	database_version	search_engine	search_engine_score[1]	modifications	retention_time	charge	exp_mass_to_charge	calc_mass_to_charge	pre	post	start	end	spectra_ref
PSM	DTHKSEIAHR	1	P02769	1	UniProtKB	2024_04	[MS, MS:1001456, X!Tandem, v2.4.0]	0.95	null	120.5	2	413.7	413.69	K	I	125	134	ms_run[1]:scan=42
PSM	LVNELTEFAK	2	P02769	1	UniProtKB	2024_04	[MS, MS:1001456, X!Tandem, v2.4.0]	0.88	null	130.2	2	582.3	582.29	K	S	66	75	ms_run[1]:scan=87
PSM	YICDNQDTISSK	3	P02769	1	UniProtKB	2024_04	[MS, MS:1001456, X!Tandem, v2.4.0]	0.91	null	150.8	2	701.4	701.38	K	L	209	220	ms_run[1]:scan=152
"""


_METABOLOMICS_FIXTURE = """\
COM	Synthetic mzTab-M 2.0 fixture for v0.9 M60.
MTD	mzTab-version	2.0.0-M
MTD	mzTab-ID	MTBLS9999
MTD	description	Synthetic metabolomics study
MTD	ms_run[1]-location	file:///tmp/glucose_run.mzML
MTD	software[1]	[MS, MS:1003121, OpenMS, v3.0.0]
MTD	study_variable[1]-description	control
MTD	study_variable[2]-description	treatment

SMH	SML_ID	database_identifier	chemical_formula	smiles	inchi	chemical_name	uri	best_id_confidence_measure	best_id_confidence_value	abundance_study_variable[1]	abundance_study_variable[2]
SML	1	CHEBI:17234	C6H12O6	OC[C@H]1OC(O)[C@H](O)[C@@H](O)[C@@H]1O	null	D-glucose	null	[MS, MS:1003124, mass match,]	0.95	1.5e6	2.1e6
SML	2	CHEBI:30769	C6H8O7	OC(=O)CC(O)(CC(O)=O)C(O)=O	null	citric acid	null	[MS, MS:1003124, mass match,]	0.88	8.2e5	7.5e5
"""


@pytest.fixture()
def proteomics_fixture(tmp_path: Path) -> Path:
    p = tmp_path / "proteomics.mztab"
    p.write_text(_PROTEOMICS_FIXTURE)
    return p


@pytest.fixture()
def metabolomics_fixture(tmp_path: Path) -> Path:
    p = tmp_path / "metabolomics.mztab"
    p.write_text(_METABOLOMICS_FIXTURE)
    return p


# --------------------------------------------------------------------------- #
# mzTab 1.0 (proteomics) parsing.
# --------------------------------------------------------------------------- #

def test_proteomics_version_and_metadata(proteomics_fixture: Path) -> None:
    result = mztab_read(proteomics_fixture)
    assert result.version == "1.0"
    assert result.is_metabolomics is False
    assert result.description == "Synthetic BSA digest results"
    assert result.ms_run_locations[1] == "file:///tmp/bsa_digest.mzML"
    assert "X!Tandem" in result.software[0]


def test_proteomics_psm_count_and_scores(proteomics_fixture: Path) -> None:
    result = mztab_read(proteomics_fixture)
    assert len(result.identifications) == 3
    # Identifications carry the protein accession + best score.
    accs = [i.chemical_entity for i in result.identifications]
    assert accs == ["P02769", "P02769", "P02769"]
    scores = [i.confidence_score for i in result.identifications]
    assert scores == [0.95, 0.88, 0.91]
    # Run name resolved from ms_run[1]-location basename.
    assert result.identifications[0].run_name == "bsa_digest"


def test_proteomics_psm_spectrum_index(proteomics_fixture: Path) -> None:
    result = mztab_read(proteomics_fixture)
    assert [i.spectrum_index for i in result.identifications] == [42, 87, 152]


def test_proteomics_psm_evidence_chain(proteomics_fixture: Path) -> None:
    result = mztab_read(proteomics_fixture)
    chain = result.identifications[0].evidence_chain
    assert any("X!Tandem" in e for e in chain)
    assert any("PSM_ID=" in e for e in chain)


def test_proteomics_protein_abundance(proteomics_fixture: Path) -> None:
    result = mztab_read(proteomics_fixture)
    # One PRT row × two abundance columns → two Quantification records.
    assert len(result.quantifications) == 2
    quants = sorted(result.quantifications, key=lambda q: q.sample_ref)
    assert quants[0].chemical_entity == "P02769"
    assert quants[0].abundance == pytest.approx(123456.7)
    assert quants[1].abundance == pytest.approx(98765.4)
    assert quants[0].sample_ref == "sample[1]"
    assert quants[1].sample_ref == "sample[2]"


def test_proteomics_provenance(proteomics_fixture: Path) -> None:
    result = mztab_read(proteomics_fixture)
    assert len(result.provenance) == 1
    params = result.provenance[0].parameters
    assert params["mztab_version"] == "1.0"
    assert "X!Tandem" in params["mztab_software"]


# --------------------------------------------------------------------------- #
# mzTab-M 2.0 (metabolomics) parsing.
# --------------------------------------------------------------------------- #

def test_metabolomics_version_and_dispatch(metabolomics_fixture: Path) -> None:
    result = mztab_read(metabolomics_fixture)
    assert result.version == "2.0.0-M"
    assert result.is_metabolomics is True


def test_metabolomics_metabolite_ids(metabolomics_fixture: Path) -> None:
    result = mztab_read(metabolomics_fixture)
    ids = [i.chemical_entity for i in result.identifications]
    assert ids == ["CHEBI:17234", "CHEBI:30769"]
    scores = [i.confidence_score for i in result.identifications]
    assert scores == [0.95, 0.88]
    # Evidence chain carries the human name and formula.
    glucose = result.identifications[0]
    assert any("D-glucose" in e for e in glucose.evidence_chain)
    assert any("C6H12O6" in e for e in glucose.evidence_chain)


def test_metabolomics_abundance(metabolomics_fixture: Path) -> None:
    result = mztab_read(metabolomics_fixture)
    # 2 metabolites × 2 study variables = 4 quantifications.
    assert len(result.quantifications) == 4
    glucose_quants = [q for q in result.quantifications if q.chemical_entity == "CHEBI:17234"]
    assert len(glucose_quants) == 2
    glucose_quants.sort(key=lambda q: q.sample_ref)
    assert glucose_quants[0].sample_ref == "control"
    assert glucose_quants[1].sample_ref == "treatment"
    assert glucose_quants[0].abundance == pytest.approx(1.5e6)
    assert glucose_quants[1].abundance == pytest.approx(2.1e6)


# --------------------------------------------------------------------------- #
# Round-trip into .mpgo + link_to existing dataset.
# --------------------------------------------------------------------------- #

def _make_seed_mpgo(tmp_path: Path) -> Path:
    """Build a minimal .mpgo with one MS run for the link_to test."""
    n_spectra = 3
    n_peaks = 4
    mz = np.tile(np.linspace(100.0, 200.0, n_peaks), n_spectra).astype(np.float64)
    intensity = np.tile(np.linspace(1.0, 100.0, n_peaks), n_spectra).astype(np.float64)
    run = WrittenRun(
        spectrum_class="MPGOMassSpectrum",
        acquisition_mode=0,
        channel_data={"mz": mz, "intensity": intensity},
        offsets=np.arange(n_spectra, dtype=np.uint64) * n_peaks,
        lengths=np.full(n_spectra, n_peaks, dtype=np.uint32),
        retention_times=np.zeros(n_spectra, dtype=np.float64),
        ms_levels=np.ones(n_spectra, dtype=np.int32),
        polarities=np.zeros(n_spectra, dtype=np.int32),
        precursor_mzs=np.zeros(n_spectra, dtype=np.float64),
        precursor_charges=np.zeros(n_spectra, dtype=np.int32),
        base_peak_intensities=np.full(n_spectra, 100.0, dtype=np.float64),
    )
    seed = tmp_path / "seed.mpgo"
    SpectralDataset.write_minimal(
        seed, title="seed",
        isa_investigation_id="ISA-SEED",
        runs={"bsa_digest": run},
    )
    return seed


def test_to_mpgo_identifications_only(proteomics_fixture: Path, tmp_path: Path) -> None:
    parsed = mztab_read(proteomics_fixture)
    out = tmp_path / "out.mpgo"
    parsed.to_mpgo(out, title="proteomics-only")
    with SpectralDataset.open(out) as ds:
        assert ds.title == "proteomics-only"
        assert len(ds.identifications()) == 3
        assert len(ds.quantifications()) == 2


def test_to_mpgo_link_to_existing(proteomics_fixture: Path, tmp_path: Path) -> None:
    seed_path = _make_seed_mpgo(tmp_path)
    parsed = mztab_read(proteomics_fixture)
    out = tmp_path / "merged.mpgo"
    with SpectralDataset.open(seed_path) as seed:
        parsed.to_mpgo(out, title="merged", link_to=seed)
    with SpectralDataset.open(out) as merged:
        # Original run survives the rewrite.
        assert "bsa_digest" in merged.ms_runs
        assert len(merged.ms_runs["bsa_digest"]) == 3
        # Identifications from mzTab show up alongside any seed records.
        assert len(merged.identifications()) == 3
        assert merged.identifications()[0].chemical_entity == "P02769"


def test_missing_version_raises(tmp_path: Path) -> None:
    bad = tmp_path / "noversion.mztab"
    bad.write_text("MTD\tdescription\twithout version line\n")
    with pytest.raises(MzTabParseError, match="missing MTD mzTab-version"):
        mztab_read(bad)


def test_missing_file_raises(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError):
        mztab_read(tmp_path / "absent.mztab")
