"""v0.11 Task 5.3 (Deferral 1, transport-spec §4.16): exercise the
IMAGE pipeline for :class:`~ttio.RamanImage` (modality=1) on
:meth:`TransportWriter.write_raman_image` and the matching reader
modality-dispatch path.

The IMAGE_HEADER carries a ``modality_extras`` slot at its tail with
the Raman-specific fields ``excitation_wavelength_nm +
laser_power_mw`` (two FLOAT64, 16 bytes total).

The shared header otherwise matches MS (modality=0) verbatim; each
pixel rides as a continuous-mode IMAGE_PIXEL whose payload is a
dense vector of ``spectrum_bins`` float64 intensities. The shared
axis on the IMAGE_HEADER is the Raman wavenumbers vector
(``axis_kind=1``).

Python parity for Java's :class:`TransportRamanImageTest` (commit
``f99ec47d``).

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import io
import struct
from pathlib import Path

import numpy as np

from ttio import SpectralDataset
from ttio.enums import ImageKind
from ttio.raman_image import RamanImage
from ttio.transport.codec import TransportReader, TransportWriter
from ttio.transport.packets import PacketType


def _build_raman_fixture(target: Path) -> Path:
    """Build a 3x3x4 RamanImage .tio file (mirrors Java)."""
    w, h, s = 3, 3, 4
    cube = np.zeros((h, w, s), dtype=np.float64)
    for y in range(h):
        for x in range(w):
            for k in range(s):
                cube[y, x, k] = (k + 1.0) * (x + y * w)
    wn = np.array([500.0 + i * 50.0 for i in range(s)], dtype=np.float64)
    img = RamanImage(
        width=w, height=h, spectral_points=s,
        intensity=cube, wavenumbers=wn,
        pixel_size_x=12.5, pixel_size_y=12.5, scan_pattern="raster",
        excitation_wavelength_nm=785.0, laser_power_mw=50.0,
        title="raman_fixture", isa_investigation_id="",
    )
    SpectralDataset.write_minimal(
        target,
        title="raman_fixture",
        isa_investigation_id="",
        runs={},
        raman_image=img,
    )
    return target


def test_write_raman_image_emits_header_pixels_eoi_with_modality_1(
    tmp_path: Path,
) -> None:
    """Writer emits IMAGE_HEADER + N IMAGE_PIXEL + END_OF_IMAGE with
    modality=1 (Raman) and the modality_extras slot at the tail of
    the IMAGE_HEADER carrying the two Raman FLOAT64 fields."""
    src = _build_raman_fixture(tmp_path / "raman.tio")
    tis = tmp_path / "raman.tis"

    with SpectralDataset.open(src) as ds:
        assert ds.image_for_kind(ImageKind.RAMAN) is not None, (
            "fixture precondition: dataset must carry a RamanImage"
        )
        out = io.BytesIO()
        with TransportWriter(out) as w:
            w.write_stream_header(
                format_version="1.2",
                title=ds.title or "",
                isa_investigation=ds.isa_investigation_id or "",
                features=[],
                n_datasets=0,
            )
            w.write_raman_image(ds.image_for_kind(ImageKind.RAMAN))
            w.write_end_of_stream()
        tis.write_bytes(out.getvalue())

    r = TransportReader(io.BytesIO(tis.read_bytes()))
    records = r.records_for_test()
    # 1 StreamHeader + 1 IMAGE_HEADER + 9 IMAGE_PIXEL + 1 EOI + 1 EOS
    assert len(records) == 13, (
        f"expected StreamHeader + IMAGE_HEADER + 9 pixels + EOI + EOS, "
        f"got {len(records)}"
    )
    assert records[0].header.packet_type == int(PacketType.STREAM_HEADER)
    assert records[1].header.packet_type == int(PacketType.IMAGE_HEADER)
    for i in range(9):
        assert records[2 + i].header.packet_type == int(PacketType.IMAGE_PIXEL)
    assert records[11].header.packet_type == int(PacketType.END_OF_IMAGE)
    assert records[12].header.packet_type == int(PacketType.END_OF_STREAM)

    hdr = records[1].payload
    off = 0
    (modality,) = struct.unpack_from("<B", hdr, off); off += 1
    (width,) = struct.unpack_from("<I", hdr, off); off += 4
    (height,) = struct.unpack_from("<I", hdr, off); off += 4
    (bins,) = struct.unpack_from("<I", hdr, off); off += 4
    (px_x,) = struct.unpack_from("<d", hdr, off); off += 8
    (px_y,) = struct.unpack_from("<d", hdr, off); off += 8
    (scan_pat,) = struct.unpack_from("<B", hdr, off); off += 1
    (axis_kind,) = struct.unpack_from("<B", hdr, off); off += 1
    (axis_len,) = struct.unpack_from("<I", hdr, off); off += 4
    axis = [struct.unpack_from("<d", hdr, off + 8 * i)[0]
            for i in range(axis_len)]
    off += 8 * axis_len
    (continuous,) = struct.unpack_from("<B", hdr, off); off += 1
    (title_len,) = struct.unpack_from("<H", hdr, off); off += 2
    off += title_len
    (isa_len,) = struct.unpack_from("<H", hdr, off); off += 2
    off += isa_len
    (extras_len,) = struct.unpack_from("<H", hdr, off); off += 2

    assert modality == 1, "RamanImage maps to modality 1"
    assert width == 3
    assert height == 3
    assert bins == 4
    assert px_x == 12.5
    assert px_y == 12.5
    assert scan_pat == 0, "raster maps to scan_pattern 0"
    assert axis_kind == 1, "RamanImage axis_kind is wavenumber=1"
    assert axis_len == 4
    for i, v in enumerate(axis):
        assert v == 500.0 + i * 50.0
    assert continuous == 1, "fixture is continuous mode"
    assert extras_len == 16, (
        "modality=1 extras = 8B excitation + 8B laser_power = 16B"
    )
    (exc,) = struct.unpack_from("<d", hdr, off); off += 8
    (laser,) = struct.unpack_from("<d", hdr, off); off += 8
    assert exc == 785.0
    assert laser == 50.0

    (pixel_count,) = struct.unpack_from("<I", records[11].payload, 0)
    assert pixel_count == 9, "pixel_count_seen = width*height"


def test_raman_image_round_trips_via_write_dataset_materialize(
    tmp_path: Path,
) -> None:
    """End-to-end: write_dataset → read_to_dataset → re-read; the
    round-tripped dataset carries the RamanImage with all fields
    byte-equal to the original."""
    src = _build_raman_fixture(tmp_path / "src.tio")
    tis = tmp_path / "src.tis"
    rt = tmp_path / "rt.tio"

    with SpectralDataset.open(src) as ds:
        with tis.open("wb") as out, TransportWriter(out) as w:
            w.write_dataset(ds)

    with TransportReader(io.BytesIO(tis.read_bytes())) as r:
        materialised = r.read_to_dataset(output_path=rt)
        materialised.close()

    with SpectralDataset.open(src) as a, SpectralDataset.open(rt) as b:
        img_a = a.image_for_kind(ImageKind.RAMAN)
        img_b = b.image_for_kind(ImageKind.RAMAN)
        assert img_a is not None, "source must carry a RamanImage"
        assert img_b is not None, "round-tripped dataset must carry a RamanImage"
        assert img_a.width == img_b.width
        assert img_a.height == img_b.height
        assert img_a.spectral_points == img_b.spectral_points
        assert img_a.pixel_size_x == img_b.pixel_size_x
        assert img_a.pixel_size_y == img_b.pixel_size_y
        assert img_a.scan_pattern == img_b.scan_pattern
        assert img_a.excitation_wavelength_nm == img_b.excitation_wavelength_nm
        assert img_a.laser_power_mw == img_b.laser_power_mw
        np.testing.assert_array_equal(img_a.wavenumbers, img_b.wavenumbers)
        np.testing.assert_array_equal(img_a.intensity, img_b.intensity)


def test_reader_skips_unknown_modality(tmp_path: Path) -> None:
    """Reader logs + skips an unknown modality byte (modality=99)
    rather than aborting the stream. The trailing END_OF_STREAM is
    still observed; the rest of the stream remains parseable."""
    # Synthesize a stream with an IMAGE_HEADER (modality=99, 1x1x1)
    # + 1 IMAGE_PIXEL + END_OF_IMAGE + END_OF_STREAM.
    tis = tmp_path / "unknown_mod.tis"
    sink = io.BytesIO()

    # IMAGE_HEADER payload (modality=99, 1+4+4+4+8+8+1+1+4+(0)+1+2+0+2+0+2+0
    # = 42 bytes — fixed prefix only, no axis values, no title/isa/
    # extras bodies).
    hbuf = b"".join((
        struct.pack("<B", 99),       # modality (unknown)
        struct.pack("<I", 1),        # width
        struct.pack("<I", 1),        # height
        struct.pack("<I", 1),        # spectrum_bins
        struct.pack("<d", 1.0),      # pixel_size_x
        struct.pack("<d", 1.0),      # pixel_size_y
        struct.pack("<B", 0),        # scan_pattern
        struct.pack("<B", 0),        # axis_kind
        struct.pack("<I", 0),        # axis_length
        # axis omitted (length 0)
        struct.pack("<B", 1),        # is_continuous
        struct.pack("<H", 0),        # title_length
        struct.pack("<H", 0),        # isa_id_length
        struct.pack("<H", 0),        # modality_extras_length
    ))
    assert len(hbuf) == 42

    # IMAGE_PIXEL (continuous, 1 float64 intensity).
    pbuf = b"".join((
        struct.pack("<I", 0),        # x
        struct.pack("<I", 0),        # y
        struct.pack("<B", 1),        # precision (FLOAT64)
        struct.pack("<B", 0),        # compression (NONE)
        struct.pack("<I", 8),        # payload_length
        struct.pack("<d", 42.0),     # single intensity
    ))

    # END_OF_IMAGE payload.
    ebuf = struct.pack("<I", 1)

    with TransportWriter(sink) as w:
        w.write_stream_header(
            format_version="1.2",
            title="unknown_mod",
            isa_investigation="",
            features=[],
            n_datasets=0,
        )
        # Synthesise unusual packets via the private _emit hook;
        # Python writer has no public emit_raw_packet sibling.
        w._emit(PacketType.IMAGE_HEADER, hbuf)
        w._emit(PacketType.IMAGE_PIXEL, pbuf)
        w._emit(PacketType.END_OF_IMAGE, ebuf)
        w.write_end_of_stream()
    tis.write_bytes(sink.getvalue())

    # materializeTo must NOT throw on the unknown modality; the
    # image block is silently dropped.
    rt = tmp_path / "rt.tio"
    with TransportReader(io.BytesIO(tis.read_bytes())) as r:
        materialised = r.read_to_dataset(output_path=rt)
        materialised.close()
    with SpectralDataset.open(rt) as ds:
        assert ds.image_for_kind(ImageKind.MS) is None, (
            "unknown-modality stream must produce no MSImage"
        )
        assert ds.image_for_kind(ImageKind.RAMAN) is None, (
            "unknown-modality stream must produce no RamanImage"
        )
        assert ds.image_for_kind(ImageKind.IR) is None, (
            "unknown-modality stream must produce no IRImage"
        )
