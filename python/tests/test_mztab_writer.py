"""mzTab writer — v0.9+ round-trip + dialect tests.

Covers both the proteomics 1.0 dialect (PSM + PRT) and the
metabolomics 2.0.0-M dialect (SML), plus every layout invariant the
reader depends on (MTD ordering, assay declarations, spectra_ref
format).
"""
from __future__ import annotations

from pathlib import Path

import pytest

from ttio.exporters import mztab as mztab_writer
from ttio.identification import Identification
from ttio.importers import mztab as mztab_reader
from ttio.quantification import Quantification


def _idents() -> list[Identification]:
    return [
        Identification(run_name="run1", spectrum_index=10,
                       chemical_entity="sp|P12345|BSA_BOVIN",
                       confidence_score=0.95,
                       evidence_chain=["[MS, MS:1001083, mascot, 1.0]"]),
        Identification(run_name="run1", spectrum_index=17,
                       chemical_entity="sp|P67890|CRP_HUMAN",
                       confidence_score=0.82,
                       evidence_chain=[]),
    ]


def _quants() -> list[Quantification]:
    return [
        Quantification(chemical_entity="sp|P12345|BSA_BOVIN",
                       sample_ref="sample_A", abundance=1234.5,
                       normalization_method=""),
        Quantification(chemical_entity="sp|P67890|CRP_HUMAN",
                       sample_ref="sample_A", abundance=67.0,
                       normalization_method=""),
        Quantification(chemical_entity="sp|P12345|BSA_BOVIN",
                       sample_ref="sample_B", abundance=2222.2,
                       normalization_method=""),
    ]


def test_proteomics_dialect_round_trip(tmp_path: Path) -> None:
    """Proteomics 1.0 output: MTD declares software + ms_runs, PSM
    carries identifications, PRT carries per-assay quantifications.
    Round-trips through the reader bit-identically."""
    out = tmp_path / "out.mztab"
    result = mztab_writer.write(out,
        identifications=_idents(), quantifications=_quants(),
        version="1.0", title="BSA tryptic digest")
    assert result.version == "1.0"
    assert result.n_psm_rows == 2
    assert result.n_prt_rows == 2
    assert result.n_sml_rows == 0
    assert out.is_file()

    imp = mztab_reader.read(out)
    assert imp.version == "1.0"
    assert len(imp.identifications) == 2
    assert {i.chemical_entity for i in imp.identifications} == {
        "sp|P12345|BSA_BOVIN", "sp|P67890|CRP_HUMAN"
    }
    # PSM reader picks the maximum score column; we wrote one score
    # column so the round-trip value equals the original.
    for orig, rt in zip(_idents(),
                         sorted(imp.identifications,
                                key=lambda i: i.spectrum_index)):
        if orig.spectrum_index == rt.spectrum_index:
            assert rt.chemical_entity == orig.chemical_entity
            assert abs(rt.confidence_score - orig.confidence_score) < 1e-9

    # PRT abundances split into one Quantification per assay column.
    # Sample labels round-trip via MTD assay[N]-sample_ref.
    assert len(imp.quantifications) == 3
    by_sample: dict[str, dict[str, float]] = {}
    for q in imp.quantifications:
        by_sample.setdefault(q.sample_ref, {})[q.chemical_entity] = q.abundance
    assert by_sample.get("sample_A", {}).get("sp|P12345|BSA_BOVIN") == 1234.5
    assert by_sample.get("sample_A", {}).get("sp|P67890|CRP_HUMAN") == 67.0
    assert by_sample.get("sample_B", {}).get("sp|P12345|BSA_BOVIN") == 2222.2


def test_metabolomics_dialect_round_trip(tmp_path: Path) -> None:
    """Metabolomics 2.0.0-M: every entity gets one SML row carrying
    both the identification and the per-sample abundances."""
    out = tmp_path / "met.mztab"
    idents = [
        Identification(run_name="metabolomics", spectrum_index=0,
                       chemical_entity="CHEBI:15365",
                       confidence_score=0.9, evidence_chain=[]),
        Identification(run_name="metabolomics", spectrum_index=1,
                       chemical_entity="CHEBI:17790",
                       confidence_score=0.7, evidence_chain=[]),
    ]
    quants = [
        Quantification(chemical_entity="CHEBI:15365",
                       sample_ref="S1", abundance=10.0,
                       normalization_method=""),
        Quantification(chemical_entity="CHEBI:15365",
                       sample_ref="S2", abundance=20.0,
                       normalization_method=""),
        Quantification(chemical_entity="CHEBI:17790",
                       sample_ref="S1", abundance=5.0,
                       normalization_method=""),
    ]
    result = mztab_writer.write(out,
        identifications=idents, quantifications=quants,
        version="2.0.0-M")
    assert result.n_sml_rows == 2
    assert result.n_psm_rows == 0
    assert result.n_prt_rows == 0

    imp = mztab_reader.read(out)
    assert imp.version == "2.0.0-M"
    assert len(imp.identifications) == 2
    # Metabolomics reader emits quantifications keyed by study_variable
    # index; every non-null abundance cell becomes one record.
    abundances = {(q.chemical_entity, q.sample_ref): q.abundance
                  for q in imp.quantifications}
    # Round-trip lands the original sample label ("S1"/"S2") via
    # MTD study_variable[N]-description.
    assert abundances.get(("CHEBI:15365", "S1")) == 10.0
    assert abundances.get(("CHEBI:15365", "S2")) == 20.0
    assert abundances.get(("CHEBI:17790", "S1")) == 5.0


def test_mtd_declares_every_referenced_ms_run(tmp_path: Path) -> None:
    """Every run_name referenced by a PSM's ms_run[N]:index=... locator
    must have a matching ``MTD\\tms_run[N]-location`` line — the reader
    uses that mapping to resolve the run name on parse."""
    out = tmp_path / "runs.mztab"
    idents = [
        Identification(run_name="alpha", spectrum_index=0,
                       chemical_entity="X", confidence_score=0.5,
                       evidence_chain=[]),
        Identification(run_name="beta", spectrum_index=1,
                       chemical_entity="Y", confidence_score=0.5,
                       evidence_chain=[]),
    ]
    mztab_writer.write(out, identifications=idents, version="1.0")
    text = out.read_text()
    # Both runs appear in MTD.
    assert "MTD\tms_run[1]-location\t" in text
    assert "MTD\tms_run[2]-location\t" in text
    # And the PSM rows reference them by their assigned index.
    assert "ms_run[1]:index=0" in text
    assert "ms_run[2]:index=1" in text


def test_rejects_unknown_version(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="unsupported mzTab version"):
        mztab_writer.write(tmp_path / "x.mztab",
            identifications=_idents(), version="0.9")


def test_tabs_in_field_values_are_escaped(tmp_path: Path) -> None:
    """TSV is fragile — embedded tabs / newlines in free-form fields
    must be scrubbed before the row is joined, otherwise every
    downstream parser breaks."""
    dirty = Identification(run_name="r", spectrum_index=0,
                           chemical_entity="nasty\tvalue\nwith\rspecials",
                           confidence_score=0.1, evidence_chain=[])
    out = tmp_path / "dirty.mztab"
    mztab_writer.write(out, identifications=[dirty], version="1.0")
    text = out.read_text()
    # The PSM row must contain the escaped (spaced) variant; the
    # nasty original must not appear verbatim.
    assert "nasty value with specials" in text
    assert "nasty\tvalue" not in text


def test_write_dataset_convenience_on_real_ttio(tmp_path: Path) -> None:
    """write_dataset() lifts the ids + quants out of an open
    SpectralDataset and delegates to write(). Compose a real .tio via
    write_minimal and verify the bytes match a direct write() call."""
    from ttio import SpectralDataset
    from ttio.spectral_dataset import WrittenRun
    from ttio.enums import AcquisitionMode
    import numpy as np

    ttio_path = tmp_path / "source.tio"
    run = WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={
            "mz": np.array([100.0, 200.0], dtype=np.float64),
            "intensity": np.array([1.0, 2.0], dtype=np.float64),
        },
        offsets=np.array([0], dtype=np.uint64),
        lengths=np.array([2], dtype=np.uint32),
        retention_times=np.array([0.0]),
        ms_levels=np.array([1], dtype=np.int32),
        polarities=np.array([1], dtype=np.int32),
        precursor_mzs=np.array([0.0]),
        precursor_charges=np.array([0], dtype=np.int32),
        base_peak_intensities=np.array([2.0]),
    )
    SpectralDataset.write_minimal(
        ttio_path, title="convenience",
        isa_investigation_id="ISA-CONV",
        runs={"run1": run},
        identifications=_idents(),
        quantifications=_quants(),
    )

    direct_path = tmp_path / "direct.mztab"
    conv_path = tmp_path / "conv.mztab"
    mztab_writer.write(direct_path,
        identifications=_idents(), quantifications=_quants(),
        version="1.0", title="convenience")
    with SpectralDataset.open(ttio_path) as ds:
        mztab_writer.write_dataset(ds, conv_path, version="1.0")

    # The convenience path threads the dataset's title through
    # automatically; the direct path got it passed explicitly.
    assert direct_path.read_bytes() == conv_path.read_bytes()
