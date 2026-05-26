"""Stage 6 (transport-spec v0.11 §4.22): Python Arrow IPC codec for
Subject + Sample.

Java parity: ``ArrowIpcCodecSubjectsSamplesTest`` (commit ``dd211600``).
Schema field names match Java's ``SUBJECT_SCHEMA`` / ``SAMPLE_SCHEMA``
exactly so cross-lang IPC reads work without translation.

Null-handling conventions verified here (per Java's documented contract):

* optional string columns: empty-string ↔ Arrow null
* optional int columns: sentinel 0 ↔ Arrow null
* ``attributes_json`` always emitted (``"{}"`` for empty)
"""
from __future__ import annotations

import io
import pyarrow as pa

from ttio.sample import Sample
from ttio.subject import Subject
from ttio.transport.arrow_ipc import (
    _SAMPLE_SCHEMA,
    _SUBJECT_SCHEMA,
    decode_samples,
    decode_subjects,
    encode_samples,
    encode_subjects,
)


# ── Subjects ────────────────────────────────────────────────────────


def test_empty_subjects_round_trip():
    out = decode_subjects(encode_subjects([]))
    assert out == []


def test_subjects_round_trip_all_fields_populated():
    rows = [
        Subject(
            external_id="S1",
            project="STUDY-A",
            sex="F",
            birth_year=1985,
            attributes={"site": "NYC", "cohort": "A1"},
        ),
        Subject(
            external_id="S2",
            project="STUDY-B",
            sex="M",
            birth_year=1990,
            attributes={},
        ),
    ]
    out = decode_subjects(encode_subjects(rows))
    assert len(out) == 2
    assert out[0].external_id == "S1"
    assert out[0].project == "STUDY-A"
    assert out[0].sex == "F"
    assert out[0].birth_year == 1985
    assert out[0].attributes == {"site": "NYC", "cohort": "A1"}
    assert out[1].external_id == "S2"
    assert out[1].project == "STUDY-B"
    assert out[1].sex == "M"
    assert out[1].birth_year == 1990
    assert out[1].attributes == {}


def test_subjects_empty_string_encodes_as_null_and_decodes_back_to_empty():
    """Optional string columns: "" ↔ Arrow null on the wire."""
    rows = [
        Subject(external_id="S1", project="", sex="", birth_year=0),
    ]
    ipc = encode_subjects(rows)
    # Inspect the actual Arrow nulls before decoding.
    reader = pa.ipc.open_stream(io.BytesIO(ipc))
    batch = reader.read_next_batch()
    assert batch.column("project")[0].as_py() is None
    assert batch.column("sex")[0].as_py() is None
    assert batch.column("birth_year")[0].as_py() is None
    # external_id is notNullable — must round-trip the non-empty value.
    assert batch.column("external_id")[0].as_py() == "S1"
    # attributes_json is always emitted with "{}" for empty maps.
    assert batch.column("attributes_json")[0].as_py() == "{}"

    out = decode_subjects(ipc)
    assert out[0].project == ""
    assert out[0].sex == ""
    assert out[0].birth_year == 0


def test_subjects_non_empty_strings_survive():
    rows = [Subject(external_id="S1", project="P", sex="F", birth_year=2000)]
    ipc = encode_subjects(rows)
    reader = pa.ipc.open_stream(io.BytesIO(ipc))
    batch = reader.read_next_batch()
    assert batch.column("project")[0].as_py() == "P"
    assert batch.column("sex")[0].as_py() == "F"
    assert batch.column("birth_year")[0].as_py() == 2000


def test_subjects_birth_year_sentinel_zero_is_null_on_wire():
    rows = [
        Subject(external_id="S1", birth_year=0),
        Subject(external_id="S2", birth_year=1990),
    ]
    ipc = encode_subjects(rows)
    reader = pa.ipc.open_stream(io.BytesIO(ipc))
    batch = reader.read_next_batch()
    assert batch.column("birth_year")[0].as_py() is None
    assert batch.column("birth_year")[1].as_py() == 1990

    out = decode_subjects(ipc)
    assert out[0].birth_year == 0
    assert out[1].birth_year == 1990


def test_subjects_attributes_json_always_present():
    rows = [
        Subject(external_id="S1"),  # empty attributes
        Subject(external_id="S2", attributes={"k": "v"}),
    ]
    ipc = encode_subjects(rows)
    reader = pa.ipc.open_stream(io.BytesIO(ipc))
    batch = reader.read_next_batch()
    assert batch.column("attributes_json")[0].as_py() == "{}"
    assert batch.column("attributes_json")[1].as_py() == '{"k":"v"}'


def test_subjects_schema_field_names_match_java():
    """Schema column names must exactly match Java's SUBJECT_SCHEMA so
    cross-lang IPC reads work without rename. The Java field list
    (commit dd211600) is:
        external_id, project, sex, birth_year, attributes_json
    """
    names = _SUBJECT_SCHEMA.names
    assert names == [
        "external_id",
        "project",
        "sex",
        "birth_year",
        "attributes_json",
    ]
    # external_id is notNullable; everything else is nullable.
    assert _SUBJECT_SCHEMA.field("external_id").nullable is False
    for n in ("project", "sex", "birth_year", "attributes_json"):
        assert _SUBJECT_SCHEMA.field(n).nullable is True
    # birth_year is int32 (widened from on-disk int64 per design spec §6.1).
    assert _SUBJECT_SCHEMA.field("birth_year").type == pa.int32()


# ── Samples ─────────────────────────────────────────────────────────


def test_empty_samples_round_trip():
    assert decode_samples(encode_samples([])) == []


def test_samples_round_trip_all_fields_populated():
    rows = [
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
    out = decode_samples(encode_samples(rows))
    assert len(out) == 2
    assert out[0].sample_id == "bio1"
    assert out[0].subject_external_id == "S1"
    assert out[0].sample_kind == "tissue"
    assert out[0].collected_at == 1700000000
    assert out[0].attributes == {"ph": "7.4"}
    assert out[1].sample_id == "bio2"
    assert out[1].subject_external_id == ""
    assert out[1].sample_kind == "plasma"
    assert out[1].collected_at == 0
    assert out[1].attributes == {}


def test_samples_empty_strings_and_zero_collected_at_decode_to_nulls():
    rows = [
        Sample(
            sample_id="bio1",
            subject_external_id="",
            sample_kind="",
            collected_at=0,
        ),
    ]
    ipc = encode_samples(rows)
    reader = pa.ipc.open_stream(io.BytesIO(ipc))
    batch = reader.read_next_batch()
    assert batch.column("subject_external_id")[0].as_py() is None
    assert batch.column("sample_kind")[0].as_py() is None
    assert batch.column("collected_at")[0].as_py() is None
    assert batch.column("sample_id")[0].as_py() == "bio1"
    assert batch.column("attributes_json")[0].as_py() == "{}"


def test_samples_collected_at_int64_on_wire():
    """Spec §6.2: collected_at is int64 (wider than birth_year's int32)."""
    assert _SAMPLE_SCHEMA.field("collected_at").type == pa.int64()
    # Boundary check: a value beyond int32 max round-trips correctly.
    big = 2_147_483_650  # > INT32_MAX
    rows = [Sample(sample_id="bio1", collected_at=big)]
    out = decode_samples(encode_samples(rows))
    assert out[0].collected_at == big


def test_samples_schema_field_names_match_java():
    """Schema column names must exactly match Java's SAMPLE_SCHEMA."""
    names = _SAMPLE_SCHEMA.names
    assert names == [
        "sample_id",
        "subject_external_id",
        "sample_kind",
        "collected_at",
        "attributes_json",
    ]
    assert _SAMPLE_SCHEMA.field("sample_id").nullable is False
    for n in (
        "subject_external_id", "sample_kind", "collected_at", "attributes_json"
    ):
        assert _SAMPLE_SCHEMA.field(n).nullable is True


def test_subjects_attributes_json_sort_keys_byte_form():
    """The on-wire attributes_json value uses sort-keys + compact
    separators — byte-equal to Java's MiniJson + ObjC's
    NSJSONWritingSortedKeys.
    """
    rows = [
        Subject(
            external_id="S1",
            attributes={"zeta": "z", "alpha": "a", "mu": "m"},
        ),
    ]
    ipc = encode_subjects(rows)
    reader = pa.ipc.open_stream(io.BytesIO(ipc))
    batch = reader.read_next_batch()
    expected = '{"alpha":"a","mu":"m","zeta":"z"}'
    assert batch.column("attributes_json")[0].as_py() == expected
