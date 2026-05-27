"""Unit tests for :func:`ttio.transport.walker.walk_dataset`."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ttio.enums import AcquisitionMode, Polarity
from ttio.spectral_dataset import SpectralDataset, WrittenRun
from ttio.transport import (
    AccessUnitEvent,
    AUFilter,
    DatasetHeaderEvent,
    DatasetProvenanceEvent,
    EncryptionAlgorithmEvent,
    EndOfDatasetEvent,
    EndOfStreamEvent,
    IRImageEvent,
    IdentificationsTableEvent,
    ImageEvent,
    QuantificationsTableEvent,
    RamanImageEvent,
    ReferenceGroupEvent,
    SampleMetadataEvent,
    StreamHeaderEvent,
    SubjectMetadataEvent,
    walk_dataset,
)


def _make_fixture(path: Path, *, n_spectra: int = 5) -> Path:
    points = 3
    total = n_spectra * points
    mz = np.arange(total, dtype="<f8") + 100.0
    intensity = (np.arange(total, dtype="<f8") + 1.0) * 100.0
    offsets = np.arange(0, total, points, dtype="<u8")
    lengths = np.full(n_spectra, points, dtype="<u4")
    rts = np.linspace(1.0, float(n_spectra), n_spectra, dtype="<f8")
    ms_levels = np.array(
        [1 if i % 2 == 0 else 2 for i in range(n_spectra)], dtype="<i4"
    )
    polarities = np.full(n_spectra, int(Polarity.POSITIVE), dtype="<i4")
    precursor_mzs = np.array(
        [0.0 if ms_levels[i] == 1 else 500.0 + 10.0 * i
         for i in range(n_spectra)],
        dtype="<f8",
    )
    precursor_charges = np.array(
        [0 if ms_levels[i] == 1 else 2 for i in range(n_spectra)],
        dtype="<i4",
    )
    base_peak = np.array(
        [float(intensity[i * points:(i + 1) * points].max())
         for i in range(n_spectra)],
        dtype="<f8",
    )
    run = WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": mz, "intensity": intensity},
        offsets=offsets,
        lengths=lengths,
        retention_times=rts,
        ms_levels=ms_levels,
        polarities=polarities,
        precursor_mzs=precursor_mzs,
        precursor_charges=precursor_charges,
        base_peak_intensities=base_peak,
    )
    SpectralDataset.write_minimal(
        path,
        title="walker fixture",
        isa_investigation_id="ISA-WALKER",
        runs={"run_0001": run},
    )
    return path


@pytest.fixture
def ttio_fixture(tmp_path):
    return _make_fixture(tmp_path / "walker.tio")


def test_unfiltered_walk_emits_full_event_sequence(ttio_fixture):
    dataset = SpectralDataset.open(ttio_fixture)
    events = list(walk_dataset(dataset))
    # 1 StreamHeader + 1 DatasetHeader + 5 AUs + 1 EndOfDataset + 1 EOS.
    assert isinstance(events[0], StreamHeaderEvent)
    assert events[0].n_datasets == 1
    assert events[0].title == "walker fixture"
    assert isinstance(events[1], DatasetHeaderEvent)
    assert events[1].dataset_id == 1
    assert events[1].name == "run_0001"
    aus = [e for e in events if isinstance(e, AccessUnitEvent)]
    assert len(aus) == 5
    assert [e.au_sequence for e in aus] == [0, 1, 2, 3, 4]
    eods = [e for e in events if isinstance(e, EndOfDatasetEvent)]
    assert len(eods) == 1 and eods[0].final_au_sequence == 5
    assert isinstance(events[-1], EndOfStreamEvent)


def test_ms_level_filter_keeps_matching_aus(ttio_fixture):
    dataset = SpectralDataset.open(ttio_fixture)
    flt = AUFilter(ms_level=1)
    aus = [e for e in walk_dataset(dataset, flt)
            if isinstance(e, AccessUnitEvent)]
    # Indexes 0,2,4 have ms_level=1.
    assert len(aus) == 3
    assert [e.au_sequence for e in aus] == [0, 2, 4]


def test_max_au_cap_honoured(ttio_fixture):
    dataset = SpectralDataset.open(ttio_fixture)
    flt = AUFilter(max_au=2)
    aus = [e for e in walk_dataset(dataset, flt)
            if isinstance(e, AccessUnitEvent)]
    assert len(aus) == 2


def test_dataset_id_filter_skips_other_datasets(ttio_fixture):
    dataset = SpectralDataset.open(ttio_fixture)
    flt = AUFilter(dataset_id=99)  # no such dataset
    events = list(walk_dataset(dataset, flt))
    aus = [e for e in events if isinstance(e, AccessUnitEvent)]
    dshs = [e for e in events if isinstance(e, DatasetHeaderEvent)]
    eods = [e for e in events if isinstance(e, EndOfDatasetEvent)]
    assert aus == []
    assert dshs == []
    assert eods == []
    # StreamHeader + EndOfStream always emit.
    assert isinstance(events[0], StreamHeaderEvent)
    assert isinstance(events[-1], EndOfStreamEvent)


def test_walker_reusable_across_multiple_walks(ttio_fixture):
    dataset = SpectralDataset.open(ttio_fixture)
    a = list(walk_dataset(dataset))
    b = list(walk_dataset(dataset))
    # Compare by event types + dataset_id / au_sequence for AU events.
    def _key(events):
        return [(type(e).__name__,
                 getattr(e, "dataset_id", None),
                 getattr(e, "au_sequence", None))
                for e in events]
    assert _key(a) == _key(b)


def test_au_event_carries_real_access_unit(ttio_fixture):
    dataset = SpectralDataset.open(ttio_fixture)
    aus = [e for e in walk_dataset(dataset)
            if isinstance(e, AccessUnitEvent)]
    # AccessUnit should have the same number of channels we wrote.
    assert len(aus[0].au.channels) == 2  # mz + intensity
    # MS spectrum → spectrum_class == 0.
    assert aus[0].au.spectrum_class == 0


# ── v0.11 §5.4 prelude parity (#141) ───────────────────────────────


def test_walker_emits_v011_prelude_in_spec_order(tmp_path):
    """The walker must yield each v0.11 §5.4 prelude event in
    spec order between StreamHeader and the first DatasetHeader.

    Mirrors the ObjC :class:`V011RecordingVisitor` test added in #140
    and the Java :meth:`walkerEmitsV011PreludeInSpecOrder` test added
    in #141.
    """
    from _v0_11_fixtures import build_everything

    target = build_everything(tmp_path / "everything.tio")
    dataset = SpectralDataset.open(target)
    events = list(walk_dataset(dataset))

    # Slice from after StreamHeader through to (but not including)
    # the first DatasetHeader — that window is the §5.4 prelude.
    assert isinstance(events[0], StreamHeaderEvent)
    first_ds_idx = next(
        i for i, e in enumerate(events) if isinstance(e, DatasetHeaderEvent)
    )
    prelude = events[1:first_ds_idx]
    prelude_types = [type(e).__name__ for e in prelude]
    # §5.4 ordering: ENCRYPTION → PROVENANCE → SUBJECTS → SAMPLES →
    # REFERENCES (one per ref) → IMAGE → IDS → QUANTS. RamanImage +
    # IRImage are NOT in the `everything` fixture (only the standalone
    # _only fixtures populate them), so they should NOT appear here.
    assert prelude_types == [
        "EncryptionAlgorithmEvent",
        "DatasetProvenanceEvent",
        "SubjectMetadataEvent",
        "SampleMetadataEvent",
        "ReferenceGroupEvent",  # 1 reference in `everything`
        "ImageEvent",
        "IdentificationsTableEvent",
        "QuantificationsTableEvent",
    ], prelude_types

    # Spot-check payloads to make sure the events carry real content.
    encryption = next(e for e in prelude
                      if isinstance(e, EncryptionAlgorithmEvent))
    assert encryption.algorithm == "aes-256-gcm"

    provenance = next(e for e in prelude
                      if isinstance(e, DatasetProvenanceEvent))
    assert len(provenance.records) == 2

    subjects = next(e for e in prelude
                    if isinstance(e, SubjectMetadataEvent))
    assert len(subjects.rows) == 2

    samples = next(e for e in prelude
                   if isinstance(e, SampleMetadataEvent))
    assert len(samples.rows) == 3

    ref_event = next(e for e in prelude
                     if isinstance(e, ReferenceGroupEvent))
    assert ref_event.reference.uri == "fixture-everything-v1"

    img_event = next(e for e in prelude
                     if isinstance(e, ImageEvent))
    assert img_event.image.width == 3 and img_event.image.height == 3

    ids = next(e for e in prelude
               if isinstance(e, IdentificationsTableEvent))
    assert len(ids.rows) == 2

    quants = next(e for e in prelude
                  if isinstance(e, QuantificationsTableEvent))
    assert len(quants.rows) == 2


def test_walker_skips_unpopulated_prelude_events(ttio_fixture):
    """A bare MS-only fixture must NOT emit any §5.4 prelude events."""
    dataset = SpectralDataset.open(ttio_fixture)
    events = list(walk_dataset(dataset))
    prelude_types = {
        EncryptionAlgorithmEvent,
        DatasetProvenanceEvent,
        SubjectMetadataEvent,
        SampleMetadataEvent,
        ReferenceGroupEvent,
        ImageEvent,
        RamanImageEvent,
        IRImageEvent,
        IdentificationsTableEvent,
        QuantificationsTableEvent,
    }
    assert not any(type(e) in prelude_types for e in events)


def test_walker_emits_raman_and_ir_image_events(tmp_path):
    """Standalone Raman/IR fixtures should each emit their own image
    prelude event."""
    from _v0_11_fixtures import build_raman_image_only, build_ir_image_only

    raman_path = build_raman_image_only(tmp_path / "raman.tio")
    with SpectralDataset.open(raman_path) as ds:
        events = list(walk_dataset(ds))
    assert any(isinstance(e, RamanImageEvent) for e in events)
    assert not any(isinstance(e, ImageEvent) for e in events)
    assert not any(isinstance(e, IRImageEvent) for e in events)

    ir_path = build_ir_image_only(tmp_path / "ir.tio")
    with SpectralDataset.open(ir_path) as ds:
        events = list(walk_dataset(ds))
    assert any(isinstance(e, IRImageEvent) for e in events)
    assert not any(isinstance(e, ImageEvent) for e in events)
    assert not any(isinstance(e, RamanImageEvent) for e in events)


def test_walker_emits_genomic_access_units(tmp_path):
    """Genomic runs should produce AccessUnitEvents with the
    five-channel layout matching :meth:`TransportWriter.write_dataset`."""
    from _v0_11_fixtures import build_genomic_runs_only

    target = build_genomic_runs_only(tmp_path / "genomic.tio")
    with SpectralDataset.open(target) as ds:
        events = list(walk_dataset(ds))

    aus = [e for e in events if isinstance(e, AccessUnitEvent)]
    assert len(aus) == 4  # 4 reads in synth_genomic_run
    # Each genomic AU has 5 channels: sequences, qualities, cigar,
    # read_name, mate_chromosome.
    for au_event in aus:
        names = [c.name for c in au_event.au.channels]
        assert names == [
            "sequences", "qualities", "cigar",
            "read_name", "mate_chromosome",
        ]
        # Genomic spectrum_class wire code is 5.
        assert au_event.au.spectrum_class == 5
    # AU sequence numbers reset per dataset (per spec §5.5).
    assert [e.au_sequence for e in aus] == [0, 1, 2, 3]


def test_walker_event_order_matches_writer_byte_form(tmp_path):
    """End-to-end parity: encoding each walker event through
    TransportWriter produces the same packet sequence as the direct
    :meth:`TransportWriter.write_dataset` call."""
    import io
    from ttio.transport import TransportWriter
    from ttio.transport.packets import PacketHeader, HEADER_SIZE
    from _v0_11_fixtures import build_everything

    target = build_everything(tmp_path / "everything.tio")

    # Direct write_dataset baseline.
    with SpectralDataset.open(target) as ds:
        direct_buf = io.BytesIO()
        TransportWriter(direct_buf).write_dataset(ds)
    direct_packet_types = _extract_packet_types(direct_buf.getvalue())

    # Walker-driven emission: replay each event through write_X.
    from ttio.transport.walker import (
        AccessUnitEvent as _AU,
        DatasetHeaderEvent as _DH,
        DatasetProvenanceEvent as _DP,
        EncryptionAlgorithmEvent as _EA,
        EndOfDatasetEvent as _EOD,
        EndOfStreamEvent as _EOS,
        IRImageEvent as _IR,
        IdentificationsTableEvent as _IDS,
        ImageEvent as _IMG,
        QuantificationsTableEvent as _Q,
        RamanImageEvent as _RAM,
        ReferenceGroupEvent as _RG,
        SampleMetadataEvent as _SM,
        StreamHeaderEvent as _SH,
        SubjectMetadataEvent as _SUB,
        walk_dataset,
    )
    with SpectralDataset.open(target) as ds:
        walker_buf = io.BytesIO()
        w = TransportWriter(walker_buf)
        for e in walk_dataset(ds):
            if isinstance(e, _SH):
                w.write_stream_header(
                    format_version=e.format_version,
                    title=e.title,
                    isa_investigation=e.isa_investigation,
                    features=e.features,
                    n_datasets=e.n_datasets,
                )
            elif isinstance(e, _DH):
                w.write_dataset_header(
                    dataset_id=e.dataset_id, name=e.name,
                    acquisition_mode=e.acquisition_mode,
                    spectrum_class=e.spectrum_class,
                    channel_names=e.channel_names,
                    instrument_json=e.instrument_json,
                    expected_au_count=e.expected_au_count,
                )
            elif isinstance(e, _AU):
                w.write_access_unit(
                    dataset_id=e.dataset_id,
                    au_sequence=e.au_sequence,
                    au=e.au,
                )
            elif isinstance(e, _EOD):
                w.write_end_of_dataset(
                    dataset_id=e.dataset_id,
                    final_au_sequence=e.final_au_sequence,
                )
            elif isinstance(e, _EOS):
                w.write_end_of_stream()
            elif isinstance(e, _EA):
                w.write_encryption_algorithm(e.algorithm)
            elif isinstance(e, _DP):
                w.write_dataset_provenance(e.records)
            elif isinstance(e, _SUB):
                w.write_subject_metadata(e.rows)
            elif isinstance(e, _SM):
                w.write_sample_metadata(e.rows)
            elif isinstance(e, _RG):
                w.write_reference_group(e.reference)
            elif isinstance(e, _IMG):
                w.write_image(e.image)
            elif isinstance(e, _RAM):
                w.write_raman_image(e.image)
            elif isinstance(e, _IR):
                w.write_ir_image(e.image)
            elif isinstance(e, _IDS):
                w.write_identifications_table(e.rows)
            elif isinstance(e, _Q):
                w.write_quantifications_table(e.rows)

    walker_packet_types = _extract_packet_types(walker_buf.getvalue())
    assert walker_packet_types == direct_packet_types, (
        f"walker packet sequence diverged from direct writer:\n"
        f"  walker: {walker_packet_types}\n"
        f"  direct: {direct_packet_types}"
    )


def _extract_packet_types(blob: bytes) -> list[int]:
    """Walk a packet stream and return the list of packet-type bytes
    in emission order (excluding timestamps)."""
    from ttio.transport.packets import PacketHeader, HEADER_SIZE
    out: list[int] = []
    offset = 0
    while offset < len(blob):
        header = PacketHeader.from_bytes(blob[offset:offset + HEADER_SIZE])
        out.append(header.packet_type)
        offset += HEADER_SIZE + header.payload_length
    return out
