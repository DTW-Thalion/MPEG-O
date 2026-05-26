"""Stage 6 / Task 6.3 (transport-spec v0.11 §4.22):
SUBJECT_METADATA (0x19) + SAMPLE_METADATA (0x1A) packets through
:class:`TransportWriter` + :class:`TransportReader`.

Wire layout per §4.22::

    arrow_ipc_length:    uint32
    arrow_ipc:           bytes[arrow_ipc_length]   # self-describing Arrow IPC

All multi-byte integers LITTLE-ENDIAN (spec §1.7).

Java parity: ``TransportSubjectsSamplesTest`` (commit ``dd211600``).
"""
from __future__ import annotations

import io
from pathlib import Path

from ttio.sample import Sample
from ttio.spectral_dataset import SpectralDataset
from ttio.subject import Subject
from ttio.transport.codec import TransportReader, TransportWriter
from ttio.transport.packets import PacketType


def _build_subjects_only(target: Path) -> Path:
    """Mirror Java's ``FixtureBuilder.buildSubjectsOnly``."""
    subjects = [
        Subject(
            external_id="S1",
            project="STUDY-A",
            sex="F",
            birth_year=1985,
            attributes={"site": "NYC"},
        ),
        Subject(
            external_id="S2",
            project="STUDY-A",
            sex="M",
            birth_year=1990,
            attributes={},
        ),
    ]
    SpectralDataset.write_minimal(
        target,
        title="subjects_only",
        isa_investigation_id="",
        runs={},
        subjects=subjects,
    )
    return target


def _build_samples_only(target: Path) -> Path:
    """Mirror Java's ``FixtureBuilder.buildSamplesOnly``."""
    samples = [
        Sample(
            sample_id="bio1",
            subject_external_id="",  # standalone sample
            sample_kind="tissue",
            collected_at=1700000000,
            attributes={"ph": "7.4"},
        ),
        Sample(
            sample_id="bio2",
            subject_external_id="",
            sample_kind="plasma",
            collected_at=0,  # sentinel
            attributes={},
        ),
    ]
    SpectralDataset.write_minimal(
        target,
        title="samples_only",
        isa_investigation_id="",
        runs={},
        samples=samples,
    )
    return target


def test_subjects_only_round_trip_through_writer_and_reader(
    tmp_path: Path,
) -> None:
    """Round-trip a subjects-only fixture through write_dataset +
    materialize and verify the rows survive."""
    src = _build_subjects_only(tmp_path / "src.tio")
    tis = tmp_path / "src.tis"
    rt = tmp_path / "rt.tio"

    with SpectralDataset.open(src) as ds:
        with open(tis, "wb") as out, TransportWriter(out) as w:
            w.write_dataset(ds)

    with TransportReader(tis) as r:
        materialised = r.read_to_dataset(output_path=rt)
        materialised.close()

    with SpectralDataset.open(src) as a, SpectralDataset.open(rt) as b:
        subs_a = a.subjects
        subs_b = b.subjects
        assert len(subs_a) == len(subs_b) == 2
        a_by_id = {s.external_id: s for s in subs_a}
        b_by_id = {s.external_id: s for s in subs_b}
        for ext_id in a_by_id:
            assert a_by_id[ext_id].project == b_by_id[ext_id].project
            assert a_by_id[ext_id].sex == b_by_id[ext_id].sex
            assert a_by_id[ext_id].birth_year == b_by_id[ext_id].birth_year
            assert a_by_id[ext_id].attributes == b_by_id[ext_id].attributes
        # Cross-cutting: samples must remain empty.
        assert a.samples == []
        assert b.samples == []


def test_samples_only_round_trip_through_writer_and_reader(
    tmp_path: Path,
) -> None:
    """Round-trip a samples-only fixture; sentinel-0 collected_at
    survives the Arrow null-encode/decode dance."""
    src = _build_samples_only(tmp_path / "src.tio")
    tis = tmp_path / "src.tis"
    rt = tmp_path / "rt.tio"

    with SpectralDataset.open(src) as ds:
        with open(tis, "wb") as out, TransportWriter(out) as w:
            w.write_dataset(ds)

    with TransportReader(tis) as r:
        materialised = r.read_to_dataset(output_path=rt)
        materialised.close()

    with SpectralDataset.open(src) as a, SpectralDataset.open(rt) as b:
        samp_a = a.samples
        samp_b = b.samples
        assert len(samp_a) == len(samp_b) == 2
        a_by_id = {s.sample_id: s for s in samp_a}
        b_by_id = {s.sample_id: s for s in samp_b}
        for sid in a_by_id:
            assert a_by_id[sid].subject_external_id == b_by_id[sid].subject_external_id
            assert a_by_id[sid].sample_kind == b_by_id[sid].sample_kind
            assert a_by_id[sid].collected_at == b_by_id[sid].collected_at
            assert a_by_id[sid].attributes == b_by_id[sid].attributes
        # bio2 sentinel collected_at == 0 must survive.
        assert b_by_id["bio2"].collected_at == 0
        # Cross-cutting: subjects must remain empty.
        assert a.subjects == []
        assert b.subjects == []


def test_empty_lists_emit_no_packets(tmp_path: Path) -> None:
    """Spec §5.4 step 5 says "zero or more"; empty subject/sample lists
    MUST NOT emit 0x19 or 0x1A packets on the wire.

    Uses a reference-only fixture to ensure the v0.11 prelude IS
    emitted (so we know we're seeing real prelude content), and
    verifies neither 0x19 nor 0x1A appears.
    """
    src = tmp_path / "src.tio"
    SpectralDataset.write_minimal(
        src,
        title="ref_only",
        isa_investigation_id="",
        runs={},
    )
    # Add a small reference to ensure v0.11 prelude triggers.
    from ttio.genomic.reference_import import ReferenceImport
    ref = ReferenceImport(
        uri="ref-only-fixture-v1",
        chromosomes=["chr1"],
        sequences=[b"ACGTACGT"],
    )
    with SpectralDataset.open(src, writable=True) as ds_w:
        ref.write_to_dataset(ds_w)

    out = io.BytesIO()
    with SpectralDataset.open(src) as ds:
        with TransportWriter(out) as w:
            w.write_dataset(ds)

    r = TransportReader(io.BytesIO(out.getvalue()))
    records = r.records_for_test()
    for rec in records:
        assert rec.header.packet_type != int(PacketType.SUBJECT_METADATA), (
            "ref-only fixture must not emit SUBJECT_METADATA"
        )
        assert rec.header.packet_type != int(PacketType.SAMPLE_METADATA), (
            "ref-only fixture must not emit SAMPLE_METADATA"
        )


def test_subjects_emit_before_samples_per_spec_5_4_3(tmp_path: Path) -> None:
    """Both populated: exactly one 0x19 followed by exactly one 0x1A
    (per spec §5.4 step 5, subjects-first ordering — so a downstream
    reader sees subjects ahead of any samples that soft-FK into them).
    """
    src = tmp_path / "both.tio"
    subjects = [
        Subject(external_id="S1", project="P", sex="F", birth_year=1980),
    ]
    samples = [
        Sample(
            sample_id="bio1",
            subject_external_id="S1",
            sample_kind="tissue",
            collected_at=1700000000,
        ),
    ]
    SpectralDataset.write_minimal(
        src,
        title="both",
        isa_investigation_id="",
        runs={},
        subjects=subjects,
        samples=samples,
    )

    out = io.BytesIO()
    with SpectralDataset.open(src) as ds:
        with TransportWriter(out) as w:
            w.write_dataset(ds)

    r = TransportReader(io.BytesIO(out.getvalue()))
    records = r.records_for_test()
    subj_idx = -1
    samp_idx = -1
    for i, rec in enumerate(records):
        t = rec.header.packet_type
        if t == int(PacketType.SUBJECT_METADATA):
            assert subj_idx == -1, "duplicate SUBJECT_METADATA"
            subj_idx = i
        elif t == int(PacketType.SAMPLE_METADATA):
            assert samp_idx == -1, "duplicate SAMPLE_METADATA"
            samp_idx = i
    assert subj_idx > 0, "expected exactly one SUBJECT_METADATA packet"
    assert samp_idx > 0, "expected exactly one SAMPLE_METADATA packet"
    assert subj_idx < samp_idx, (
        "per spec §5.4 step 5: SUBJECT_METADATA must precede SAMPLE_METADATA"
    )
