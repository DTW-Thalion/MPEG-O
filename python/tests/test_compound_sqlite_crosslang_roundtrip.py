"""P2.7 QT2 — cross-language compound SQLite round-trip conformance (write side).

This is the Python half of the #205 read-side cross-language conformance
contract. The Java SDK's :class:`SqliteProvider` replaced its hand-rolled
compound-JSON reader with Jackson (P2.7 QT1); this test pins the *byte form a
non-Java writer (Python) actually emits* on disk, so the Java-side fence
(``CompoundCrossLangReadTest``) reads against a captured-but-real shape.

What it asserts:

* a compound dataset written through the Python ``SqliteProvider`` stores its
  ``compound_fields`` / ``compound_rows`` as ``json.dumps`` output — i.e.
  ``", "`` / ``": "`` whitespace-padded separators, Python float repr (``3.0``
  for an integral float), and escaped string values — the exact non-canonical
  shape the Java reader must tolerate;
* a row VALUE may legitimately contain the literal token ``"kind":"int64"``
  (plus commas and braces) — the substring-confusion class behind #205;
* the Python read-back round-trips every field/row/shape value.

The byte-canonical JSON *serializer* is unchanged, so compound byte-parity
across languages is preserved (see ``test_canonical_bytes_cross_backend.py`` /
``test_compound_writer_parity.py``); this test guards the *read-back* obligation
in the SQLite-on-disk direction.
"""
from __future__ import annotations

import json
import sqlite3
from pathlib import Path

from ttio.providers import CompoundField, CompoundFieldKind
from ttio.providers.sqlite import SqliteProvider


def _schema() -> list[CompoundField]:
    return [
        CompoundField("run_name", CompoundFieldKind.VL_STRING),
        CompoundField("spectrum_index", CompoundFieldKind.UINT32),
        CompoundField("score", CompoundFieldKind.FLOAT64),
        CompoundField("chem_id", CompoundFieldKind.VL_STRING),
    ]


def _rows() -> list[dict]:
    return [
        {"run_name": "runA", "spectrum_index": 0,
         "score": 0.95, "chem_id": "CHEBI:15377"},
        # run_name VALUE contains the literal token "kind":"int64" plus a
        # comma and braces — the #205 substring-confusion case.
        {"run_name": 'r,b{x} said "kind":"int64"', "spectrum_index": 42,
         "score": -1.5, "chem_id": ""},
        # score 3.0 is an integral float -> Python repr emits "3.0" (a
        # floating-point JSON token), not "3".
        {"run_name": "pi", "spectrum_index": 7,
         "score": 3.0, "chem_id": "u"},
    ]


def _write_fixture(path: Path) -> None:
    with SqliteProvider.open(str(path), mode="w") as p:
        ds = p.root_group().create_compound_dataset("idents", _schema(), count=3)
        ds.write(_rows())


def test_python_compound_on_disk_is_noncanonical(tmp_path: Path) -> None:
    """The on-disk JSON the Python writer emits is the whitespace-padded,
    float-repr, escaped shape the Java Jackson reader must tolerate."""
    fixture = tmp_path / "py_compound.tio.sqlite"
    _write_fixture(fixture)

    conn = sqlite3.connect(str(fixture))
    try:
        fields_json, rows_json, shape_json = conn.execute(
            "SELECT compound_fields, compound_rows, shape_json "
            "FROM datasets WHERE name = 'idents'"
        ).fetchone()
    finally:
        conn.close()

    # Non-canonical whitespace padding that the byte-canonical serializer never
    # emits, but a structural reader must accept.
    assert '", "' in rows_json or '": "' in rows_json
    assert '": "' in fields_json
    # Python float repr for the integral float.
    assert '"score": 3.0' in rows_json
    # The #205 substring-confusion token survives verbatim inside a value.
    assert r'\"kind\":\"int64\"' in rows_json
    assert shape_json == "[3]"

    # The fields JSON uses the same wire tokens the Java reader maps.
    parsed_fields = json.loads(fields_json)
    assert [f["kind"] for f in parsed_fields] == [
        "vl_string", "uint32", "float64", "vl_string"]


def test_python_compound_roundtrips_through_python_reader(tmp_path: Path) -> None:
    """Sanity: the Python read-back round-trips every field/row/shape value —
    the same values the Java fence asserts on the read side."""
    fixture = tmp_path / "py_compound.tio.sqlite"
    _write_fixture(fixture)

    with SqliteProvider.open(str(fixture), mode="r") as p:
        ds = p.root_group().open_dataset("idents")
        assert ds.shape == (3,)
        got_fields = list(ds.compound_fields)
        assert got_fields == _schema()
        rows = list(ds.read())

    assert rows == _rows()
    # The substring-confusion value survived structurally.
    assert rows[1]["run_name"] == 'r,b{x} said "kind":"int64"'
    # Integral float read back as a float.
    assert isinstance(rows[2]["score"], float)
    assert rows[2]["score"] == 3.0
