"""Bruker timsTOF TDF importer — v0.8 M53.

Bruker's .d directory format holds two files:

* ``analysis.tdf``     — a plain SQLite database with metadata tables
  (``Frames``, ``Precursors``, ``Properties``, ``GlobalMetadata``, etc.).
* ``analysis.tdf_bin`` or ``analysis.tdf_raw`` — a binary blob with
  ZSTD-compressed frame data + scan-to-ion-index mapping.

The SQLite metadata is openly readable with the standard
:mod:`sqlite3` module. The binary decompression is delegated to the
``opentimspy`` + ``opentims-bruker-bridge`` packages (install with
``pip install 'mpeg-o[bruker]'``) which wrap the open-source
``libtimsdata.so`` implementation of the documented frame layout.

Output
------
Each MS1 frame becomes one :class:`~mpeg_o.spectral_dataset.WrittenRun`
entry with three parallel signal channels:

* ``mz`` — peak m/z values (float64 Da)
* ``intensity`` — raw peak intensities (float64)
* ``inv_ion_mobility`` — inverse reduced ion mobility 1/K₀
  (float64 Vs/cm²) — the third signal channel is new in v0.8 M53.

Ion mobility is preserved per-peak, not per-spectrum, because
timsTOF frames are 2-D acquisitions (multiple ion-mobility slices
per retention-time step). The parallel-arrays layout round-trips
exactly through the HDF5, Memory, SQLite, and Zarr providers.

Scope
-----
* MS1 frames are extracted; MS2 precursor/fragment relationships are
  captured as instrument metadata but not yet exploded into the
  per-spectrum ``precursor_mz`` field. A follow-up milestone will
  thread MS2 into the precursor compound schema.
* Retention time comes from the ``Frames.Time`` column in seconds.
* Instrument config is populated from the ``Properties`` and
  ``GlobalMetadata`` tables — vendor strings preserved verbatim.

Cross-language equivalents
--------------------------
Objective-C: ``MPGOBrukerTDFReader`` · Java:
``com.dtwthalion.mpgo.importers.BrukerTDFReader``.
Both Java and ObjC readers parse the SQLite metadata natively (via
``sqlite-jdbc`` and ``libsqlite3`` respectively); binary frame data
extraction delegates to this Python module via subprocess, matching
the ThermoRawReader pattern (M38).

API status: Provisional (v0.8 M53). Binary decompression via
``opentimspy`` is the only supported path in v0.8; a native-C port
of the frame decoder is deferred to v0.9.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import sqlite3
from contextlib import closing
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np

from ..enums import AcquisitionMode
from ..spectral_dataset import SpectralDataset, WrittenRun


__all__ = [
    "BrukerTDFUnavailableError",
    "BrukerTDFMetadata",
    "read_metadata",
    "read",
]


class BrukerTDFUnavailableError(RuntimeError):
    """Raised when ``opentimspy`` is not installed and binary frame
    extraction is requested. Metadata-only reads via
    :func:`read_metadata` remain available without the optional
    dependency."""


@dataclass(frozen=True, slots=True)
class BrukerTDFMetadata:
    """Summary of an ``analysis.tdf`` metadata snapshot."""

    frame_count: int
    ms1_frame_count: int
    ms2_frame_count: int
    retention_time_min: float
    retention_time_max: float
    mobility_range: tuple[float, float]   # (inv_ion_mobility min, max)
    mz_range: tuple[float, float]
    instrument_vendor: str
    instrument_model: str
    acquisition_software: str
    properties: dict[str, str]     # raw Properties table
    global_metadata: dict[str, str]  # raw GlobalMetadata table


# ── Public API ──────────────────────────────────────────────────────


def read_metadata(d_dir: str | Path) -> BrukerTDFMetadata:
    """Read the SQLite metadata from an ``analysis.tdf`` without
    opening the binary blob. Works on any host that has the standard
    :mod:`sqlite3` module — no ``opentimspy`` required."""
    d = Path(d_dir)
    tdf = _locate_tdf(d)
    with closing(sqlite3.connect(tdf)) as conn:
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()
        # Frames table
        cur.execute("SELECT COUNT(*) FROM Frames")
        frame_count = int(cur.fetchone()[0] or 0)
        cur.execute("SELECT COUNT(*) FROM Frames WHERE MsMsType = 0")
        ms1 = int(cur.fetchone()[0] or 0)
        cur.execute("SELECT COUNT(*) FROM Frames WHERE MsMsType != 0")
        ms2 = int(cur.fetchone()[0] or 0)
        cur.execute("SELECT MIN(Time), MAX(Time) FROM Frames")
        rt_row = cur.fetchone()
        rt_min = float(rt_row[0] or 0.0)
        rt_max = float(rt_row[1] or 0.0)
        # GlobalMetadata (KV table)
        global_md: dict[str, str] = {}
        try:
            cur.execute("SELECT Key, Value FROM GlobalMetadata")
            for row in cur.fetchall():
                global_md[str(row[0])] = str(row[1])
        except sqlite3.OperationalError:
            pass
        # Properties (KV table)
        properties: dict[str, str] = {}
        try:
            cur.execute("SELECT Key, Value FROM Properties")
            for row in cur.fetchall():
                properties[str(row[0])] = str(row[1])
        except sqlite3.OperationalError:
            pass

    vendor = _pick(global_md, "InstrumentVendor", "Vendor") or "Bruker"
    model = _pick(global_md, "InstrumentName", "Model", "MaldiApplicationType") or ""
    software = _pick(global_md, "AcquisitionSoftware", "OperatingSystem") or ""

    # Mobility + mz ranges require opentimspy to be present AND the
    # binary blob to exist on disk. Fall back to 0 otherwise — these
    # values are informational on the metadata-only path.
    mz_lo, mz_hi = 0.0, 0.0
    im_lo, im_hi = 0.0, 0.0
    try:
        from opentimspy.opentims import OpenTIMS  # type: ignore[import-not-found]
        ot = OpenTIMS(d)
        try:
            mz_lo = float(ot.min_mz); mz_hi = float(ot.max_mz)
            im_lo = float(ot.min_inv_ion_mobility)
            im_hi = float(ot.max_inv_ion_mobility)
        finally:
            ot.close()
    except (ImportError, RuntimeError, OSError, ValueError):
        # opentimspy missing, or the directory lacks the binary blob /
        # bridge library — informational metadata stays at zero.
        pass

    return BrukerTDFMetadata(
        frame_count=frame_count,
        ms1_frame_count=ms1,
        ms2_frame_count=ms2,
        retention_time_min=rt_min,
        retention_time_max=rt_max,
        mobility_range=(im_lo, im_hi),
        mz_range=(mz_lo, mz_hi),
        instrument_vendor=vendor,
        instrument_model=model,
        acquisition_software=software,
        properties=properties,
        global_metadata=global_md,
    )


def read(d_dir: str | Path, output_path: str | Path, *,
         title: str | None = None,
         ms2: bool = False) -> Path:
    """Import a Bruker ``.d`` directory to an ``.mpgo`` file.

    Requires the optional ``opentimspy`` + ``opentims-bruker-bridge``
    dependencies (``pip install 'mpeg-o[bruker]'``). Raises
    :class:`BrukerTDFUnavailableError` otherwise — use
    :func:`read_metadata` for the metadata-only fallback.

    One spectrum is produced per MS1 frame by default. Each spectrum
    stores three parallel signal channels:
    ``mz`` / ``intensity`` / ``inv_ion_mobility``. The last is the
    new v0.8 addition — ion mobility is preserved per-peak so the
    2-D tims geometry survives the round trip.

    Args:
        d_dir: Path to the Bruker ``.d`` directory.
        output_path: Target ``.mpgo`` file path.
        title: Optional study title; defaults to the ``.d`` stem.
        ms2: If True, also emit MS2 fragment frames as a second run.
             Defaults to MS1-only; MS2 precursor threading is a v0.9
             concern (see module docstring).
    """
    try:
        from opentimspy.opentims import OpenTIMS  # type: ignore[import-not-found]
    except ImportError as exc:
        raise BrukerTDFUnavailableError(
            "Binary frame decompression requires the optional "
            "'opentimspy' + 'opentims-bruker-bridge' dependencies. "
            "Install with: pip install 'mpeg-o[bruker]'"
        ) from exc

    d = Path(d_dir)
    if not d.is_dir():
        raise FileNotFoundError(f"Bruker .d directory not found: {d}")

    metadata = read_metadata(d)

    ot = OpenTIMS(d)
    try:
        frames = np.asarray(ot.frames)
        ms_types = np.asarray(ot.ms_types)  # 0 = MS1, 9 = MS2 DDA, ...
        if frames.size == 0:
            raise ValueError(f"Bruker .d is empty: {d}")

        runs: dict[str, WrittenRun] = {}
        runs["tims_ms1"] = _build_run(
            ot, np.asarray(ot.ms1_frames, dtype=np.int64),
            spectrum_class="MPGOMassSpectrum",
            acquisition_mode=int(AcquisitionMode.MS1_DDA),
        )
        if ms2 and ot.ms2_frames is not None and len(ot.ms2_frames) > 0:
            runs["tims_ms2"] = _build_run(
                ot, np.asarray(ot.ms2_frames, dtype=np.int64),
                spectrum_class="MPGOMassSpectrum",
                acquisition_mode=int(AcquisitionMode.MS2_DDA),
            )
    finally:
        ot.close()

    out = SpectralDataset.write_minimal(
        output_path,
        title=title or d.stem,
        isa_investigation_id="",
        runs=runs,
        provenance=None,
        features=None,
    )
    # Instrument metadata is returned by read_metadata() but not yet
    # auto-populated into the .mpgo instrument-config group; that is
    # a v0.9 enhancement (MPEG-O's instrument-config schema needs
    # Bruker-specific field mapping). For now, callers can query
    # read_metadata() directly for the raw Properties / GlobalMetadata
    # key/value pairs and stamp them manually.
    _ = metadata  # silence unused warning; kept for API discoverability
    return Path(out)


# ── Internals ────────────────────────────────────────────────────────


def _locate_tdf(d: Path) -> Path:
    """Return the path to ``analysis.tdf`` inside the ``.d`` directory."""
    if not d.is_dir():
        raise FileNotFoundError(
            f"No analysis.tdf found under {d} — is this a Bruker .d directory?")
    candidate = d / "analysis.tdf"
    if candidate.is_file():
        return candidate
    # Some tools nest the .d under a parent — try one level in.
    for child in d.iterdir():
        if child.is_dir() and (child / "analysis.tdf").is_file():
            return child / "analysis.tdf"
    raise FileNotFoundError(
        f"No analysis.tdf found under {d} — is this a Bruker .d directory?")


def _pick(d: dict[str, str], *keys: str) -> str:
    for k in keys:
        v = d.get(k)
        if v:
            return v
    return ""


def _build_run(ot: Any, frame_ids: np.ndarray,
                *, spectrum_class: str, acquisition_mode: int) -> WrittenRun:
    """Convert a batch of frames into a WrittenRun with three parallel
    signal channels."""
    frame_ids = np.asarray(frame_ids, dtype=np.int64)
    if frame_ids.size == 0:
        return _empty_run(spectrum_class, acquisition_mode)

    peaks = ot.query(frame_ids,
                      columns=("frame", "intensity", "mz", "inv_ion_mobility"))
    frame_col = np.asarray(peaks["frame"], dtype=np.int64)
    mz_col = np.asarray(peaks["mz"], dtype=np.float64)
    intensity_col = np.asarray(peaks["intensity"], dtype=np.float64)
    im_col = np.asarray(peaks["inv_ion_mobility"], dtype=np.float64)

    # Group peaks by frame in the original frame_ids order (peaks may
    # come back unordered across frames but ordered within each).
    order = np.argsort(frame_col, kind="stable")
    frame_col = frame_col[order]
    mz_col = mz_col[order]
    intensity_col = intensity_col[order]
    im_col = im_col[order]

    n = len(frame_ids)
    lengths = np.zeros(n, dtype=np.uint32)
    # Count per frame.
    # frame_col is sorted; find group boundaries.
    unique_frames, counts = np.unique(frame_col, return_counts=True)
    # Map frame_ids → length in position-preserving order.
    frame_to_count = dict(zip(unique_frames.tolist(), counts.tolist()))
    for i, fid in enumerate(frame_ids.tolist()):
        lengths[i] = int(frame_to_count.get(fid, 0))

    offsets = np.zeros(n, dtype=np.uint64)
    if n > 0:
        offsets[1:] = np.cumsum(lengths[:-1], dtype=np.uint64)

    # Reorder peaks so that their frame order matches frame_ids.
    # Build a permutation from sorted frame_col back to frame_ids order.
    total = int(lengths.sum())
    mz_buf = np.empty(total, dtype=np.float64)
    int_buf = np.empty(total, dtype=np.float64)
    im_buf = np.empty(total, dtype=np.float64)
    # Slice by unique frame group, then place at the target offset
    # corresponding to the frame_ids ordering.
    sorted_offsets = np.cumsum(np.r_[0, counts[:-1]])
    for i, fid in enumerate(frame_ids.tolist()):
        if fid in frame_to_count and frame_to_count[fid] > 0:
            group_idx = int(np.searchsorted(unique_frames, fid))
            src_start = int(sorted_offsets[group_idx])
            src_end = src_start + int(counts[group_idx])
            dst_start = int(offsets[i])
            dst_end = dst_start + int(lengths[i])
            mz_buf[dst_start:dst_end] = mz_col[src_start:src_end]
            int_buf[dst_start:dst_end] = intensity_col[src_start:src_end]
            im_buf[dst_start:dst_end] = im_col[src_start:src_end]

    # Per-spectrum retention time.
    rts = np.asarray([ot.frame2retention_time(int(f)) for f in frame_ids.tolist()],
                     dtype=np.float64)
    ms_levels = np.full(n, 1 if acquisition_mode == 0 else 2, dtype=np.int32)
    polarities = np.zeros(n, dtype=np.int32)
    precursor_mzs = np.zeros(n, dtype=np.float64)
    precursor_charges = np.zeros(n, dtype=np.int32)
    base_peaks = np.empty(n, dtype=np.float64)
    for i in range(n):
        s, e = int(offsets[i]), int(offsets[i]) + int(lengths[i])
        base_peaks[i] = float(int_buf[s:e].max()) if e > s else 0.0

    return WrittenRun(
        spectrum_class=spectrum_class,
        acquisition_mode=acquisition_mode,
        channel_data={
            "mz": mz_buf,
            "intensity": int_buf,
            "inv_ion_mobility": im_buf,
        },
        offsets=offsets,
        lengths=lengths,
        retention_times=rts,
        ms_levels=ms_levels,
        polarities=polarities,
        precursor_mzs=precursor_mzs,
        precursor_charges=precursor_charges,
        base_peak_intensities=base_peaks,
        nucleus_type="",
        chromatograms=[],
    )


def _empty_run(spectrum_class: str, acquisition_mode: int) -> WrittenRun:
    z8 = np.zeros(0, dtype=np.uint64)
    z4 = np.zeros(0, dtype=np.uint32)
    f8 = np.zeros(0, dtype=np.float64)
    i4 = np.zeros(0, dtype=np.int32)
    return WrittenRun(
        spectrum_class=spectrum_class,
        acquisition_mode=acquisition_mode,
        channel_data={"mz": f8, "intensity": f8, "inv_ion_mobility": f8},
        offsets=z8, lengths=z4,
        retention_times=f8, ms_levels=i4, polarities=i4,
        precursor_mzs=f8, precursor_charges=i4, base_peak_intensities=f8,
        chromatograms=[],
    )


