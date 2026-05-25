"""Apache Arrow IPC encode/decode for transport-spec v0.11 tabular packets.

Mirrors Java's :class:`global.thalion.ttio.transport.ArrowIpcCodec` for
cross-language byte-equivalence of the IPC payload. The Arrow IPC
format is endian-independent and the schemas are declarative, so
identical inputs produce identical bytes in Java and Python.

See transport-spec
:doc:`/transport-spec` sections 4.19 (IDENTIFICATIONS_TABLE 0x16) and
4.20 (QUANTIFICATIONS_TABLE 0x17).

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

Notes
-----
``evidence_chain`` is serialised to a compact JSON array of strings
matching Java's emit format: ``[]`` for an empty list,
``["a","b"]`` (no whitespace, double-quoted) otherwise. ``json.dumps``
with ``separators=(",", ":")`` produces exactly this shape.

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


__all__ = [
    "encode_identifications",
    "decode_identifications",
    "encode_quantifications",
    "decode_quantifications",
]
