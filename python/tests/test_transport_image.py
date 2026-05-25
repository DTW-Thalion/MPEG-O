"""v0.11 Task 2.6 (transport-spec §4.16-§4.18): exercise the
``IMAGE_HEADER`` (0x13), ``IMAGE_PIXEL`` (0x14), and ``END_OF_IMAGE``
(0x15) packets on :class:`TransportWriter` + :class:`TransportReader`.

Continuous mode only — every pixel shares the same m/z axis.
Processed-mode (per-pixel axis) is deferred to a follow-up.

Wire layout summary (LITTLE-ENDIAN, see §4.16-§4.18):

* IMAGE_HEADER: modality(u8), width(u32), height(u32),
  spectrum_bins(u32), pixel_size_x(f64), pixel_size_y(f64),
  scan_pattern(u8), axis_kind(u8), axis_length(u32),
  axis(f64[axis_length]), is_continuous(u8),
  title_length(u16), title_utf8, isa_id_length(u16), isa_id_utf8.
* IMAGE_PIXEL (continuous): x(u32), y(u32), precision(u8),
  compression(u8), payload_length(u32), intensities[..].
* END_OF_IMAGE: pixel_count_seen(u32).

Python parity for Java's ``TransportImageTest`` (commit
``a6b1e5d9``).

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import io
import math
import struct
from pathlib import Path

import numpy as np

from ttio import MSImage
from ttio.spectral_dataset import SpectralDataset
from ttio.transport.codec import TransportReader, TransportWriter
from ttio.transport.packets import PacketType, TRANSPORT_V0_11_FEATURE


def _build_image_ms_continuous(target: Path) -> Path:
    """Build a 4x4x5 continuous-mode MSImage ``.tio`` file.

    Mirrors Java's ``FixtureBuilder.buildImageMsContinuous``:

    * width=4, height=4, spectral_points=5
    * mz_axis = [100, 110, 120, 130, 140]
    * pixel_size_x = pixel_size_y = 10.0
    * scan_pattern = "raster"
    * intensity[y, x, k] = (k + 1) * (x + y * width)  -- so pixel
      (0, 0) is all zeros, pixel (3, 3) has the largest values
    * title = "image_ms_continuous", isa_id = ""
    """
    w, h, s = 4, 4, 5
    cube = np.empty((h, w, s), dtype=np.float64)
    for y in range(h):
        for x in range(w):
            pixel_idx = x + y * w
            for k in range(s):
                cube[y, x, k] = (k + 1.0) * pixel_idx
    mz = np.array([100.0 + i * 10.0 for i in range(s)], dtype=np.float64)
    img = MSImage(
        width=w, height=h, spectral_points=s,
        intensity=cube, mz_axis=mz,
        pixel_size_x=10.0, pixel_size_y=10.0, scan_pattern="raster",
        title="image_ms_continuous", isa_investigation_id="",
    )
    SpectralDataset.write_minimal(
        target,
        title="image_ms_continuous",
        isa_investigation_id="",
        runs={},
        image=img,
    )
    return target


def test_writeImage_emits_header_pixels_eof_in_order(tmp_path: Path) -> None:
    """Low-level helper on a 4x4 MSImage emits exactly 1 IMAGE_HEADER +
    16 IMAGE_PIXEL + 1 END_OF_IMAGE packets in order, with the
    END_OF_IMAGE pixel_count_seen matching width*height."""
    src = _build_image_ms_continuous(tmp_path / "img.tio")
    tis = tmp_path / "img.tis"

    with SpectralDataset.open(src) as ds:
        assert ds.image is not None, (
            "fixture precondition: dataset must carry an MSImage"
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
            w.write_image(ds.image)
            w.write_end_of_stream()
        tis.write_bytes(out.getvalue())

    r = TransportReader(io.BytesIO(tis.read_bytes()))
    records = r.records_for_test()
    # 1 StreamHeader + 1 IMAGE_HEADER + 16 IMAGE_PIXEL + 1 EOI + 1 EOS
    assert len(records) == 20, (
        f"expected StreamHeader + IMAGE_HEADER + 16 pixels + EOI + EOS, "
        f"got {len(records)}"
    )
    assert records[0].header.packet_type == int(PacketType.STREAM_HEADER)
    assert records[1].header.packet_type == int(PacketType.IMAGE_HEADER)
    for i in range(16):
        assert records[2 + i].header.packet_type == int(PacketType.IMAGE_PIXEL), (
            f"packet {2 + i} must be IMAGE_PIXEL"
        )
    assert records[18].header.packet_type == int(PacketType.END_OF_IMAGE)
    assert records[19].header.packet_type == int(PacketType.END_OF_STREAM)

    # Decode the IMAGE_HEADER payload to validate the wire layout.
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

    assert modality == 0, "MSImage maps to modality 0"
    assert width == 4
    assert height == 4
    assert bins == 5
    assert math.isclose(px_x, 10.0, abs_tol=1e-12)
    assert math.isclose(px_y, 10.0, abs_tol=1e-12)
    assert scan_pat == 0, "raster maps to scan_pattern 0"
    assert axis_kind == 0, "MSImage axis_kind is mz=0"
    assert axis_len == 5
    for i, v in enumerate(axis):
        assert math.isclose(v, 100.0 + i * 10.0, abs_tol=1e-12), (
            f"axis[{i}] mismatch: got {v}"
        )
    assert continuous == 1, "fixture is continuous mode"

    # END_OF_IMAGE pixel_count_seen must equal width*height.
    (pixel_count,) = struct.unpack_from("<I", records[18].payload, 0)
    assert pixel_count == 16


def test_round_trip_via_write_dataset_and_materialize(tmp_path: Path) -> None:
    """End-to-end round-trip: ``write_dataset`` emits the image packets,
    ``read_to_dataset`` materialises them, the resulting on-disk .tio
    carries the same MSImage content (cube + mz axis)."""
    src = _build_image_ms_continuous(tmp_path / "src.tio")
    tis = tmp_path / "src.tis"
    rt = tmp_path / "rt.tio"

    with SpectralDataset.open(src) as ds:
        with tis.open("wb") as out, TransportWriter(out) as w:
            w.write_dataset(ds)

    with TransportReader(io.BytesIO(tis.read_bytes())) as r:
        materialised = r.read_to_dataset(output_path=rt)
        materialised.close()

    with SpectralDataset.open(src) as a, SpectralDataset.open(rt) as b:
        img_a = a.image
        img_b = b.image
        assert img_a is not None, "source must carry an MSImage"
        assert img_b is not None, "round-tripped dataset must carry an MSImage"
        assert img_a.width == img_b.width
        assert img_a.height == img_b.height
        assert img_a.spectral_points == img_b.spectral_points
        assert math.isclose(img_a.pixel_size_x, img_b.pixel_size_x, abs_tol=1e-12)
        assert math.isclose(img_a.pixel_size_y, img_b.pixel_size_y, abs_tol=1e-12)
        assert img_a.scan_pattern == img_b.scan_pattern
        np.testing.assert_array_equal(img_a.mz_axis, img_b.mz_axis)
        np.testing.assert_array_equal(img_a.intensity, img_b.intensity)


def test_feature_flag_set_when_image_present(tmp_path: Path) -> None:
    """``write_dataset`` on a .tio carrying an image emits the
    transport_v0_11 feature flag in the StreamHeader."""
    src = _build_image_ms_continuous(tmp_path / "img.tio")
    tis = tmp_path / "img.tis"
    with SpectralDataset.open(src) as ds:
        with tis.open("wb") as out, TransportWriter(out) as w:
            w.write_dataset(ds)

    r = TransportReader(io.BytesIO(tis.read_bytes()))
    records = r.records_for_test()
    from ttio.transport.codec import _decode_stream_header
    sh = _decode_stream_header(records[0].payload)
    assert TRANSPORT_V0_11_FEATURE in sh["features"], (
        "image-carrying dataset must flip the v0.11 feature flag"
    )


def test_zero_emission_when_no_image(tmp_path: Path) -> None:
    """``write_dataset`` on a .tio with NO image emits ZERO image-related
    packets, preserving v0.10 byte-stream identity for legacy files."""
    src = tmp_path / "plain.tio"
    SpectralDataset.write_minimal(
        src,
        title="plain",
        isa_investigation_id="",
        runs={},
    )
    tis = tmp_path / "plain.tis"
    with SpectralDataset.open(src) as ds:
        assert ds.image is None, (
            "fixture precondition: dataset must carry no image"
        )
        with tis.open("wb") as out, TransportWriter(out) as w:
            w.write_dataset(ds)

    r = TransportReader(io.BytesIO(tis.read_bytes()))
    for rec in r.records_for_test():
        assert rec.header.packet_type != int(PacketType.IMAGE_HEADER), (
            "image-less dataset must not emit IMAGE_HEADER"
        )
        assert rec.header.packet_type != int(PacketType.IMAGE_PIXEL), (
            "image-less dataset must not emit IMAGE_PIXEL"
        )
        assert rec.header.packet_type != int(PacketType.END_OF_IMAGE), (
            "image-less dataset must not emit END_OF_IMAGE"
        )
