"""imzML writer — v0.9+ round-trip + layout tests.

Covers both modes plus the subtle layout invariants that broke real
imzML files in the past (UUID length, offset monotonicity, shared
m/z axis in continuous mode, .ibd size matching declared offsets).
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ttio.exporters import imzml as imzml_writer
from ttio.importers import imzml as imzml_reader
from ttio.importers.imzml import ImzMLPixelSpectrum


def _pixel(x: int, y: int, mz: np.ndarray, intensity: np.ndarray) -> ImzMLPixelSpectrum:
    return ImzMLPixelSpectrum(
        x=x, y=y, z=1,
        mz=np.asarray(mz, dtype=np.float64),
        intensity=np.asarray(intensity, dtype=np.float64),
    )


def test_continuous_mode_round_trips_bit_identical(tmp_path: Path) -> None:
    """continuous mode: shared m/z axis + per-pixel intensities.
    Round-trip through the reader must restore both arrays exactly."""
    mz = np.linspace(100.0, 900.0, 128)
    pixels = [
        _pixel(1, 1, mz, np.linspace(0.0, 100.0, 128)),
        _pixel(2, 1, mz, np.linspace(10.0, 110.0, 128)),
        _pixel(1, 2, mz, np.linspace(20.0, 120.0, 128)),
        _pixel(2, 2, mz, np.linspace(30.0, 130.0, 128)),
    ]
    out_imzml = tmp_path / "c.imzML"
    result = imzml_writer.write(
        pixels, out_imzml,
        mode="continuous",
        grid_max_x=2, grid_max_y=2,
        pixel_size_x=50.0, pixel_size_y=50.0,
    )
    assert result.imzml_path == out_imzml
    assert result.ibd_path == tmp_path / "c.ibd"
    assert result.mode == "continuous"
    assert result.n_pixels == 4
    assert result.imzml_path.is_file()
    assert result.ibd_path.is_file()

    imp = imzml_reader.read(out_imzml)
    assert imp.mode == "continuous"
    assert imp.uuid_hex == result.uuid_hex
    assert imp.grid_max_x == 2
    assert imp.grid_max_y == 2
    assert imp.pixel_size_x == 50.0
    assert imp.pixel_size_y == 50.0
    assert len(imp.spectra) == 4
    for i, roundtripped in enumerate(imp.spectra):
        np.testing.assert_array_equal(roundtripped.mz, pixels[i].mz)
        np.testing.assert_array_equal(roundtripped.intensity, pixels[i].intensity)
        assert roundtripped.x == pixels[i].x
        assert roundtripped.y == pixels[i].y


def test_processed_mode_round_trips_bit_identical(tmp_path: Path) -> None:
    """processed mode: every pixel has its own m/z + intensity."""
    pixels = [
        _pixel(1, 1, [100, 200, 300], [1, 2, 3]),
        _pixel(2, 1, [100, 200, 300, 400], [4, 5, 6, 7]),
        _pixel(1, 2, [150, 250], [8, 9]),
        _pixel(2, 2, [500.5, 600.25, 700.125], [10, 11, 12]),
    ]
    out_imzml = tmp_path / "p.imzML"
    result = imzml_writer.write(pixels, out_imzml, mode="processed")
    assert result.mode == "processed"

    imp = imzml_reader.read(out_imzml)
    assert imp.mode == "processed"
    assert len(imp.spectra) == 4
    for i, rt in enumerate(imp.spectra):
        np.testing.assert_array_equal(rt.mz, pixels[i].mz)
        np.testing.assert_array_equal(rt.intensity, pixels[i].intensity)


def test_continuous_mode_rejects_divergent_mz_axis(tmp_path: Path) -> None:
    """continuous mode requires every pixel's m/z array to match the
    shared axis bit-for-bit. Divergent axes must raise, not silently
    produce a file that the reader will reject."""
    mz_shared = np.linspace(100.0, 200.0, 16)
    mz_divergent = mz_shared.copy()
    mz_divergent[0] = 99.9  # single-element divergence
    pixels = [
        _pixel(1, 1, mz_shared, np.ones(16)),
        _pixel(2, 1, mz_divergent, np.ones(16)),
    ]
    with pytest.raises(ValueError, match="pixels to share the same m/z axis"):
        imzml_writer.write(pixels, tmp_path / "bad.imzML", mode="continuous")


def test_processed_mode_rejects_length_mismatch(tmp_path: Path) -> None:
    """processed mode requires mz + intensity arrays of the same length."""
    bad = ImzMLPixelSpectrum(
        x=1, y=1, z=1,
        mz=np.array([100.0, 200.0, 300.0]),
        intensity=np.array([1.0, 2.0]),
    )
    with pytest.raises(ValueError, match="must be the same length"):
        imzml_writer.write([bad], tmp_path / "bad.imzML", mode="processed")


def test_explicit_uuid_is_normalised_and_embedded(tmp_path: Path) -> None:
    """Caller-supplied UUIDs can include dashes / braces; they must be
    normalised to 32 lowercase hex chars before landing in the .ibd
    header + the .imzML ``IMS:1000080`` cvParam."""
    u = "{11223344-5566-7788-99AA-BBCCDDEEFF00}"
    pixels = [_pixel(1, 1, [100, 200], [1, 2])]
    result = imzml_writer.write(
        pixels, tmp_path / "u.imzML", mode="processed", uuid_hex=u,
    )
    assert result.uuid_hex == "11223344556677889aabbccddeeff00"[:32] or \
           result.uuid_hex.lower() == u.replace("{", "").replace("}", "").replace("-", "").lower()
    # .ibd header holds the raw 16 bytes; hex-decoded must match.
    ibd_head = (tmp_path / "u.ibd").read_bytes()[:16]
    assert ibd_head.hex() == result.uuid_hex


def test_rejects_invalid_uuid_length(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="32 hex chars"):
        imzml_writer.write(
            [_pixel(1, 1, [100], [1])],
            tmp_path / "u.imzML", mode="processed", uuid_hex="tooshort",
        )


def test_rejects_empty_pixel_list(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="at least one pixel"):
        imzml_writer.write([], tmp_path / "empty.imzML", mode="continuous")


def test_rejects_invalid_mode(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="continuous.*processed"):
        imzml_writer.write(
            [_pixel(1, 1, [100], [1])],
            tmp_path / "x.imzML", mode="wat",
        )


def test_grid_max_derived_from_pixel_coordinates(tmp_path: Path) -> None:
    """When grid_max_x/y aren't supplied, the writer picks up the max
    from actual coordinates so scanSettings matches the run content."""
    pixels = [
        _pixel(3, 5, [100], [1]),
        _pixel(7, 2, [100], [2]),
    ]
    result = imzml_writer.write(
        pixels, tmp_path / "g.imzML", mode="processed",
    )
    imp = imzml_reader.read(result.imzml_path)
    assert imp.grid_max_x == 7
    assert imp.grid_max_y == 5


def test_ibd_sha1_cvparam_matches_actual_ibd(tmp_path: Path) -> None:
    """The writer emits IMS:1000091 'ibd SHA-1' — validators + audit
    pipelines rely on that hash matching the companion .ibd."""
    import hashlib
    pixels = [_pixel(1, 1, [100, 200, 300], [1, 2, 3])]
    result = imzml_writer.write(pixels, tmp_path / "h.imzML", mode="processed")
    declared = (tmp_path / "h.imzML").read_text()
    # Extract the declared SHA-1 from the XML.
    import re
    match = re.search(r'ibd SHA-1"\s+value="([0-9a-f]+)"', declared)
    assert match, "writer must emit an ibd SHA-1 cvParam"
    declared_hash = match.group(1)
    actual_hash = hashlib.sha1(result.ibd_path.read_bytes()).hexdigest()
    assert declared_hash == actual_hash


def test_write_from_import_round_trips_metadata(tmp_path: Path) -> None:
    """write_from_import(read(...)) must preserve every field the
    importer exposes — mode, UUID, grid extents, pixel sizes, scan
    pattern, pixel coordinates, and all binary arrays."""
    # First, produce a seed file via write().
    seed_pixels = [
        _pixel(1, 1, [100, 200, 300], [1, 2, 3]),
        _pixel(2, 1, [100, 200, 300, 400], [4, 5, 6, 7]),
    ]
    seed = imzml_writer.write(
        seed_pixels, tmp_path / "seed.imzML", mode="processed",
        grid_max_x=2, grid_max_y=1, pixel_size_x=25.0, pixel_size_y=25.0,
        scan_pattern="meandering",
    )
    imported = imzml_reader.read(seed.imzml_path)

    # Re-emit to a new location and re-read.
    rewritten = imzml_writer.write_from_import(
        imported, tmp_path / "echo.imzML"
    )
    reread = imzml_reader.read(rewritten.imzml_path)
    assert reread.mode == imported.mode
    assert reread.uuid_hex == imported.uuid_hex
    assert reread.grid_max_x == imported.grid_max_x
    assert reread.grid_max_y == imported.grid_max_y
    assert reread.pixel_size_x == imported.pixel_size_x
    assert reread.pixel_size_y == imported.pixel_size_y
    assert reread.scan_pattern == imported.scan_pattern
    assert len(reread.spectra) == len(imported.spectra)
    for a, b in zip(reread.spectra, imported.spectra):
        np.testing.assert_array_equal(a.mz, b.mz)
        np.testing.assert_array_equal(a.intensity, b.intensity)
        assert a.x == b.x
        assert a.y == b.y
