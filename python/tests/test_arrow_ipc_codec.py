"""Python Arrow IPC codec — parity with Java ArrowIpcCodec (commit dc89f470)."""
from __future__ import annotations

import io

from ttio.identification import Identification
from ttio.quantification import Quantification
from ttio.transport.arrow_ipc import (
    decode_identifications,
    decode_quantifications,
    encode_identifications,
    encode_quantifications,
)


def test_identifications_round_trip():
    rows = [
        Identification(
            run_name="run1",
            spectrum_index=42,
            chemical_entity="CompoundA",
            confidence_score=0.91,
            evidence_chain=["e1", "e2"],
        ),
        Identification(
            run_name="run1",
            spectrum_index=43,
            chemical_entity="CompoundB",
            confidence_score=0.85,
            evidence_chain=["e3"],
        ),
    ]
    ipc = encode_identifications(rows)
    assert len(ipc) > 0
    out = decode_identifications(ipc)
    assert len(out) == 2
    assert out[0].chemical_entity == "CompoundA"
    assert out[0].evidence_chain == ["e1", "e2"]
    assert out[1].spectrum_index == 43


def test_empty_identifications():
    assert decode_identifications(encode_identifications([])) == []


def test_quantifications_round_trip():
    rows = [
        Quantification(
            chemical_entity="GeneA",
            sample_ref="bio1",
            abundance=12.5,
            normalization_method="intensity-sum",
            unit="counts",
        )
    ]
    out = decode_quantifications(encode_quantifications(rows))
    assert len(out) == 1
    assert out[0].chemical_entity == "GeneA"
    assert out[0].abundance == 12.5


def test_empty_quantifications():
    assert decode_quantifications(encode_quantifications([])) == []


def test_cross_lang_schema_field_names():
    """Smoke test the Arrow schema column names are exactly what Java emits."""
    import pyarrow.ipc

    ipc = encode_identifications(
        [
            Identification(
                run_name="r",
                spectrum_index=0,
                chemical_entity="x",
                confidence_score=0.0,
                evidence_chain=[],
            )
        ]
    )
    reader = pyarrow.ipc.open_stream(io.BytesIO(ipc))
    schema = reader.schema
    expected = [
        "run_name",
        "spectrum_index",
        "chemical_entity",
        "confidence_score",
        "evidence_chain_json",
    ]
    assert schema.names == expected, (
        f"Schema columns must match Java: expected {expected}, got {schema.names}"
    )
