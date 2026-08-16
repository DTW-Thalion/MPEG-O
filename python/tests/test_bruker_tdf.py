"""Milestone 53 — Bruker timsTOF TDF importer (Python side).

Tests split into two tiers:

* **Metadata-only** (always runs): builds a synthetic ``analysis.tdf``
  SQLite database with the tables :mod:`ttio.importers.bruker_tdf`
  reads (``Frames``, ``GlobalMetadata``, ``Properties``). Verifies
  frame-count and metadata-extraction paths without needing
  ``opentimspy`` or a real Bruker fixture.
* **Binary round-trip** (skipped if no real ``.d`` fixture available):
  requires a user-supplied Bruker timsTOF directory pointed at by the
  ``TTIO_BRUKER_TDF_FIXTURE`` environment variable. Extracts m/z,
  intensity, inv_ion_mobility peaks via opentimspy and asserts the
  written ``.tio`` round-trips with three signal channels.
"""
from __future__ import annotations

import os
import sqlite3
from pathlib import Path

import pytest


def _write_synthetic_tdf(d_dir: Path,
                          *,
                          frame_count: int = 3,
                          ms1_count: int = 2,
                          vendor: str = "Bruker",
                          model: str = "timsTOF Pro") -> None:
    """Construct a minimal ``analysis.tdf`` SQLite file with the
    metadata tables the TTI-O importer consumes. No binary blob is
    emitted — the metadata-only tests use this path."""
    d_dir.mkdir(parents=True, exist_ok=True)
    tdf = d_dir / "analysis.tdf"
    if tdf.exists():
        tdf.unlink()
    conn = sqlite3.connect(str(tdf))
    c = conn.cursor()
    c.execute("""
        CREATE TABLE Frames (
            Id INTEGER PRIMARY KEY,
            Time REAL NOT NULL,
            MsMsType INTEGER NOT NULL
        )""")
    c.execute("CREATE TABLE GlobalMetadata (Key TEXT PRIMARY KEY, Value TEXT)")
    c.execute("CREATE TABLE Properties (Key TEXT PRIMARY KEY, Value TEXT)")

    for i in range(frame_count):
        c.execute(
            "INSERT INTO Frames (Id, Time, MsMsType) VALUES (?, ?, ?)",
            (i + 1, 0.5 * (i + 1), 0 if i < ms1_count else 9),
        )
    for k, v in [
        ("InstrumentVendor", vendor),
        ("InstrumentName", model),
        ("AcquisitionSoftware", "timsControl 4.0"),
    ]:
        c.execute(
            "INSERT INTO GlobalMetadata (Key, Value) VALUES (?, ?)", (k, v))
    for k, v in [("MotorZ1", "-0.5"), ("BeamSplitterConfig", "NONE")]:
        c.execute("INSERT INTO Properties (Key, Value) VALUES (?, ?)", (k, v))
    conn.commit()
    conn.close()


def test_metadata_reads_synthetic_fixture(tmp_path: Path) -> None:
    from ttio.importers.bruker_tdf import read_metadata

    d = tmp_path / "example.d"
    _write_synthetic_tdf(d, frame_count=5, ms1_count=3,
                         vendor="Bruker Daltonics",
                         model="timsTOF SCP")

    md = read_metadata(d)
    assert md.frame_count == 5
    assert md.ms1_frame_count == 3
    assert md.ms2_frame_count == 2
    assert md.retention_time_min == pytest.approx(0.5)
    assert md.retention_time_max == pytest.approx(0.5 * 5)
    assert md.instrument_vendor == "Bruker Daltonics"
    assert md.instrument_model == "timsTOF SCP"
    assert md.acquisition_software == "timsControl 4.0"
    assert "MotorZ1" in md.properties
    assert md.properties["BeamSplitterConfig"] == "NONE"


def test_metadata_raises_on_non_tdf_directory(tmp_path: Path) -> None:
    from ttio.importers.bruker_tdf import read_metadata
    with pytest.raises(FileNotFoundError, match="analysis.tdf"):
        read_metadata(tmp_path / "does_not_exist.d")


def _write_synthetic_tsf(d_dir: Path) -> None:
    """Construct a minimal ``analysis.tsf`` (non-TIMS Bruker) SQLite
    metadata file. Same schema as ``.tdf`` — only the file name and
    binary frame layout differ. Used for the .tsf-detection tests."""
    d_dir.mkdir(parents=True, exist_ok=True)
    tsf = d_dir / "analysis.tsf"
    if tsf.exists():
        tsf.unlink()
    conn = sqlite3.connect(str(tsf))
    c = conn.cursor()
    c.execute("CREATE TABLE Frames (Id INTEGER PRIMARY KEY, Time REAL, MsMsType INTEGER)")
    c.execute("CREATE TABLE GlobalMetadata (Key TEXT PRIMARY KEY, Value TEXT)")
    c.execute("CREATE TABLE Properties (Key TEXT PRIMARY KEY, Value TEXT)")
    c.execute("INSERT INTO Frames VALUES (1, 0.5, 0)")
    c.execute("INSERT INTO Frames VALUES (2, 1.0, 0)")
    c.execute("INSERT INTO GlobalMetadata VALUES ('InstrumentVendor', 'Bruker')")
    c.execute("INSERT INTO GlobalMetadata VALUES ('InstrumentName', 'rapifleX')")
    c.execute("INSERT INTO GlobalMetadata VALUES ('AcquisitionSoftware', 'flexControl')")
    conn.commit()
    conn.close()


def test_metadata_reads_tsf_directory(tmp_path: Path) -> None:
    """``read_metadata`` works on .tsf inputs (non-TIMS Bruker). The
    SQLite schema is identical to .tdf for the metadata tables we
    consume; the only difference is binary frame layout, which
    metadata-only access doesn't touch."""
    from ttio.importers.bruker_tdf import read_metadata
    d = tmp_path / "non_tims.d"
    _write_synthetic_tsf(d)
    md = read_metadata(d)
    assert md.frame_count == 2
    assert md.ms1_frame_count == 2
    assert md.instrument_vendor == "Bruker"
    assert md.instrument_model == "rapifleX"


def test_read_rejects_tsf_with_clear_error(tmp_path: Path) -> None:
    """Full per-frame ``read()`` raises BrukerTDFUnavailableError on
    a .tsf directory rather than crashing inside opentimspy (which
    is TDF-only). Users get a pointer at the msconvert workaround."""
    from ttio.importers.bruker_tdf import read, BrukerTDFUnavailableError
    d = tmp_path / "non_tims.d"
    _write_synthetic_tsf(d)
    out = tmp_path / "out.tio"
    with pytest.raises(
        BrukerTDFUnavailableError,
        match=r"\.tsf .*non-TIMS|msconvert"
    ):
        read(d, out)


def test_read_without_opentimspy_raises_cleanly(tmp_path: Path) -> None:
    """If opentimspy is not importable, ``read()`` must raise
    :class:`BrukerTDFUnavailableError` with install guidance — the
    module import itself must remain healthy so ``read_metadata``
    stays callable on opentimspy-free hosts."""
    from ttio.importers.bruker_tdf import (
        BrukerTDFUnavailableError,
        read,
    )
    import sys
    import builtins

    d = tmp_path / "no_bin.d"
    _write_synthetic_tdf(d)

    # Simulate opentimspy missing.
    real_import = builtins.__import__
    def _patched(name, *args, **kwargs):
        if name == "opentimspy.opentims" or name == "opentimspy":
            raise ImportError("simulated missing opentimspy")
        return real_import(name, *args, **kwargs)
    builtins.__import__ = _patched
    try:
        if "opentimspy.opentims" in sys.modules:
            del sys.modules["opentimspy.opentims"]
        if "opentimspy" in sys.modules:
            del sys.modules["opentimspy"]
        with pytest.raises(BrukerTDFUnavailableError, match="opentimspy"):
            read(d, tmp_path / "out.tio")
    finally:
        builtins.__import__ = real_import


_FIXTURE_ENV = "TTIO_BRUKER_TDF_FIXTURE"


@pytest.mark.skipif(
    os.environ.get(_FIXTURE_ENV) is None,
    reason=f"{_FIXTURE_ENV} not set — skipping real-Bruker round-trip",
)
def test_real_tdf_round_trip(tmp_path: Path) -> None:
    """Full round-trip: read a real Bruker .d via opentimspy, write
    a .tio, reopen, and assert that the three signal channels
    (mz / intensity / inv_ion_mobility) round-trip and the frame
    count matches the SQLite Frames table."""
    opentimspy = pytest.importorskip("opentimspy.opentims")
    from ttio.importers.bruker_tdf import read, read_metadata
    from ttio.spectral_dataset import SpectralDataset

    d_dir = Path(os.environ[_FIXTURE_ENV]).expanduser().resolve()
    assert d_dir.is_dir(), f"fixture .d not found: {d_dir}"

    md = read_metadata(d_dir)
    assert md.frame_count > 0
    assert md.mz_range[1] > md.mz_range[0]

    out = tmp_path / "tims.tio"
    written = read(d_dir, out)
    assert written.is_file()

    # Cross-check against opentimspy directly.
    ot = opentimspy.OpenTIMS(d_dir)
    try:
        assert len(ot.ms1_frames) > 0
    finally:
        ot.close()

    # Re-open the written file and verify the ion-mobility channel
    # is present with matching shape.
    with SpectralDataset.open(written, mode="r") as sd:
        root = sd.provider.root_group()
        run_group = (
            root.open_group("study")
            .open_group("ms_runs")
            .open_group("tims_ms1")
        )
        channels = run_group.open_group("signal_channels")
        # Channels are stored with the ``_values`` suffix on disk (the
        # canonical signal-channel layout).
        names = channels.child_names()
        assert "mz_values" in names
        assert "intensity_values" in names
        assert "inv_ion_mobility_values" in names

        # Under the codec-17 MS default the datasets are FDZ1 streams
        # whose byte lengths differ per channel; compare decoded
        # element counts, not raw dataset shapes.
        def _element_count(name: str) -> int:
            import numpy as np
            from ttio import _hdf5_io as io
            ds = channels.open_dataset(name)
            codec = io.read_int_attr(ds, "compression", default=0) or 0
            if codec == 17:
                from ttio.codecs import float_delta_zstd as fdz
                return fdz.decode(
                    bytes(np.asarray(ds.read(), dtype=np.uint8))).shape[0]
            return ds.shape[0]

        assert (_element_count("mz_values")
                == _element_count("inv_ion_mobility_values"))
