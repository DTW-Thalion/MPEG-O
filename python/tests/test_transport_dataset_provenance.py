"""v0.11 Task 2.5 (transport-spec §4.21): exercise the
``DATASET_PROVENANCE`` (0x18) packet on :class:`TransportWriter` +
:class:`TransportReader`.

Wire layout per §4.21::

    record_count:        uint32
    # repeated record_count times:
    timestamp_unix:      int64
    software_length:     uint16
    software:            bytes[software_length]      # UTF-8
    parameters_length:   uint16
    parameters_json:     bytes[parameters_length]    # UTF-8 JSON
    input_refs_length:   uint16
    input_refs_csv:      bytes[input_refs_length]    # UTF-8 comma-joined
    output_refs_length:  uint16
    output_refs_csv:     bytes[output_refs_length]   # UTF-8 comma-joined

All multi-byte integers are LITTLE-ENDIAN (spec §1.7).

Python parity for Java's ``TransportDatasetProvenanceTest`` (commit
``563e09c3``).

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import io
import struct
from pathlib import Path

from ttio.provenance import ProvenanceRecord
from ttio.spectral_dataset import SpectralDataset
from ttio.transport.codec import TransportReader, TransportWriter
from ttio.transport.packets import PacketType, TRANSPORT_V0_11_FEATURE


def _read_le_string(buf: bytes, offset: int, width: int) -> tuple[str, int]:
    """Read a length-prefixed UTF-8 string at ``offset``. ``width``
    selects uint16 (=2) or uint32 (=4) prefix."""
    if width == 2:
        (length,) = struct.unpack_from("<H", buf, offset)
        offset += 2
    else:
        (length,) = struct.unpack_from("<I", buf, offset)
        offset += 4
    s = buf[offset:offset + length].decode("utf-8")
    return s, offset + length


def test_write_dataset_provenance_emits_single_packet_with_record_count() -> None:
    """Writer's low-level helper emits a single 0x18 packet whose
    payload matches §4.21 exactly."""
    r1 = ProvenanceRecord(
        timestamp_unix=1700000000,
        software="TTI-O Python 1.0.0",
        parameters={"threshold": "0.5"},
        input_refs=["file:///in.raw", "file:///in2.raw"],
        output_refs=["file:///out.tio"],
    )
    r2 = ProvenanceRecord(
        timestamp_unix=1700000100,
        software="step 2",
        parameters={},
        input_refs=[],
        output_refs=["file:///final.tio"],
    )

    out = io.BytesIO()
    with TransportWriter(out) as w:
        w.write_stream_header(
            format_version="1.2",
            title="prov-test",
            isa_investigation="isa",
            features=[],
            n_datasets=0,
        )
        w.write_dataset_provenance([r1, r2])
        w.write_end_of_stream()

    r = TransportReader(io.BytesIO(out.getvalue()))
    records = r.records_for_test()
    assert len(records) == 3, (
        f"expected StreamHeader + DatasetProvenance + EndOfStream, "
        f"got {len(records)}"
    )
    assert records[1].header.packet_type == int(
        PacketType.DATASET_PROVENANCE
    )

    payload = records[1].payload
    off = 0
    (record_count,) = struct.unpack_from("<I", payload, off)
    off += 4
    assert record_count == 2

    # Record 0.
    (ts0,) = struct.unpack_from("<q", payload, off)
    off += 8
    assert ts0 == 1700000000
    software0, off = _read_le_string(payload, off, 2)
    assert software0 == "TTI-O Python 1.0.0"
    params0, off = _read_le_string(payload, off, 2)
    assert "threshold" in params0
    assert "0.5" in params0
    inputs0, off = _read_le_string(payload, off, 2)
    assert inputs0 == "file:///in.raw,file:///in2.raw"
    outputs0, off = _read_le_string(payload, off, 2)
    assert outputs0 == "file:///out.tio"

    # Record 1 (empty params/inputs).
    (ts1,) = struct.unpack_from("<q", payload, off)
    off += 8
    assert ts1 == 1700000100
    software1, off = _read_le_string(payload, off, 2)
    assert software1 == "step 2"
    params1, off = _read_le_string(payload, off, 2)
    assert params1 == "{}", (
        f"empty parameters must render as '{{}}', got {params1!r}"
    )
    inputs1, off = _read_le_string(payload, off, 2)
    assert inputs1 == "", (
        f"empty input_refs must render as '', got {inputs1!r}"
    )
    outputs1, off = _read_le_string(payload, off, 2)
    assert outputs1 == "file:///final.tio"
    assert off == len(payload), (
        "payload must contain only the 2 records, no trailing bytes"
    )


def test_write_dataset_provenance_zero_records_emits_no_packet() -> None:
    """An empty record list should not emit a 0x18 packet at all
    (spec §5.4 "zero or more")."""
    out = io.BytesIO()
    with TransportWriter(out) as w:
        w.write_stream_header(
            format_version="1.2",
            title="empty",
            isa_investigation="",
            features=[],
            n_datasets=0,
        )
        w.write_dataset_provenance([])
        w.write_end_of_stream()

    r = TransportReader(io.BytesIO(out.getvalue()))
    for rec in r.records_for_test():
        assert rec.header.packet_type != int(PacketType.DATASET_PROVENANCE), (
            "empty record list must not emit DATASET_PROVENANCE"
        )


def test_write_dataset_emits_dataset_provenance_when_present(
    tmp_path: Path,
) -> None:
    """``write_dataset`` on a ``.tio`` carrying provenance emits
    exactly one DATASET_PROVENANCE packet (in the v0.11 prelude, after
    ENCRYPTION_ALGORITHM, before reference groups per §5.4) AND flips
    the v0.11 feature flag."""
    src = tmp_path / "prov.tio"
    _build_provenance_only(src)
    tis = tmp_path / "prov.tis"

    with SpectralDataset.open(src) as ds:
        assert ds.provenance(), (
            "fixture precondition: dataset must carry provenance"
        )
        with tis.open("wb") as out, TransportWriter(out) as w:
            w.write_dataset(ds)

    r = TransportReader(io.BytesIO(tis.read_bytes()))
    records = r.records_for_test()
    # StreamHeader features must include transport_v0_11.
    from ttio.transport.codec import _decode_stream_header
    sh = _decode_stream_header(records[0].payload)
    assert TRANSPORT_V0_11_FEATURE in sh["features"], (
        "StreamHeader must carry transport_v0_11 feature flag"
    )

    prov_count = sum(
        1 for rec in records
        if rec.header.packet_type == int(PacketType.DATASET_PROVENANCE)
    )
    assert prov_count == 1, (
        f"write_dataset on provenance-bearing .tio must emit exactly "
        f"one DATASET_PROVENANCE packet, got {prov_count}"
    )


def test_write_dataset_no_packet_when_provenance_empty(
    tmp_path: Path,
) -> None:
    """``write_dataset`` on a ``.tio`` with NO provenance emits NO
    0x18 packet."""
    src = tmp_path / "plain.tio"
    SpectralDataset.write_minimal(
        src,
        title="plain",
        isa_investigation_id="",
        runs={},
    )
    tis = tmp_path / "plain.tis"
    with SpectralDataset.open(src) as ds:
        assert not ds.provenance(), (
            "fixture precondition: dataset must carry no provenance"
        )
        with tis.open("wb") as out, TransportWriter(out) as w:
            w.write_dataset(ds)

    r = TransportReader(io.BytesIO(tis.read_bytes()))
    for rec in r.records_for_test():
        assert rec.header.packet_type != int(PacketType.DATASET_PROVENANCE), (
            "empty-provenance dataset must not emit DATASET_PROVENANCE"
        )


def test_dataset_provenance_round_trips_three_records(tmp_path: Path) -> None:
    """End-to-end round-trip preserves record count + per-record
    fields + record order."""
    src = tmp_path / "src.tio"
    _build_provenance_only(src)
    tis = tmp_path / "src.tis"
    rt = tmp_path / "rt.tio"

    with SpectralDataset.open(src) as ds:
        with tis.open("wb") as out, TransportWriter(out) as w:
            w.write_dataset(ds)

    with TransportReader(io.BytesIO(tis.read_bytes())) as r:
        materialised = r.read_to_dataset(output_path=rt)
        materialised.close()

    with SpectralDataset.open(src) as a, SpectralDataset.open(rt) as b:
        prov_a = a.provenance()
        prov_b = b.provenance()
        assert len(prov_a) == len(prov_b), (
            f"record count mismatch: src={len(prov_a)}, rt={len(prov_b)}"
        )
        for i, (ra, rb) in enumerate(zip(prov_a, prov_b)):
            assert ra.timestamp_unix == rb.timestamp_unix, (
                f"timestamp_unix mismatch at record {i}: "
                f"{ra.timestamp_unix} vs {rb.timestamp_unix}"
            )
            assert ra.software == rb.software, (
                f"software mismatch at record {i}"
            )
            assert list(ra.input_refs) == list(rb.input_refs), (
                f"input_refs mismatch at record {i}"
            )
            assert list(ra.output_refs) == list(rb.output_refs), (
                f"output_refs mismatch at record {i}"
            )
            # parameters: compare as dicts (the on-disk JSON form may
            # reorder keys, but the dict contents must match).
            assert dict(ra.parameters) == dict(rb.parameters), (
                f"parameters mismatch at record {i}"
            )


def _build_provenance_only(target: Path) -> None:
    """Build a minimal ``.tio`` carrying 3 provenance records
    (1 with non-empty params + multi-element refs, 1 with all-empty
    fields, 1 with single-element refs). Exercises every empty/non-
    empty combination of the v0.11 wire layout."""
    r1 = ProvenanceRecord(
        timestamp_unix=1700000000,
        software="TTI-O Python 1.0.0",
        parameters={"mode": "strict", "threshold": "0.5"},
        input_refs=["file:///in.raw", "file:///in2.raw"],
        output_refs=["file:///out.tio"],
    )
    r2 = ProvenanceRecord(
        timestamp_unix=1700000100,
        software="downstream step",
        parameters={},
        input_refs=[],
        output_refs=[],
    )
    r3 = ProvenanceRecord(
        timestamp_unix=1700000200,
        software="final step",
        parameters={"k": "v"},
        input_refs=["file:///r2-out.tio"],
        output_refs=["file:///final.tio"],
    )
    SpectralDataset.write_minimal(
        target,
        title="provenance_only",
        isa_investigation_id="",
        runs={},
        provenance=[r1, r2, r3],
    )
