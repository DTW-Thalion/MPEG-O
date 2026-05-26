"""v0.11 Task 2.7 (transport-spec §4.19 / §4.20): exercise the
``IDENTIFICATIONS_TABLE`` (0x16) and ``QUANTIFICATIONS_TABLE`` (0x17)
packets on :class:`TransportWriter` + :class:`TransportReader`.

Wire layout per §4.19 / §4.20::

    arrow_ipc_length:    uint32
    arrow_ipc:           bytes[arrow_ipc_length]   # self-describing Arrow IPC

All multi-byte integers LITTLE-ENDIAN (spec §1.7).

Python parity for Java's
``TransportIdentificationsQuantificationsTest`` (commit ``a6faab16``).

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import io
from pathlib import Path

from ttio.identification import Identification
from ttio.quantification import Quantification
from ttio.spectral_dataset import SpectralDataset
from ttio.transport.codec import TransportReader, TransportWriter
from ttio.transport.packets import PacketType


def _build_identifications_only(target: Path) -> Path:
    """Mirror Java's ``FixtureBuilder.buildIdentificationsOnly``."""
    ids = [
        Identification(
            run_name="run1",
            spectrum_index=42,
            chemical_entity="CompoundA",
            confidence_score=0.91,
            evidence_chain=["evidence1", "evidence2"],
        ),
        Identification(
            run_name="run1",
            spectrum_index=43,
            chemical_entity="CompoundB",
            confidence_score=0.85,
            evidence_chain=["evidence3"],
        ),
    ]
    SpectralDataset.write_minimal(
        target,
        title="ids_only",
        isa_investigation_id="",
        runs={},
        identifications=ids,
    )
    return target


def _build_quantifications_only(target: Path) -> Path:
    """Mirror Java's ``FixtureBuilder.buildQuantificationsOnly``."""
    quants = [
        Quantification(
            chemical_entity="CompoundA",
            sample_ref="sample-1",
            abundance=12.5,
            normalization_method="intensity-sum",
            unit="counts",
        ),
        Quantification(
            chemical_entity="CompoundB",
            sample_ref="sample-1",
            abundance=7.3,
            normalization_method="intensity-sum",
            unit="counts",
        ),
    ]
    SpectralDataset.write_minimal(
        target,
        title="quants_only",
        isa_investigation_id="",
        runs={},
        quantifications=quants,
    )
    return target


def _build_reference_only(target: Path) -> Path:
    """A ``.tio`` carrying a single small reference and nothing else.

    Acts as the "no ids, no quants" fixture for the
    empty-list-emits-no-packet test.
    """
    from ttio.genomic.reference_import import ReferenceImport
    SpectralDataset.write_minimal(
        target,
        title="ref_only",
        isa_investigation_id="",
        runs={},
    )
    ref = ReferenceImport(
        uri="ref-only-fixture-v1",
        chromosomes=["chr1"],
        sequences=[b"ACGTACGT"],
    )
    with SpectralDataset.open(target, writable=True) as ds_w:
        ref.write_to_dataset(ds_w)
    return target


def test_identifications_table_round_trips_through_writer_and_reader(
    tmp_path: Path,
) -> None:
    """Round-trip an identifications-only fixture through writeDataset
    + materializeTo and verify the rows survive byte-for-byte."""
    src = _build_identifications_only(tmp_path / "src.tio")
    tis = tmp_path / "src.tis"
    rt = tmp_path / "rt.tio"

    with SpectralDataset.open(src) as ds:
        with open(tis, "wb") as out, TransportWriter(out) as w:
            w.write_dataset(ds)

    with TransportReader(tis) as r:
        materialised = r.read_to_dataset(output_path=rt)
        materialised.close()

    with SpectralDataset.open(src) as a, SpectralDataset.open(rt) as b:
        ids_a = a.identifications()
        ids_b = b.identifications()
        assert len(ids_a) == len(ids_b), (
            "identification row count must round-trip"
        )
        for ia, ib in zip(ids_a, ids_b):
            assert ia.chemical_entity == ib.chemical_entity
            assert abs(ia.confidence_score - ib.confidence_score) < 1e-9
            assert ia.evidence_chain == ib.evidence_chain
            assert ia.run_name == ib.run_name
            assert ia.spectrum_index == ib.spectrum_index
        # Cross-cutting: quants table must remain empty.
        assert a.quantifications() == []
        assert b.quantifications() == []


def test_quantifications_table_round_trips_through_writer_and_reader(
    tmp_path: Path,
) -> None:
    """Round-trip a quantifications-only fixture through writeDataset
    + materializeTo and verify the rows survive byte-for-byte."""
    src = _build_quantifications_only(tmp_path / "src.tio")
    tis = tmp_path / "src.tis"
    rt = tmp_path / "rt.tio"

    with SpectralDataset.open(src) as ds:
        with open(tis, "wb") as out, TransportWriter(out) as w:
            w.write_dataset(ds)

    with TransportReader(tis) as r:
        materialised = r.read_to_dataset(output_path=rt)
        materialised.close()

    with SpectralDataset.open(src) as a, SpectralDataset.open(rt) as b:
        quants_a = a.quantifications()
        quants_b = b.quantifications()
        assert len(quants_a) == len(quants_b), (
            "quantification row count must round-trip"
        )
        for qa, qb in zip(quants_a, quants_b):
            assert qa.chemical_entity == qb.chemical_entity
            assert qa.sample_ref == qb.sample_ref
            assert abs(qa.abundance - qb.abundance) < 1e-9
            assert qa.normalization_method == qb.normalization_method
            assert qa.unit == qb.unit
        # Cross-cutting: ids table must remain empty.
        assert a.identifications() == []
        assert b.identifications() == []


def test_empty_identifications_emits_no_packet(tmp_path: Path) -> None:
    """Spec §5.4 step 6 says "zero or more"; an empty list MUST NOT
    emit a 0x16 packet on the wire. The reference-only fixture acts
    as a stand-in for "no ids, no quants"."""
    src = _build_reference_only(tmp_path / "src.tio")
    out = io.BytesIO()
    with SpectralDataset.open(src) as ds:
        with TransportWriter(out) as w:
            w.write_dataset(ds)

    r = TransportReader(io.BytesIO(out.getvalue()))
    records = r.records_for_test()
    for rec in records:
        assert rec.header.packet_type != int(PacketType.IDENTIFICATIONS_TABLE), (
            "reference-only fixture must not emit IDENTIFICATIONS_TABLE"
        )
        assert rec.header.packet_type != int(PacketType.QUANTIFICATIONS_TABLE), (
            "reference-only fixture must not emit QUANTIFICATIONS_TABLE"
        )


def test_both_tables_emit_in_spec_order(tmp_path: Path) -> None:
    """With both ids and quants populated, the writer emits exactly
    one 0x16 followed by exactly one 0x17 (per §5.4 step 6,
    identifications-first ordering)."""
    src = tmp_path / "both.tio"
    ids = [
        Identification(
            run_name="run1",
            spectrum_index=0,
            chemical_entity="CompoundA",
            confidence_score=0.5,
            evidence_chain=["e1"],
        ),
    ]
    quants = [
        Quantification(
            chemical_entity="CompoundA",
            sample_ref="sample-1",
            abundance=1.0,
            normalization_method="intensity-sum",
            unit="counts",
        ),
    ]
    SpectralDataset.write_minimal(
        src,
        title="both",
        isa_investigation_id="",
        runs={},
        identifications=ids,
        quantifications=quants,
    )

    out = io.BytesIO()
    with SpectralDataset.open(src) as ds:
        with TransportWriter(out) as w:
            w.write_dataset(ds)

    r = TransportReader(io.BytesIO(out.getvalue()))
    records = r.records_for_test()
    id_idx = -1
    q_idx = -1
    for i, rec in enumerate(records):
        t = rec.header.packet_type
        if t == int(PacketType.IDENTIFICATIONS_TABLE):
            assert id_idx == -1, "duplicate IDENTIFICATIONS_TABLE"
            id_idx = i
        elif t == int(PacketType.QUANTIFICATIONS_TABLE):
            assert q_idx == -1, "duplicate QUANTIFICATIONS_TABLE"
            q_idx = i
    assert id_idx > 0, "expected exactly one IDENTIFICATIONS_TABLE packet"
    assert q_idx > 0, "expected exactly one QUANTIFICATIONS_TABLE packet"
    assert id_idx < q_idx, (
        "per spec §5.4 step 6: IDENTIFICATIONS_TABLE precedes "
        "QUANTIFICATIONS_TABLE"
    )
