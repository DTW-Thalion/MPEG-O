"""v0.11 Task 5.1 (Deferral 1, transport-spec §4.17 processed mode):
exercise sparse :data:`PacketType.IMAGE_PIXEL` (0x14) emission on
:meth:`TransportWriter.write_image_processed` and the matching decode
path on :class:`TransportReader`.

Processed mode emits, per pixel, a list of
``(channel_index, intensity)`` pairs indexed into the shared
``mz_axis`` (carried on the IMAGE_HEADER). The MSImage data model is
unchanged - the dense ``intensity`` cube round-trips byte-for-byte
through the sparse wire shape. Channels that are not enumerated in
the payload decode as 0.0.

Wire layout (LITTLE-ENDIAN, see transport-spec §4.17)::

    x(u32), y(u32), precision(u8), compression(u8),
    payload_length(u32),
    payload_bytes = nonzero_count(u32)
                  + nonzero_count x { channel_index(u32) + intensity(fXX) }

``write_image`` (continuous mode) is unchanged and remains the default
emission path; ``write_image_processed`` is an opt-in sibling for
sparse cubes. Java parity:
``TransportImageProcessedTest`` (commit ``1889343e``).

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import io
import struct
from pathlib import Path

import numpy as np

from ttio import MSImage
from ttio.transport.codec import TransportReader, TransportWriter
from ttio.transport.packets import PacketType


def _build_sparse_image() -> MSImage:
    """3x3x10 cube, ~80% sparse - per-pixel nonzeros < bins/4.

    Mirrors Java's ``buildSparseImage`` so the on-wire byte layout
    matches across languages: each pixel gets 1-2 nonzero channels
    deterministically.
    """
    w, h, bins = 3, 3, 10
    cube = np.zeros((h, w, bins), dtype=np.float64)
    for y in range(h):
        for x in range(w):
            p = y * w + x
            cube[y, x, p % bins] = 1.0 + p
            if (p & 1) == 1:
                cube[y, x, (p * 3) % bins] = -2.0 - p
    mz = np.array([100.0 + k * 5.0 for k in range(bins)], dtype=np.float64)
    return MSImage(
        width=w, height=h, spectral_points=bins,
        intensity=cube, mz_axis=mz,
        pixel_size_x=10.0, pixel_size_y=10.0, scan_pattern="raster",
        title="sparse", isa_investigation_id="",
    )


def _encode_image_processed(image: MSImage) -> bytes:
    """Encode an MSImage via writeImageProcessed only (no stream framing)."""
    sink = io.BytesIO()
    with TransportWriter(sink) as w:
        w.write_image_processed(image)
    return sink.getvalue()


def _decode_to_image(data: bytes) -> MSImage:
    """Parse the IMAGE_HEADER + IMAGE_PIXEL records directly into a
    dense MSImage. Mirrors Java's ``decodeToImage`` helper - we don't
    go through ``read_to_dataset`` because the test only writes an
    image block (no StreamHeader)."""
    r = TransportReader(io.BytesIO(data))
    records = r.records_for_test()
    hdr_idx = -1
    for i, rec in enumerate(records):
        if rec.header.packet_type == int(PacketType.IMAGE_HEADER):
            hdr_idx = i
            break
    assert hdr_idx >= 0, "must contain an IMAGE_HEADER"

    hdr = records[hdr_idx].payload
    off = 0
    off += 1                                                # modality
    (width,) = struct.unpack_from("<I", hdr, off); off += 4
    (height,) = struct.unpack_from("<I", hdr, off); off += 4
    (bins,) = struct.unpack_from("<I", hdr, off); off += 4
    (px_x,) = struct.unpack_from("<d", hdr, off); off += 8
    (px_y,) = struct.unpack_from("<d", hdr, off); off += 8
    off += 1                                                # scan_pattern
    off += 1                                                # axis_kind
    (axis_len,) = struct.unpack_from("<I", hdr, off); off += 4
    mz = np.frombuffer(hdr, dtype="<f8", count=axis_len, offset=off).copy()
    off += 8 * axis_len
    is_cont = hdr[off]; off += 1
    assert is_cont == 0, "decode_to_image expects processed-mode header"

    cube = np.zeros((height, width, bins), dtype=np.float64)
    for rec in records[hdr_idx + 1:]:
        if rec.header.packet_type == int(PacketType.END_OF_IMAGE):
            break
        if rec.header.packet_type != int(PacketType.IMAGE_PIXEL):
            continue
        pl = rec.payload
        off = 0
        (x,) = struct.unpack_from("<I", pl, off); off += 4
        (y,) = struct.unpack_from("<I", pl, off); off += 4
        precision = pl[off]; off += 1
        compression = pl[off]; off += 1
        (plen,) = struct.unpack_from("<I", pl, off); off += 4
        raw = bytes(pl[off:off + plen])
        assert compression == 0, (
            "compression=0 is the only mode produced today"
        )
        (count,) = struct.unpack_from("<I", raw, 0)
        eo = 4
        for _ in range(count):
            (ch,) = struct.unpack_from("<I", raw, eo); eo += 4
            if precision == 1:
                (v,) = struct.unpack_from("<d", raw, eo); eo += 8
            else:
                (v,) = struct.unpack_from("<f", raw, eo); eo += 4
            cube[y, x, ch] = v

    return MSImage(
        width=width, height=height, spectral_points=bins,
        intensity=cube, mz_axis=mz,
        pixel_size_x=px_x, pixel_size_y=px_y, scan_pattern="raster",
    )


def test_processed_mode_round_trips_sparse_cube() -> None:
    """Round-trip a sparse 3x3x10 MSImage through processed-mode
    encode -> decode and assert the dense intensity cube matches the
    input byte-for-byte. The fixture is ~80% sparse: each pixel has a
    small handful of nonzero channels seeded by a deterministic
    pattern."""
    img = _build_sparse_image()
    data = _encode_image_processed(img)

    r = TransportReader(io.BytesIO(data))
    records = r.records_for_test()
    # 1 IMAGE_HEADER + 9 IMAGE_PIXEL + 1 END_OF_IMAGE
    assert len(records) == 11, (
        f"expected 1 header + 9 pixels + 1 EOI, got {len(records)}"
    )
    assert records[0].header.packet_type == int(PacketType.IMAGE_HEADER)
    for i in range(9):
        assert records[1 + i].header.packet_type == int(PacketType.IMAGE_PIXEL), (
            f"packet {1 + i} must be IMAGE_PIXEL"
        )
    assert records[10].header.packet_type == int(PacketType.END_OF_IMAGE)

    # IMAGE_HEADER must advertise is_continuous=0.
    hdr = records[0].payload
    off = 0
    off += 1                                            # modality
    off += 4 + 4 + 4                                    # width, height, bins
    off += 8 + 8                                        # pixel_size_x/y
    off += 1 + 1                                        # scan_pattern, axis_kind
    (axis_len,) = struct.unpack_from("<I", hdr, off); off += 4
    off += 8 * axis_len                                 # axis values
    is_cont = hdr[off]
    assert is_cont == 0, (
        "write_image_processed must emit is_continuous=0"
    )

    # Materialise into a fresh MSImage and compare cube byte-for-byte.
    rt = _decode_to_image(data)
    assert rt.width == img.width
    assert rt.height == img.height
    assert rt.spectral_points == img.spectral_points
    np.testing.assert_array_equal(rt.mz_axis, img.mz_axis)
    np.testing.assert_array_equal(rt.intensity, img.intensity)


def test_all_zero_pixel_emits_nonzero_count_zero() -> None:
    """An entire pixel with all-zero intensities must encode as
    ``nonzero_count=0``. After round-tripping, the corresponding cube
    slice stays at 0.0 and the wire payload is tiny (just the outer
    header + the 4-byte count)."""
    w, h, bins = 2, 1, 5
    cube = np.zeros((h, w, bins), dtype=np.float64)  # all zero
    mz = np.array([100.0, 110.0, 120.0, 130.0, 140.0], dtype=np.float64)
    img = MSImage(
        width=w, height=h, spectral_points=bins,
        intensity=cube, mz_axis=mz,
        pixel_size_x=10.0, pixel_size_y=10.0, scan_pattern="raster",
        title="all_zero", isa_investigation_id="",
    )

    data = _encode_image_processed(img)
    r = TransportReader(io.BytesIO(data))
    records = r.records_for_test()
    # 1 hdr + 2 pixels + 1 EOI
    assert len(records) == 4

    # Each IMAGE_PIXEL payload after the outer fixed header must carry
    # nonzero_count=0 (a single 4-byte u32 LE = 0).
    for i in range(2):
        pl = records[1 + i].payload
        off = 0
        off += 4                                       # x
        off += 4                                       # y
        off += 1 + 1                                   # precision, compression
        (plen,) = struct.unpack_from("<I", pl, off); off += 4
        assert plen == 4, (
            "all-zero pixel must have payload_length=4 (just nonzero_count)"
        )
        (count,) = struct.unpack_from("<I", pl, off)
        assert count == 0, "all-zero pixel must emit nonzero_count=0"

    rt = _decode_to_image(data)
    np.testing.assert_array_equal(rt.intensity, cube)


def test_fully_dense_pixel_round_trips_in_processed_mode() -> None:
    """A fully dense pixel (every channel nonzero) round-trips
    correctly even in processed mode - no off-by-one on the
    channel-index loop."""
    w, h, bins = 1, 1, 8
    cube = np.zeros((h, w, bins), dtype=np.float64)
    for k in range(bins):
        cube[0, 0, k] = (k + 1) * 7.5  # all nonzero
    mz = np.array([200.0 + k for k in range(bins)], dtype=np.float64)
    img = MSImage(
        width=w, height=h, spectral_points=bins,
        intensity=cube, mz_axis=mz,
        pixel_size_x=5.0, pixel_size_y=5.0, scan_pattern="raster",
        title="dense", isa_investigation_id="",
    )

    data = _encode_image_processed(img)
    r = TransportReader(io.BytesIO(data))
    records = r.records_for_test()
    # 1 hdr + 1 pixel + 1 EOI
    assert len(records) == 3

    # Inspect the pixel payload: nonzero_count must be bins, and
    # payload_length = 4 + bins*(4+8).
    pl = records[1].payload
    off = 4 + 4 + 1 + 1                                # x, y, prec, comp
    (plen,) = struct.unpack_from("<I", pl, off); off += 4
    assert plen == 4 + bins * (4 + 8), (
        "dense processed-mode pixel payload size mismatch"
    )
    (count,) = struct.unpack_from("<I", pl, off); off += 4
    assert count == bins
    for k in range(bins):
        (ch,) = struct.unpack_from("<I", pl, off); off += 4
        (v,) = struct.unpack_from("<d", pl, off); off += 8
        assert ch == k, (
            "channels must arrive in ascending order for a dense pixel"
        )
        assert v == (k + 1) * 7.5

    rt = _decode_to_image(data)
    np.testing.assert_array_equal(rt.intensity, cube)


def test_mixed_sparse_and_dense_pixels_round_trip() -> None:
    """Mixed sparse-and-dense pixels in the same image round-trip
    correctly: row 0 is dense, row 1 is sparse, row 2 is empty. All
    three coexist on the wire under a single IMAGE_HEADER."""
    w, h, bins = 2, 3, 6
    cube = np.zeros((h, w, bins), dtype=np.float64)
    # Row 0: dense.
    for x in range(w):
        for k in range(bins):
            cube[0, x, k] = (k + 1) + x * 0.5
    # Row 1: sparse - only channels 0, 3 are nonzero.
    for x in range(w):
        cube[1, x, 0] = 99.0 + x
        cube[1, x, 3] = -1.5 * (x + 1)
    # Row 2: empty (all zeros - left as default).
    mz = np.array([300.0 + k for k in range(bins)], dtype=np.float64)
    img = MSImage(
        width=w, height=h, spectral_points=bins,
        intensity=cube, mz_axis=mz,
        pixel_size_x=1.0, pixel_size_y=1.0, scan_pattern="raster",
        title="mixed", isa_investigation_id="",
    )

    data = _encode_image_processed(img)
    rt = _decode_to_image(data)
    np.testing.assert_array_equal(
        rt.intensity, cube,
        err_msg="mixed-sparsity cube must round-trip exactly",
    )
    np.testing.assert_array_equal(rt.mz_axis, mz)
