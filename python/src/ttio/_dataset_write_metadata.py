"""Metadata + subjects/samples IO helpers extracted from spectral_dataset.py (P3.10).

Pure code-movement extraction (P3.10 PR-1): identifications /
quantifications / provenance writers + JSON decoders, and the Stage 6
subjects/samples validation + read/write helpers. No behaviour change.
"""
from __future__ import annotations

import json

import h5py

from . import _hdf5_io as io
from .identification import Identification
from .quantification import Quantification
from .provenance import ProvenanceRecord
from .sample import Sample
from .subject import Subject
from .providers import StorageProvider
from .providers.base import StorageGroup


def _write_identifications(study: h5py.Group, records: list[Identification]) -> None:
    fields = [
        ("run_name", io.vl_str()),
        ("spectrum_index", "<u4"),
        ("chemical_entity", io.vl_str()),
        ("confidence_score", "<f8"),
        ("evidence_chain_json", io.vl_str()),
    ]
    io.write_compound_dataset(study, "identifications", [
        {
            "run_name": r.run_name,
            "spectrum_index": int(r.spectrum_index),
            "chemical_entity": r.chemical_entity,
            "confidence_score": float(r.confidence_score),
            "evidence_chain_json": json.dumps(r.evidence_chain),
        } for r in records
    ], fields)
    # emit @identifications_json mirror so Java (JHI5 1.10 cannot
    # marshal compound-with-VL reads) can recover the full record set.
    io.write_fixed_string_attr(study, "identifications_json", json.dumps([
        {
            "run_name": r.run_name,
            "spectrum_index": int(r.spectrum_index),
            "chemical_entity": r.chemical_entity,
            "confidence_score": float(r.confidence_score),
            "evidence_chain": list(r.evidence_chain),
        } for r in records
    ]))


def _write_quantifications(study: h5py.Group, records: list[Quantification]) -> None:
    fields = [
        ("chemical_entity", io.vl_str()),
        ("sample_ref", io.vl_str()),
        ("abundance", "<f8"),
        ("normalization_method", io.vl_str()),
    ]
    io.write_compound_dataset(study, "quantifications", [
        {
            "chemical_entity": r.chemical_entity,
            "sample_ref": r.sample_ref,
            "abundance": float(r.abundance),
            "normalization_method": r.normalization_method,
        } for r in records
    ], fields)
    # Optional sidecar `@quantification_units` JSON-array attribute:
    # one string per row, parallel to the compound dataset above.
    # Emitted only when at least one record carries a non-empty unit;
    # absent on legacy files (units default to "").
    if any(getattr(r, "unit", "") for r in records):
        io.write_fixed_string_attr(study, "quantification_units",
            json.dumps([getattr(r, "unit", "") or "" for r in records]))
    # JSON mirror (see _write_identifications)
    io.write_fixed_string_attr(study, "quantifications_json", json.dumps([
        {
            "chemical_entity": r.chemical_entity,
            "sample_ref": r.sample_ref,
            "abundance": float(r.abundance),
            **({"normalization_method": r.normalization_method}
               if r.normalization_method else {}),
            **({"unit": r.unit} if getattr(r, "unit", "") else {}),
        } for r in records
    ]))


def _write_provenance(
    study: h5py.Group,
    records: list[ProvenanceRecord],
    *,
    dataset_name: str = "provenance",
) -> None:
    fields = [
        ("timestamp_unix", "<i8"),
        ("software", io.vl_str()),
        ("parameters_json", io.vl_str()),
        ("input_refs_json", io.vl_str()),
        ("output_refs_json", io.vl_str()),
    ]
    io.write_compound_dataset(study, dataset_name, [
        {
            "timestamp_unix": int(r.timestamp_unix),
            "software": r.software,
            "parameters_json": json.dumps(r.parameters),
            "input_refs_json": json.dumps(r.input_refs),
            "output_refs_json": json.dumps(r.output_refs),
        } for r in records
    ], fields)
    # JSON mirror. Only emitted for the top-level /study/provenance
    # dataset; per-run provenance (§6.4) stays compound-only because the
    # Java reader never descends into run-level compound datasets.
    if dataset_name == "provenance":
        io.write_fixed_string_attr(study, "provenance_json", json.dumps([
            {
                "timestamp_unix": int(r.timestamp_unix),
                "software": r.software,
                "parameters": r.parameters,
                "input_refs": list(r.input_refs),
                "output_refs": list(r.output_refs),
            } for r in records
        ]))


# --------------------------------------------------------- JSON fallback ---


def _maybe_json_list(value: str) -> list[str]:
    try:
        parsed = json.loads(value) if value else []
    except json.JSONDecodeError:
        return []
    if isinstance(parsed, list):
        return [str(x) for x in parsed]
    return []


def _maybe_json_dict(value: str) -> dict[str, object]:
    try:
        parsed = json.loads(value) if value else {}
    except json.JSONDecodeError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _decode_identifications_json(blob: str) -> list[Identification]:
    try:
        data = json.loads(blob)
    except json.JSONDecodeError:
        return []
    out: list[Identification] = []
    for r in data if isinstance(data, list) else []:
        out.append(Identification(
            run_name=str(r.get("run_name", "")),
            spectrum_index=int(r.get("spectrum_index", 0)),
            chemical_entity=str(r.get("chemical_entity", "")),
            confidence_score=float(r.get("confidence_score", 0.0)),
            evidence_chain=[str(x) for x in r.get("evidence_chain", [])],
        ))
    return out


def _decode_quantifications_json(blob: str) -> list[Quantification]:
    try:
        data = json.loads(blob)
    except json.JSONDecodeError:
        return []
    out: list[Quantification] = []
    for r in data if isinstance(data, list) else []:
        out.append(Quantification(
            chemical_entity=str(r.get("chemical_entity", "")),
            sample_ref=str(r.get("sample_ref", "")),
            abundance=float(r.get("abundance", 0.0)),
            normalization_method=str(r.get("normalization_method", "")),
            unit=str(r.get("unit", "")),
        ))
    return out


def _decode_provenance_json(blob: str) -> list[ProvenanceRecord]:
    try:
        data = json.loads(blob)
    except json.JSONDecodeError:
        return []
    out: list[ProvenanceRecord] = []
    items = data if isinstance(data, list) else []
    for r in items:
        out.append(ProvenanceRecord(
            timestamp_unix=int(r.get("timestamp_unix", 0)),
            software=str(r.get("software", "")),
            parameters=r.get("parameters", {}) if isinstance(r.get("parameters"), dict) else {},
            input_refs=[str(x) for x in r.get("input_refs", [])],
            output_refs=[str(x) for x in r.get("output_refs", [])],
        ))
    return out


# ── Stage 6 (transport-spec v0.11, Deferral 2): Subjects + Samples ──
# Per design spec docs/superpowers/specs/2026-05-26-subjects-samples-design.md
# §4.4 (validation), §5 (HDF5 layout). Mirrors Java's
# SpectralDataset.{validateSubjectsAndSamples, writeSubjects, writeSamples,
# readSubjects, readSamples} from commit dd39f4e6.

import logging  # noqa: E402

_STAGE6_LOG = logging.getLogger(__name__)


def _validate_subjects_and_samples(
    subjects: list[Subject], samples: list[Sample]
) -> None:
    """Pre-write validation per spec §4.4:
    duplicate ``Subject.external_id`` or ``Sample.sample_id`` raises
    :class:`ValueError`; soft-FK mismatch (``Sample.subject_external_id``
    not found in Subject list) logs WARNING but does not fail."""
    seen_subjects: set[str] = set()
    for s in subjects:
        if s.external_id in seen_subjects:
            raise ValueError(
                f"duplicate Subject.external_id: {s.external_id}"
            )
        seen_subjects.add(s.external_id)
    seen_samples: set[str] = set()
    for s in samples:
        if s.sample_id in seen_samples:
            raise ValueError(
                f"duplicate Sample.sample_id: {s.sample_id}"
            )
        seen_samples.add(s.sample_id)
    for s in samples:
        fk = s.subject_external_id
        if not fk:
            continue
        if fk not in seen_subjects:
            _STAGE6_LOG.warning(
                "Sample %r references unknown Subject.external_id %r "
                "— soft-FK mismatch, writing anyway (spec §4.4).",
                s.sample_id, fk,
            )


def _write_subjects_h5(study: h5py.Group, subjects: list[Subject]) -> None:
    """HDF5 fast path: write ``/study/subjects/<external_id>/`` per-row
    groups with typed attributes. Mirrors Java's
    :meth:`SpectralDataset.writeSubjects`."""
    if not subjects:
        return
    from ttio.providers.hdf5 import _Group as _Hdf5Group
    subjects_group = study.create_group("subjects")
    for s in subjects:
        row_native = subjects_group.create_group(s.external_id)
        row = _Hdf5Group(row_native)
        # external_id (str) — always written.
        io.write_fixed_string_attr(row, "external_id", s.external_id)
        # optional strings — only emit when non-empty (Java parity).
        if s.project:
            io.write_fixed_string_attr(row, "project", s.project)
        if s.sex:
            io.write_fixed_string_attr(row, "sex", s.sex)
        # birth_year (int64) — always written; sentinel 0 means unknown.
        io.write_int_attr(row, "birth_year", int(s.birth_year))
        # attributes_json — always written; "{}" when empty.
        io.write_fixed_string_attr(row, "attributes_json", s.attributes_json())


def _write_samples_h5(study: h5py.Group, samples: list[Sample]) -> None:
    """HDF5 fast path: write ``/study/samples/<sample_id>/`` per-row
    groups with typed attributes. Mirrors Java's
    :meth:`SpectralDataset.writeSamples`."""
    if not samples:
        return
    from ttio.providers.hdf5 import _Group as _Hdf5Group
    samples_group = study.create_group("samples")
    for s in samples:
        row_native = samples_group.create_group(s.sample_id)
        row = _Hdf5Group(row_native)
        io.write_fixed_string_attr(row, "sample_id", s.sample_id)
        if s.subject_external_id:
            io.write_fixed_string_attr(
                row, "subject_external_id", s.subject_external_id
            )
        if s.sample_kind:
            io.write_fixed_string_attr(row, "sample_kind", s.sample_kind)
        io.write_int_attr(row, "collected_at", int(s.collected_at))
        io.write_fixed_string_attr(row, "attributes_json", s.attributes_json())


def _write_subjects_provider(
    study: StorageGroup, subjects: list[Subject]
) -> None:
    """Provider-agnostic mirror of :func:`_write_subjects_h5`."""
    if not subjects:
        return
    subjects_group = study.create_group("subjects")
    for s in subjects:
        row = subjects_group.create_group(s.external_id)
        row.set_attribute("external_id", s.external_id)
        if s.project:
            row.set_attribute("project", s.project)
        if s.sex:
            row.set_attribute("sex", s.sex)
        row.set_attribute("birth_year", int(s.birth_year))
        row.set_attribute("attributes_json", s.attributes_json())


def _write_samples_provider(
    study: StorageGroup, samples: list[Sample]
) -> None:
    """Provider-agnostic mirror of :func:`_write_samples_h5`."""
    if not samples:
        return
    samples_group = study.create_group("samples")
    for s in samples:
        row = samples_group.create_group(s.sample_id)
        row.set_attribute("sample_id", s.sample_id)
        if s.subject_external_id:
            row.set_attribute("subject_external_id", s.subject_external_id)
        if s.sample_kind:
            row.set_attribute("sample_kind", s.sample_kind)
        row.set_attribute("collected_at", int(s.collected_at))
        row.set_attribute("attributes_json", s.attributes_json())


def _parse_attributes_json(blob: str | None) -> dict[str, str]:
    """Parse ``attributes_json`` back into a ``dict[str, str]``.
    Mirrors Java's ``MiniJson.parseStringMap`` semantics for the
    Subject + Sample case (``{}`` and the empty string both decode to
    an empty dict)."""
    if not blob or blob == "{}":
        return {}
    try:
        parsed = json.loads(blob)
    except json.JSONDecodeError:
        return {}
    if not isinstance(parsed, dict):
        return {}
    return {str(k): str(v) for k, v in parsed.items()}


def _read_subjects(
    provider: StorageProvider | None,
) -> list[Subject]:
    """Stage 6: enumerate ``/study/subjects/`` children and decode each
    per-row group into a :class:`Subject`. Empty list when the group
    is absent (pre-Stage-6 files)."""
    out: list[Subject] = []
    if provider is None:
        return out
    root = provider.root_group()
    if not root.has_child("study"):
        return out
    study = root.open_group("study")
    if not study.has_child("subjects"):
        return out
    subjects_group = study.open_group("subjects")
    for name in subjects_group.child_names():
        row = subjects_group.open_group(name)
        external_id = _read_string_attr_or_default(row, "external_id", name)
        project = _read_string_attr_or_default(row, "project", "")
        sex = _read_string_attr_or_default(row, "sex", "")
        birth_year = _read_long_attr_or_default(row, "birth_year", 0)
        attrs_json = _read_string_attr_or_default(row, "attributes_json", "{}")
        out.append(Subject(
            external_id=external_id,
            project=project,
            sex=sex,
            birth_year=int(birth_year),
            attributes=_parse_attributes_json(attrs_json),
        ))
    return out


def _read_samples(
    provider: StorageProvider | None,
) -> list[Sample]:
    """Stage 6: enumerate ``/study/samples/`` children and decode each
    per-row group into a :class:`Sample`. Empty list when the group
    is absent (pre-Stage-6 files)."""
    out: list[Sample] = []
    if provider is None:
        return out
    root = provider.root_group()
    if not root.has_child("study"):
        return out
    study = root.open_group("study")
    if not study.has_child("samples"):
        return out
    samples_group = study.open_group("samples")
    for name in samples_group.child_names():
        row = samples_group.open_group(name)
        sample_id = _read_string_attr_or_default(row, "sample_id", name)
        subject_external_id = _read_string_attr_or_default(
            row, "subject_external_id", ""
        )
        sample_kind = _read_string_attr_or_default(row, "sample_kind", "")
        collected_at = _read_long_attr_or_default(row, "collected_at", 0)
        attrs_json = _read_string_attr_or_default(row, "attributes_json", "{}")
        out.append(Sample(
            sample_id=sample_id,
            subject_external_id=subject_external_id,
            sample_kind=sample_kind,
            collected_at=int(collected_at),
            attributes=_parse_attributes_json(attrs_json),
        ))
    return out


def _read_string_attr_or_default(
    group: StorageGroup, name: str, fallback: str
) -> str:
    if not group.has_attribute(name):
        return fallback
    v = group.get_attribute(name)
    if v is None:
        return fallback
    if isinstance(v, bytes):
        return v.decode("utf-8")
    return str(v)


def _read_long_attr_or_default(
    group: StorageGroup, name: str, fallback: int
) -> int:
    if not group.has_attribute(name):
        return fallback
    v = group.get_attribute(name)
    if v is None:
        return fallback
    try:
        return int(v)
    except (TypeError, ValueError):
        return fallback
