"""v0.11 Task 5.3 (Deferral 1, transport-spec §4.16): exercise the
IMAGE pipeline for :class:`~ttio.IRImage` (modality=2) plus the
three-modality write_dataset path (MS + Raman + IR populated on the
same dataset, image blocks emitted in deterministic order).

The IMAGE_HEADER carries a ``modality_extras`` slot at its tail with
the IR-specific fields ``ir_mode (u8)`` and ``resolution_cm_inv
(f64)`` (9 bytes total).

Python parity for Java's :class:`TransportIRImageTest` (commit
``f99ec47d``).

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import io
import struct
from pathlib import Path

import numpy as np

from ttio import MSImage, SpectralDataset
from ttio.enums import IRMode, ImageKind
from ttio.ir_image import IRImage
from ttio.raman_image import RamanImage
from ttio.transport.codec import TransportReader, TransportWriter
from ttio.transport.packets import PacketType


def _build_ir_fixture(target: Path) -> Path:
    """Build a 3x3x4 IRImage .tio file (mirrors Java)."""
    w, h, s = 3, 3, 4
    cube = np.zeros((h, w, s), dtype=np.float64)
    for y in range(h):
        for x in range(w):
            for k in range(s):
                cube[y, x, k] = (k + 1.0) * (x + y * w)
    wn = np.array([800.0 + i * 100.0 for i in range(s)], dtype=np.float64)
    img = IRImage(
        width=w, height=h, spectral_points=s,
        intensity=cube, wavenumbers=wn,
        pixel_size_x=8.0, pixel_size_y=8.0, scan_pattern="raster",
        mode=IRMode.ABSORBANCE, resolution_cm_inv=4.0,
        title="ir_fixture", isa_investigation_id="",
    )
    SpectralDataset.write_minimal(
        target,
        title="ir_fixture",
        isa_investigation_id="",
        runs={},
        ir_image=img,
    )
    return target


def _build_all_three_image_modalities(target: Path) -> Path:
    """Build a .tio that carries one of EACH image modality (MS +
    Raman + IR) - used to verify the three-block emit ordering in
    write_dataset. Mirrors Java's ``buildAllThreeImageModalities``."""
    w, h, s = 2, 2, 3
    ms_cube = np.zeros((h, w, s), dtype=np.float64)
    ms_mz = np.array([100.0 + i * 10.0 for i in range(s)], dtype=np.float64)
    for y in range(h):
        for x in range(w):
            for k in range(s):
                ms_cube[y, x, k] = (k + 1.0) * (x + y * w)
    ms = MSImage(
        width=w, height=h, spectral_points=s,
        intensity=ms_cube, mz_axis=ms_mz,
        pixel_size_x=5.0, pixel_size_y=5.0, scan_pattern="raster",
        title="all_three", isa_investigation_id="",
    )

    raman_cube = np.arange(w * h * s, dtype=np.float64).reshape(h, w, s)
    raman_wn = np.array([500.0 + i * 50.0 for i in range(s)], dtype=np.float64)
    raman = RamanImage(
        width=w, height=h, spectral_points=s,
        intensity=raman_cube, wavenumbers=raman_wn,
        pixel_size_x=6.0, pixel_size_y=6.0, scan_pattern="raster",
        excitation_wavelength_nm=785.0, laser_power_mw=50.0,
        title="all_three", isa_investigation_id="",
    )

    ir_cube = (
        2.0 * np.arange(w * h * s, dtype=np.float64).reshape(h, w, s)
    )
    ir_wn = np.array([1500.0 + i * 200.0 for i in range(s)], dtype=np.float64)
    ir = IRImage(
        width=w, height=h, spectral_points=s,
        intensity=ir_cube, wavenumbers=ir_wn,
        pixel_size_x=7.0, pixel_size_y=7.0, scan_pattern="raster",
        mode=IRMode.TRANSMITTANCE, resolution_cm_inv=2.0,
        title="all_three", isa_investigation_id="",
    )

    SpectralDataset.write_minimal(
        target,
        title="all_three",
        isa_investigation_id="",
        runs={},
        image=ms,
        raman_image=raman,
        ir_image=ir,
    )
    return target


def test_write_ir_image_emits_header_pixels_eoi_with_modality_2(
    tmp_path: Path,
) -> None:
    """Writer emits IMAGE_HEADER + N IMAGE_PIXEL + END_OF_IMAGE with
    modality=2 (IR) and the modality_extras slot carrying the
    IR-specific tail (u8 ir_mode + f64 resolution_cm_inv)."""
    src = _build_ir_fixture(tmp_path / "ir.tio")
    tis = tmp_path / "ir.tis"

    with SpectralDataset.open(src) as ds:
        assert ds.image_for_kind(ImageKind.IR) is not None, (
            "fixture precondition: dataset must carry an IRImage"
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
            w.write_ir_image(ds.image_for_kind(ImageKind.IR))
            w.write_end_of_stream()
        tis.write_bytes(out.getvalue())

    r = TransportReader(io.BytesIO(tis.read_bytes()))
    records = r.records_for_test()
    # 1 StreamHeader + 1 IMAGE_HEADER + 9 IMAGE_PIXEL + 1 EOI + 1 EOS
    assert len(records) == 13
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
    off += 8 * axis_len
    (continuous,) = struct.unpack_from("<B", hdr, off); off += 1
    (title_len,) = struct.unpack_from("<H", hdr, off); off += 2
    off += title_len
    (isa_len,) = struct.unpack_from("<H", hdr, off); off += 2
    off += isa_len
    (extras_len,) = struct.unpack_from("<H", hdr, off); off += 2

    assert modality == 2, "IRImage maps to modality 2"
    assert width == 3
    assert height == 3
    assert bins == 4
    assert px_x == 8.0
    assert px_y == 8.0
    assert axis_kind == 1, "IRImage axis_kind is wavenumber=1"
    assert axis_len == 4
    assert continuous == 1, "fixture is continuous mode"
    assert extras_len == 9, (
        "modality=2 extras = 1B ir_mode + 8B resolution = 9B"
    )
    (ir_mode,) = struct.unpack_from("<B", hdr, off); off += 1
    (resolution_cm_inv,) = struct.unpack_from("<d", hdr, off); off += 8
    assert ir_mode == 1, "ABSORBANCE maps to wire ir_mode=1"
    assert resolution_cm_inv == 4.0

    (pixel_count,) = struct.unpack_from("<I", records[11].payload, 0)
    assert pixel_count == 9


def test_ir_image_round_trips_via_write_dataset_materialize(
    tmp_path: Path,
) -> None:
    """End-to-end: write_dataset → read_to_dataset → re-read; the
    round-tripped IRImage matches byte-equal (cube, wavenumbers,
    ir_mode, resolution)."""
    src = _build_ir_fixture(tmp_path / "src.tio")
    tis = tmp_path / "src.tis"
    rt = tmp_path / "rt.tio"

    with SpectralDataset.open(src) as ds:
        with tis.open("wb") as out, TransportWriter(out) as w:
            w.write_dataset(ds)

    with TransportReader(io.BytesIO(tis.read_bytes())) as r:
        materialised = r.read_to_dataset(output_path=rt)
        materialised.close()

    with SpectralDataset.open(src) as a, SpectralDataset.open(rt) as b:
        img_a = a.image_for_kind(ImageKind.IR)
        img_b = b.image_for_kind(ImageKind.IR)
        assert img_a is not None
        assert img_b is not None
        assert img_a.width == img_b.width
        assert img_a.height == img_b.height
        assert img_a.spectral_points == img_b.spectral_points
        assert img_a.pixel_size_x == img_b.pixel_size_x
        assert img_a.pixel_size_y == img_b.pixel_size_y
        assert img_a.scan_pattern == img_b.scan_pattern
        assert img_a.mode == img_b.mode
        assert img_a.resolution_cm_inv == img_b.resolution_cm_inv
        np.testing.assert_array_equal(img_a.wavenumbers, img_b.wavenumbers)
        np.testing.assert_array_equal(img_a.intensity, img_b.intensity)


def test_write_dataset_emits_all_three_image_modalities_in_order(
    tmp_path: Path,
) -> None:
    """write_dataset on a .tio carrying MS + Raman + IR images emits
    exactly THREE IMAGE_HEADER blocks, in MS, Raman, IR order."""
    src = _build_all_three_image_modalities(tmp_path / "all.tio")
    tis = tmp_path / "all.tis"

    with SpectralDataset.open(src) as ds:
        assert ds.image_for_kind(ImageKind.MS) is not None, "MS image must be present"
        assert ds.image_for_kind(ImageKind.RAMAN) is not None, "Raman image must be present"
        assert ds.image_for_kind(ImageKind.IR) is not None, "IR image must be present"
        with tis.open("wb") as out, TransportWriter(out) as w:
            w.write_dataset(ds)

    r = TransportReader(io.BytesIO(tis.read_bytes()))
    records = r.records_for_test()
    modalities = []
    for rec in records:
        if rec.header.packet_type == int(PacketType.IMAGE_HEADER):
            (m,) = struct.unpack_from("<B", rec.payload, 0)
            modalities.append(m)
    assert modalities == [0, 1, 2], (
        "write_dataset must emit MS (0), then Raman (1), then IR (2)"
    )
