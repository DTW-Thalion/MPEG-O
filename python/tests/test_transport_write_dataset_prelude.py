"""v0.11 Task 2.9 (transport-spec §5.4): end-to-end verification of
``TransportWriter.write_dataset``'s v0.11 prelude wiring.

The prelude emits in this strict order per spec §5.4:

#. ``ENCRYPTION_ALGORITHM`` (0x1B) — when ``ds.is_encrypted``
#. ``DATASET_PROVENANCE`` (0x18) — when ``ds.provenance()`` non-empty
#. ``SUBJECT_METADATA`` / ``SAMPLE_METADATA`` (0x19/0x1A) — deferred
#. Reference groups (0x10/0x11/0x12) — one sequence per ref
#. Image cube (0x13/0x14/0x15) — when ``ds.image is not None``
#. ``IDENTIFICATIONS_TABLE`` (0x16) / ``QUANTIFICATIONS_TABLE`` (0x17)

The ``transport_v0_11`` feature flag rides on ``StreamHeader.features``
when any of the above is non-empty / non-None.

Python parity for Java's
``TransportWriterReferenceWireUpTest`` (commit ``dc0de926``) plus the
post-Task-2.7 integration coverage for §5.4 ordering and the v0.10
"no v0.11 content" path.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import io
from pathlib import Path

from ttio.enums import ImageKind
from ttio.genomic.reference_import import ReferenceImport
from ttio.identification import Identification
from ttio.provenance import ProvenanceRecord
from ttio.quantification import Quantification
from ttio.spectral_dataset import SpectralDataset
from ttio.transport.codec import TransportReader, TransportWriter
from ttio.transport.packets import PacketType, TRANSPORT_V0_11_FEATURE


def _build_reference_only(target: Path) -> Path:
    """A ``.tio`` carrying a single reference and nothing else.

    The reference is sized to BOTH straddle the 4 KiB zlib threshold
    (one chromosome below, one above) so the writer exercises both
    encoding paths in this round-trip.
    """
    SpectralDataset.write_minimal(
        target,
        title="ref_only",
        isa_investigation_id="",
        runs={},
    )
    alphabet = b"ACGT"
    big = bytes(alphabet[i & 3] for i in range(8192))
    ref = ReferenceImport(
        uri="prelude-ref-v1",
        chromosomes=["chrA", "chrB"],
        sequences=[b"ACGTACGT", big],
    )
    with SpectralDataset.open(target, writable=True) as ds_w:
        ref.write_to_dataset(ds_w)
    return target


def test_reference_only_round_trips_through_write_dataset(
    tmp_path: Path,
) -> None:
    """Regression for the silent-drop bug: ``write_dataset`` on a
    reference-only ``.tio`` must produce a ``.tis`` that round-trips
    losslessly back to ``.tio`` with the references intact. Java
    parity: ``writeDataset_round_trips_references_end_to_end``."""
    src = _build_reference_only(tmp_path / "src.tio")
    tis = tmp_path / "src.tis"
    rt = tmp_path / "rt.tio"

    with SpectralDataset.open(src) as ds:
        with open(tis, "wb") as out, TransportWriter(out) as w:
            w.write_dataset(ds)

    # The reference-only .tis must be substantially larger than the
    # known silent-drop baseline (~190 bytes — StreamHeader +
    # EndOfStream only). The 8 KiB ACGT chromosome is highly
    # compressible (zlib down to ~40 bytes), so we gate on a
    # conservative 300-byte floor: enough to fit the StreamHeader +
    # REFERENCE_GROUP_HEADER + 2x REFERENCE_CHROMOSOME +
    # END_OF_REFERENCE_GROUP + EndOfStream packet headers and short
    # bodies, but well above the silent-drop baseline.
    src_size = src.stat().st_size
    tis_size = tis.stat().st_size
    assert tis_size > 300, (
        f"reference-only write_dataset produced only {tis_size} bytes; "
        f"source was {src_size} bytes -- silent drop?"
    )

    with TransportReader(tis) as r:
        materialised = r.read_to_dataset(output_path=rt)
        materialised.close()

    with SpectralDataset.open(src) as a, SpectralDataset.open(rt) as b:
        refs_a = a.references
        refs_b = b.references
        assert list(refs_a.keys()) == list(refs_b.keys()), (
            f"reference URIs must round-trip: {list(refs_a.keys())} vs "
            f"{list(refs_b.keys())}"
        )
        for uri in refs_a.keys():
            ra = refs_a[uri]
            rb = refs_b[uri]
            assert ra.uri == rb.uri
            assert sorted(ra.chromosomes) == sorted(rb.chromosomes)
            for name in ra.chromosomes:
                assert ra.chromosome(name) == rb.chromosome(name), (
                    f"chromosome {name!r} byte content mismatch"
                )
            assert ra.total_bases == rb.total_bases
            assert ra.md5 == rb.md5


def test_feature_flag_set_when_references_present(tmp_path: Path) -> None:
    """The ``transport_v0_11`` feature flag MUST appear in
    ``StreamHeader.features`` whenever a reference rides on the
    stream (or any other v0.11 content). Java parity:
    ``writeDataset_emits_v0_11_feature_flag_when_references_present``.
    """
    src = _build_reference_only(tmp_path / "src.tio")
    out = io.BytesIO()
    with SpectralDataset.open(src) as ds:
        with TransportWriter(out) as w:
            w.write_dataset(ds)

    # Inspect the StreamHeader payload directly — the features list
    # rides as a sequence of uint16-length-prefixed UTF-8 strings, so
    # the literal flag text must appear verbatim.
    r = TransportReader(io.BytesIO(out.getvalue()))
    records = r.records_for_test()
    assert records[0].header.packet_type == int(PacketType.STREAM_HEADER), (
        "first packet must be StreamHeader"
    )
    assert TRANSPORT_V0_11_FEATURE.encode("utf-8") in records[0].payload, (
        f"StreamHeader must contain {TRANSPORT_V0_11_FEATURE!r} feature flag"
    )


def test_v0_10_dataset_emits_no_v0_11_flag_or_packets(tmp_path: Path) -> None:
    """A dataset with no v0.11 content (no references, no ids,
    no quants, no image, not encrypted, no dataset_provenance) MUST
    produce a ``.tis`` without the v0.11 feature flag and without any
    0x10-0x1B packets. Confirms the v0.10 path is unchanged."""
    src = tmp_path / "v010.tio"
    SpectralDataset.write_minimal(
        src,
        title="v010_only",
        isa_investigation_id="",
        runs={},
    )

    out = io.BytesIO()
    with SpectralDataset.open(src) as ds:
        with TransportWriter(out) as w:
            w.write_dataset(ds)

    r = TransportReader(io.BytesIO(out.getvalue()))
    records = r.records_for_test()
    # First packet must be StreamHeader and must NOT advertise the
    # v0.11 flag.
    assert records[0].header.packet_type == int(PacketType.STREAM_HEADER)
    assert TRANSPORT_V0_11_FEATURE.encode("utf-8") not in records[0].payload, (
        "v0.10-only dataset must not advertise transport_v0_11"
    )
    # None of the v0.11 packet types may appear.
    v011_types = {
        int(PacketType.REFERENCE_GROUP_HEADER),
        int(PacketType.REFERENCE_CHROMOSOME),
        int(PacketType.END_OF_REFERENCE_GROUP),
        int(PacketType.IMAGE_HEADER),
        int(PacketType.IMAGE_PIXEL),
        int(PacketType.END_OF_IMAGE),
        int(PacketType.IDENTIFICATIONS_TABLE),
        int(PacketType.QUANTIFICATIONS_TABLE),
        int(PacketType.DATASET_PROVENANCE),
        int(PacketType.SUBJECT_METADATA),
        int(PacketType.SAMPLE_METADATA),
        int(PacketType.ENCRYPTION_ALGORITHM),
    }
    for rec in records:
        assert rec.header.packet_type not in v011_types, (
            f"unexpected v0.11 packet 0x{rec.header.packet_type:02x} on "
            f"v0.10 stream"
        )


def test_multi_section_prelude_emits_in_spec_5_4_order(tmp_path: Path) -> None:
    """A dataset carrying ENCRYPTION, PROVENANCE, REFERENCE, IMAGE,
    IDENTIFICATIONS, and QUANTIFICATIONS MUST emit those sections in
    the strict §5.4 order:

      ENCRYPTION_ALGORITHM (0x1B)
      DATASET_PROVENANCE   (0x18)
      REFERENCE_*          (0x10/0x11/0x12)
      IMAGE_*              (0x13/0x14/0x15)
      IDENTIFICATIONS_TABLE (0x16)
      QUANTIFICATIONS_TABLE (0x17)

    Subjects + samples (0x19/0x1A) are deferred and skipped here.
    """
    import numpy as np
    from ttio import MSImage
    src = tmp_path / "multi.tio"
    # Build the multi-section dataset.
    image = MSImage(
        width=2, height=2, spectral_points=3,
        intensity=np.zeros((2, 2, 3), dtype=np.float64),
        mz_axis=np.array([100.0, 110.0, 120.0], dtype=np.float64),
        pixel_size_x=10.0, pixel_size_y=10.0, scan_pattern="raster",
        title="multi-img", isa_investigation_id="",
    )
    ids = [
        Identification(
            run_name="r1", spectrum_index=0,
            chemical_entity="CompoundA", confidence_score=0.5,
            evidence_chain=["e1"],
        ),
    ]
    quants = [
        Quantification(
            chemical_entity="CompoundA", sample_ref="s1",
            abundance=1.0, normalization_method="intensity-sum",
            unit="counts",
        ),
    ]
    provenance = [
        ProvenanceRecord(
            timestamp_unix=12345,
            software="ttio-test",
            parameters={"k": "v"},
            input_refs=[],
            output_refs=[],
        ),
    ]
    SpectralDataset.write_minimal(
        src,
        title="multi",
        isa_investigation_id="",
        runs={},
        identifications=ids,
        quantifications=quants,
        provenance=provenance,
        image=image,
    )
    # Add encryption attribute + a reference group post-write.
    ref = ReferenceImport(
        uri="multi-ref-v1",
        chromosomes=["chr1"],
        sequences=[b"ACGT"],
    )
    with SpectralDataset.open(src, writable=True) as ds_w:
        ref.write_to_dataset(ds_w)
        ds_w.provider.root_group().set_attribute("encrypted", "aes-256-gcm")

    out = io.BytesIO()
    with SpectralDataset.open(src) as ds:
        assert ds.is_encrypted, "fixture precondition: encryption attr set"
        assert ds.image_for_kind(ImageKind.MS) is not None
        assert ds.references
        assert ds.identifications()
        assert ds.quantifications()
        assert ds.provenance()
        with TransportWriter(out) as w:
            w.write_dataset(ds)

    r = TransportReader(io.BytesIO(out.getvalue()))
    records = r.records_for_test()

    # Index of the first packet of each v0.11 section.
    def first_idx(*types: int) -> int:
        for i, rec in enumerate(records):
            if rec.header.packet_type in types:
                return i
        return -1

    encryption_idx = first_idx(int(PacketType.ENCRYPTION_ALGORITHM))
    provenance_idx = first_idx(int(PacketType.DATASET_PROVENANCE))
    reference_idx = first_idx(int(PacketType.REFERENCE_GROUP_HEADER))
    image_idx = first_idx(int(PacketType.IMAGE_HEADER))
    ids_idx = first_idx(int(PacketType.IDENTIFICATIONS_TABLE))
    quants_idx = first_idx(int(PacketType.QUANTIFICATIONS_TABLE))

    # Every section must be present.
    assert encryption_idx > 0, "ENCRYPTION_ALGORITHM not emitted"
    assert provenance_idx > 0, "DATASET_PROVENANCE not emitted"
    assert reference_idx > 0, "REFERENCE_GROUP_HEADER not emitted"
    assert image_idx > 0, "IMAGE_HEADER not emitted"
    assert ids_idx > 0, "IDENTIFICATIONS_TABLE not emitted"
    assert quants_idx > 0, "QUANTIFICATIONS_TABLE not emitted"

    # Strict §5.4 ordering.
    assert encryption_idx < provenance_idx, (
        "§5.4 violation: ENCRYPTION_ALGORITHM must precede "
        "DATASET_PROVENANCE"
    )
    assert provenance_idx < reference_idx, (
        "§5.4 violation: DATASET_PROVENANCE must precede REFERENCE_*"
    )
    assert reference_idx < image_idx, (
        "§5.4 violation: REFERENCE_* must precede IMAGE_*"
    )
    assert image_idx < ids_idx, (
        "§5.4 violation: IMAGE_* must precede IDENTIFICATIONS_TABLE"
    )
    assert ids_idx < quants_idx, (
        "§5.4 violation: IDENTIFICATIONS_TABLE must precede "
        "QUANTIFICATIONS_TABLE"
    )
