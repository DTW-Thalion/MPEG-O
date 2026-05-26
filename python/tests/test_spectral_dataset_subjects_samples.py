"""Stage 6 (transport-spec v0.11, Deferral 2): SpectralDataset.subjects
+ SpectralDataset.samples lazy properties + HDF5 round-trip.

Java parity: ``SpectralDatasetSubjectsSamplesTest`` from commit
``dd39f4e6``.
"""
from __future__ import annotations

import logging
from pathlib import Path

import pytest

from ttio.sample import Sample
from ttio.spectral_dataset import SpectralDataset
from ttio.subject import Subject


def _write_minimal_with_subjects_samples(
    path: Path,
    *,
    subjects=None,
    samples=None,
) -> Path:
    return SpectralDataset.write_minimal(
        path,
        title="stage6",
        isa_investigation_id="",
        runs={},
        subjects=subjects,
        samples=samples,
    )


def test_empty_round_trip(tmp_path: Path) -> None:
    """Dataset with no subjects / samples has empty lists on open."""
    p = _write_minimal_with_subjects_samples(tmp_path / "ds.tio")
    with SpectralDataset.open(p) as ds:
        assert ds.subjects == []
        assert ds.samples == []


def test_subjects_only_round_trip(tmp_path: Path) -> None:
    subjects = [
        Subject(
            external_id="S1",
            project="STUDY-A",
            sex="F",
            birth_year=1985,
            attributes={"site": "NYC", "cohort": "A1"},
        ),
        Subject(
            external_id="S2",
            project="STUDY-A",
            sex="M",
            birth_year=1990,
            attributes={},
        ),
    ]
    p = _write_minimal_with_subjects_samples(
        tmp_path / "ds.tio", subjects=subjects
    )
    with SpectralDataset.open(p) as ds:
        read_back = ds.subjects
        assert len(read_back) == 2
        # Order preserved (HDF5 group iteration is deterministic for
        # newly-written groups in name order).
        by_id = {s.external_id: s for s in read_back}
        assert by_id["S1"].project == "STUDY-A"
        assert by_id["S1"].sex == "F"
        assert by_id["S1"].birth_year == 1985
        assert by_id["S1"].attributes == {"site": "NYC", "cohort": "A1"}
        assert by_id["S2"].sex == "M"
        assert by_id["S2"].birth_year == 1990
        assert by_id["S2"].attributes == {}
        assert ds.samples == []


def test_samples_only_round_trip(tmp_path: Path) -> None:
    samples = [
        Sample(
            sample_id="bio1",
            subject_external_id="S1",
            sample_kind="tissue",
            collected_at=1700000000,
            attributes={"ph": "7.4"},
        ),
        Sample(
            sample_id="bio2",
            subject_external_id="",
            sample_kind="plasma",
            collected_at=0,
            attributes={},
        ),
    ]
    p = _write_minimal_with_subjects_samples(
        tmp_path / "ds.tio", samples=samples
    )
    with SpectralDataset.open(p) as ds:
        read_back = ds.samples
        assert len(read_back) == 2
        by_id = {s.sample_id: s for s in read_back}
        assert by_id["bio1"].subject_external_id == "S1"
        assert by_id["bio1"].sample_kind == "tissue"
        assert by_id["bio1"].collected_at == 1700000000
        assert by_id["bio1"].attributes == {"ph": "7.4"}
        assert by_id["bio2"].subject_external_id == ""
        assert by_id["bio2"].collected_at == 0
        assert by_id["bio2"].attributes == {}
        assert ds.subjects == []


def test_full_round_trip_two_subjects_three_samples(tmp_path: Path) -> None:
    subjects = [
        Subject(external_id="S1", project="P", sex="F", birth_year=1980),
        Subject(external_id="S2", project="P", sex="M", birth_year=1990),
    ]
    samples = [
        Sample(sample_id="bio1", subject_external_id="S1", sample_kind="tissue"),
        Sample(sample_id="bio2", subject_external_id="S1", sample_kind="plasma"),
        Sample(sample_id="bio3", subject_external_id="S2", sample_kind="tissue"),
    ]
    p = _write_minimal_with_subjects_samples(
        tmp_path / "ds.tio", subjects=subjects, samples=samples
    )
    with SpectralDataset.open(p) as ds:
        assert len(ds.subjects) == 2
        assert len(ds.samples) == 3
        sample_subj_ids = {s.subject_external_id for s in ds.samples}
        assert sample_subj_ids == {"S1", "S2"}


def test_duplicate_subject_external_id_raises(tmp_path: Path) -> None:
    subjects = [
        Subject(external_id="S1"),
        Subject(external_id="S1"),
    ]
    with pytest.raises(ValueError, match="duplicate Subject.external_id"):
        _write_minimal_with_subjects_samples(
            tmp_path / "ds.tio", subjects=subjects
        )


def test_duplicate_sample_id_raises(tmp_path: Path) -> None:
    samples = [
        Sample(sample_id="bio1"),
        Sample(sample_id="bio1"),
    ]
    with pytest.raises(ValueError, match="duplicate Sample.sample_id"):
        _write_minimal_with_subjects_samples(
            tmp_path / "ds.tio", samples=samples
        )


def test_soft_fk_mismatch_warns_but_writes(
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    """Spec §4.4: Sample.subject_external_id that doesn't match any
    Subject logs WARNING but does not fail (anonymous / cross-dataset
    samples are valid)."""
    subjects = [Subject(external_id="S1")]
    samples = [
        Sample(sample_id="bio1", subject_external_id="SX"),  # unknown FK
    ]
    with caplog.at_level(logging.WARNING, logger="ttio.spectral_dataset"):
        p = _write_minimal_with_subjects_samples(
            tmp_path / "ds.tio", subjects=subjects, samples=samples
        )
    assert any(
        "soft-FK" in rec.message and "SX" in rec.message and "bio1" in rec.message
        for rec in caplog.records
    ), f"expected soft-FK WARNING; got {[r.message for r in caplog.records]}"
    # The dataset still wrote successfully.
    with SpectralDataset.open(p) as ds:
        assert len(ds.subjects) == 1
        assert len(ds.samples) == 1
        assert ds.samples[0].subject_external_id == "SX"


def test_empty_subject_external_id_does_not_trigger_soft_fk_warning(
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    """An empty FK is "unset", not "wrong" — no WARNING."""
    subjects = [Subject(external_id="S1")]
    samples = [Sample(sample_id="bio1", subject_external_id="")]
    with caplog.at_level(logging.WARNING, logger="ttio.spectral_dataset"):
        _write_minimal_with_subjects_samples(
            tmp_path / "ds.tio", subjects=subjects, samples=samples
        )
    assert not any(
        "soft-FK" in rec.message for rec in caplog.records
    ), "empty FK must not trigger soft-FK warning"


def test_attributes_json_special_chars_round_trip(tmp_path: Path) -> None:
    """Quoted strings + multi-key + UTF-8 survive write/read."""
    subjects = [
        Subject(
            external_id="S1",
            attributes={
                "note": 'has "quoted" text',
                "site": "café",
                "k1": "v1",
            },
        ),
    ]
    p = _write_minimal_with_subjects_samples(
        tmp_path / "ds.tio", subjects=subjects
    )
    with SpectralDataset.open(p) as ds:
        read_back = ds.subjects
        assert len(read_back) == 1
        assert read_back[0].attributes == {
            "note": 'has "quoted" text',
            "site": "café",
            "k1": "v1",
        }
