"""Apache Arrow IPC encode/decode for transport-spec v0.11 tabular packets.

Mirrors Java's :class:`global.thalion.ttio.transport.ArrowIpcCodec` for
cross-language byte-equivalence of the IPC payload. The Arrow IPC
format is endian-independent and the schemas are declarative, so
identical inputs produce identical bytes in Java and Python.

See transport-spec
:doc:`/transport-spec` sections 4.19 (IDENTIFICATIONS_TABLE 0x16),
4.20 (QUANTIFICATIONS_TABLE 0x17), and 4.22
(SUBJECT_METADATA 0x19 + SAMPLE_METADATA 0x1A — Stage 6).

Schemas
-------

``IDENTIFICATION_SCHEMA``::

    run_name             : utf8
    spectrum_index       : int32
    chemical_entity      : utf8
    confidence_score     : float64
    evidence_chain_json  : utf8        # JSON array of evidence strings

``QUANTIFICATION_SCHEMA``::

    chemical_entity      : utf8
    sample_ref           : utf8
    abundance            : float64
    normalization_method : utf8
    unit                 : utf8

``SUBJECT_SCHEMA`` (Stage 6, design spec §6.1)::

    external_id          : utf8  (notNullable)
    project              : utf8  (nullable)
    sex                  : utf8  (nullable)
    birth_year           : int32 (nullable)   # widened from on-disk int64
    attributes_json      : utf8  (nullable)

``SAMPLE_SCHEMA`` (Stage 6, design spec §6.2)::

    sample_id            : utf8  (notNullable)
    subject_external_id  : utf8  (nullable)
    sample_kind          : utf8  (nullable)
    collected_at         : int64 (nullable)
    attributes_json      : utf8  (nullable)

Notes
-----
``evidence_chain`` is serialised to a compact JSON array of strings
matching Java's emit format: ``[]`` for an empty list,
``["a","b"]`` (no whitespace, double-quoted) otherwise. ``json.dumps``
with ``separators=(",", ":")`` produces exactly this shape.

**Subject / Sample null handling** (transport-spec §11 + Java's
:class:`ArrowIpcCodec` Javadoc, commit ``dd211600``):

* Optional string columns (``project``, ``sex``,
  ``subject_external_id``, ``sample_kind``) emit Arrow null when the
  source is the empty string ``""``. On read, Arrow null decodes back
  to ``""`` so the dataclasses' "empty-string = unset" invariant is
  preserved end to end.
* Optional integer columns (``birth_year``, ``collected_at``) emit
  Arrow null when the source value is the sentinel ``0``; Arrow null
  decodes back to ``0``. This mirrors the on-disk sentinel-0
  convention so Python and Java implementations interoperate
  byte-for-byte at the value level.
* The ``attributes_json`` column is **always** emitted with a value
  (``"{}"`` for empty maps), never Arrow null; its semantics are
  well-defined as a sort-keys JSON object.

Cross-language equivalents
--------------------------
Java: :class:`global.thalion.ttio.transport.ArrowIpcCodec`.
"""
from __future__ import annotations

import io
import json
from typing import List

import pyarrow as pa
import pyarrow.ipc

from ttio.identification import Identification
from ttio.quantification import Quantification
from ttio.sample import Sample
from ttio.subject import Subject


_IDENTIFICATION_SCHEMA = pa.schema(
    [
        pa.field("run_name", pa.string()),
        pa.field("spectrum_index", pa.int32()),
        pa.field("chemical_entity", pa.string()),
        pa.field("confidence_score", pa.float64()),
        pa.field("evidence_chain_json", pa.string()),
    ]
)

_QUANTIFICATION_SCHEMA = pa.schema(
    [
        pa.field("chemical_entity", pa.string()),
        pa.field("sample_ref", pa.string()),
        pa.field("abundance", pa.float64()),
        pa.field("normalization_method", pa.string()),
        pa.field("unit", pa.string()),
    ]
)

# Stage 6 (transport-spec v0.11, Deferral 2): SUBJECT_METADATA (0x19)
# and SAMPLE_METADATA (0x1A) payload schemas. The ``external_id`` /
# ``sample_id`` PK columns are nullable=False; every other column is
# nullable to express the spec §11 "absent value" convention. Schemas
# must match Java's ``ArrowIpcCodec.SUBJECT_SCHEMA`` / ``SAMPLE_SCHEMA``
# field names exactly for cross-lang IPC reads.
_SUBJECT_SCHEMA = pa.schema(
    [
        pa.field("external_id",     pa.string(), nullable=False),
        pa.field("project",         pa.string(), nullable=True),
        pa.field("sex",             pa.string(), nullable=True),
        pa.field("birth_year",      pa.int32(),  nullable=True),
        pa.field("attributes_json", pa.string(), nullable=True),
    ]
)

_SAMPLE_SCHEMA = pa.schema(
    [
        pa.field("sample_id",           pa.string(), nullable=False),
        pa.field("subject_external_id", pa.string(), nullable=True),
        pa.field("sample_kind",         pa.string(), nullable=True),
        pa.field("collected_at",        pa.int64(),  nullable=True),
        pa.field("attributes_json",     pa.string(), nullable=True),
    ]
)


def encode_identifications(rows: List[Identification]) -> bytes:
    """Encode a list of :class:`~ttio.identification.Identification`
    rows as an Arrow IPC stream.

    Empty input yields a valid empty IPC stream that round-trips to
    an empty list.
    """
    cols = {
        "run_name": [r.run_name for r in rows],
        "spectrum_index": [int(r.spectrum_index) for r in rows],
        "chemical_entity": [r.chemical_entity for r in rows],
        "confidence_score": [float(r.confidence_score) for r in rows],
        "evidence_chain_json": [_json_list(r.evidence_chain) for r in rows],
    }
    batch = pa.RecordBatch.from_pydict(cols, schema=_IDENTIFICATION_SCHEMA)
    sink = io.BytesIO()
    with pa.ipc.new_stream(sink, _IDENTIFICATION_SCHEMA) as writer:
        writer.write_batch(batch)
    return sink.getvalue()


def decode_identifications(ipc: bytes) -> List[Identification]:
    """Decode an Arrow IPC stream into a list of
    :class:`~ttio.identification.Identification`."""
    if not ipc:
        return []
    reader = pa.ipc.open_stream(io.BytesIO(ipc))
    out: List[Identification] = []
    for batch in reader:
        cols = batch.to_pydict()
        for i in range(batch.num_rows):
            out.append(
                Identification(
                    run_name=cols["run_name"][i],
                    spectrum_index=cols["spectrum_index"][i],
                    chemical_entity=cols["chemical_entity"][i],
                    confidence_score=cols["confidence_score"][i],
                    evidence_chain=_parse_list(cols["evidence_chain_json"][i]),
                )
            )
    return out


def encode_quantifications(rows: List[Quantification]) -> bytes:
    """Encode a list of :class:`~ttio.quantification.Quantification`
    rows as an Arrow IPC stream.

    Empty input yields a valid empty IPC stream.
    """
    cols = {
        "chemical_entity": [r.chemical_entity for r in rows],
        "sample_ref": [r.sample_ref for r in rows],
        "abundance": [float(r.abundance) for r in rows],
        "normalization_method": [r.normalization_method for r in rows],
        "unit": [r.unit for r in rows],
    }
    batch = pa.RecordBatch.from_pydict(cols, schema=_QUANTIFICATION_SCHEMA)
    sink = io.BytesIO()
    with pa.ipc.new_stream(sink, _QUANTIFICATION_SCHEMA) as writer:
        writer.write_batch(batch)
    return sink.getvalue()


def decode_quantifications(ipc: bytes) -> List[Quantification]:
    """Decode an Arrow IPC stream into a list of
    :class:`~ttio.quantification.Quantification`."""
    if not ipc:
        return []
    reader = pa.ipc.open_stream(io.BytesIO(ipc))
    out: List[Quantification] = []
    for batch in reader:
        cols = batch.to_pydict()
        for i in range(batch.num_rows):
            out.append(
                Quantification(
                    chemical_entity=cols["chemical_entity"][i],
                    sample_ref=cols["sample_ref"][i],
                    abundance=cols["abundance"][i],
                    normalization_method=cols["normalization_method"][i],
                    unit=cols["unit"][i],
                )
            )
    return out


def _json_list(items) -> str:
    """Serialise a list of strings to JSON matching Java's emit:
    ``[]`` for an empty list, ``["a","b"]`` (no whitespace,
    double-quoted) for a non-empty list."""
    if not items:
        return "[]"
    return json.dumps(list(items), separators=(",", ":"))


def _parse_list(s: str) -> List[str]:
    """Parse the JSON array emitted by :func:`_json_list`."""
    if not s or s == "[]":
        return []
    return list(json.loads(s))


# ── Stage 6 (transport-spec §4.22 / 0x19 SUBJECT_METADATA) ──

def encode_subjects(rows: List[Subject]) -> bytes:
    """Encode a list of :class:`~ttio.subject.Subject` rows as an
    Arrow IPC stream per transport-spec §4.22.

    Empty input yields a valid empty IPC stream that round-trips to
    an empty list. See the module docstring for null-handling rules:
    optional strings (``project`` / ``sex``) map empty-string to Arrow
    null; ``birth_year`` sentinel ``0`` maps to Arrow null;
    ``attributes_json`` is always present (``"{}"`` for empty maps).

    Java parity: :meth:`ArrowIpcCodec.encodeSubjects`.
    """
    cols = {
        "external_id":     [r.external_id for r in rows],
        "project":         [_str_or_null(r.project) for r in rows],
        "sex":             [_str_or_null(r.sex) for r in rows],
        "birth_year":      [_int_or_null(r.birth_year) for r in rows],
        "attributes_json": [r.attributes_json() for r in rows],
    }
    batch = pa.RecordBatch.from_pydict(cols, schema=_SUBJECT_SCHEMA)
    sink = io.BytesIO()
    with pa.ipc.new_stream(sink, _SUBJECT_SCHEMA) as writer:
        writer.write_batch(batch)
    return sink.getvalue()


def decode_subjects(ipc: bytes) -> List[Subject]:
    """Decode an Arrow IPC stream into a list of
    :class:`~ttio.subject.Subject`.

    Arrow null in ``project`` / ``sex`` decodes to ``""``; Arrow null
    in ``birth_year`` decodes to ``0``. Java parity:
    :meth:`ArrowIpcCodec.decodeSubjects`.
    """
    if not ipc:
        return []
    reader = pa.ipc.open_stream(io.BytesIO(ipc))
    out: List[Subject] = []
    for batch in reader:
        cols = batch.to_pydict()
        for i in range(batch.num_rows):
            out.append(
                Subject(
                    external_id=cols["external_id"][i],
                    project=_or_empty(cols["project"][i]),
                    sex=_or_empty(cols["sex"][i]),
                    birth_year=_or_zero(cols["birth_year"][i]),
                    attributes=_parse_attributes_json(
                        cols["attributes_json"][i]
                    ),
                )
            )
    return out


# ── Stage 6 (transport-spec §4.22 / 0x1A SAMPLE_METADATA) ──

def encode_samples(rows: List[Sample]) -> bytes:
    """Encode a list of :class:`~ttio.sample.Sample` rows as an Arrow
    IPC stream per transport-spec §4.22.

    Empty input yields a valid empty IPC stream. Null-handling rules
    match :func:`encode_subjects`: optional strings map empty-string
    to Arrow null; ``collected_at`` sentinel ``0`` maps to Arrow null;
    ``attributes_json`` is always present (``"{}"`` for empty).

    Java parity: :meth:`ArrowIpcCodec.encodeSamples`.
    """
    cols = {
        "sample_id":           [r.sample_id for r in rows],
        "subject_external_id": [_str_or_null(r.subject_external_id) for r in rows],
        "sample_kind":         [_str_or_null(r.sample_kind) for r in rows],
        "collected_at":        [_int_or_null(r.collected_at) for r in rows],
        "attributes_json":     [r.attributes_json() for r in rows],
    }
    batch = pa.RecordBatch.from_pydict(cols, schema=_SAMPLE_SCHEMA)
    sink = io.BytesIO()
    with pa.ipc.new_stream(sink, _SAMPLE_SCHEMA) as writer:
        writer.write_batch(batch)
    return sink.getvalue()


def decode_samples(ipc: bytes) -> List[Sample]:
    """Decode an Arrow IPC stream into a list of
    :class:`~ttio.sample.Sample`.

    Arrow null in ``subject_external_id`` / ``sample_kind`` decodes to
    ``""``; Arrow null in ``collected_at`` decodes to ``0``. Java
    parity: :meth:`ArrowIpcCodec.decodeSamples`.
    """
    if not ipc:
        return []
    reader = pa.ipc.open_stream(io.BytesIO(ipc))
    out: List[Sample] = []
    for batch in reader:
        cols = batch.to_pydict()
        for i in range(batch.num_rows):
            out.append(
                Sample(
                    sample_id=cols["sample_id"][i],
                    subject_external_id=_or_empty(
                        cols["subject_external_id"][i]
                    ),
                    sample_kind=_or_empty(cols["sample_kind"][i]),
                    collected_at=_or_zero(cols["collected_at"][i]),
                    attributes=_parse_attributes_json(
                        cols["attributes_json"][i]
                    ),
                )
            )
    return out


def _str_or_null(s: str | None):
    """Optional-string encoder: empty-string ↔ Arrow null on the wire.
    Mirrors Java's ``ArrowIpcCodec.setOptionalString``."""
    if s is None or s == "":
        return None
    return s


def _int_or_null(v: int | None):
    """Optional-int encoder: sentinel ``0`` ↔ Arrow null on the wire.
    Mirrors Java's ``birthYear == 0L`` / ``collectedAt == 0L`` checks."""
    if v is None or int(v) == 0:
        return None
    return int(v)


def _or_empty(s) -> str:
    """Decode helper: Arrow null → ``""``."""
    return "" if s is None else str(s)


def _or_zero(v) -> int:
    """Decode helper: Arrow null → ``0``."""
    return 0 if v is None else int(v)


def _parse_attributes_json(blob) -> dict[str, str]:
    """Parse an ``attributes_json`` value into a ``dict[str, str]``.
    ``None`` (defensive — schema marks the column nullable even though
    the encoder always emits a value) and ``"{}"`` decode to ``{}``."""
    if blob is None or blob == "" or blob == "{}":
        return {}
    parsed = json.loads(blob)
    if not isinstance(parsed, dict):
        return {}
    return {str(k): str(v) for k, v in parsed.items()}


__all__ = [
    "encode_identifications",
    "decode_identifications",
    "encode_quantifications",
    "decode_quantifications",
    "encode_subjects",
    "decode_subjects",
    "encode_samples",
    "decode_samples",
]
