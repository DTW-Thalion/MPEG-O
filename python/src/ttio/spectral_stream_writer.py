"""``SpectralStreamWriter``: append spectra to a spectral run with
bounded memory.

The on-disk layout is the one :func:`spectral_dataset._write_run`
produces (``spectrum_index/*``, ``signal_channels/<c>_values`` with
``@compression``); the datasets are extendable and appended per
batch, and a codec-17 channel's FDZ1 header (``n_values``,
``n_blocks``) is written at close. Every existing spectral reader opens
the result unchanged. Design:
``docs/superpowers/specs/2026-08-16-streaming-blocks-v1-design.md`` 3.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

from typing import Any

import numpy as np

from . import _hdf5_io as io
from .codecs import float_delta_zstd as fdz
from .enums import Compression, Precision, SpectrumKind

_INDEX_COLUMNS: tuple[tuple[str, Precision, str], ...] = (
    ("lengths", Precision.UINT32, "<u4"),
    ("retention_times", Precision.FLOAT64, "<f8"),
    ("ms_levels", Precision.INT32, "<i4"),
    ("polarities", Precision.INT32, "<i4"),
    ("precursor_mzs", Precision.FLOAT64, "<f8"),
    ("precursor_charges", Precision.INT32, "<i4"),
    ("base_peak_intensities", Precision.FLOAT64, "<f8"),
)
_M74_COLUMNS: tuple[tuple[str, Precision, str], ...] = (
    ("activation_methods", Precision.INT32, "<i4"),
    ("isolation_target_mzs", Precision.FLOAT64, "<f8"),
    ("isolation_lower_offsets", Precision.FLOAT64, "<f8"),
    ("isolation_upper_offsets", Precision.FLOAT64, "<f8"),
)
_INSTRUMENT_FIELDS = ("manufacturer", "model", "serial_number",
                      "source_type", "analyzer_type", "detector_type")


class SpectralStreamWriter:
    """Append spectra to one spectral run of an open-for-write dataset."""

    def __init__(self, study_group, run_name: str, *, spectrum_class: str,
                 acquisition_mode: int, channel_names: list[str],
                 instrument_config=None, batch_spectra: int = 4096,
                 opt_disable_float_delta: bool = False,
                 signal_compression: str = "gzip",
                 nucleus_type: str = "", solvent: str = "",
                 provenance_records=None):
        if signal_compression not in ("gzip", "none"):
            raise ValueError("SpectralStreamWriter supports signal_compression "
                             "'gzip' or 'none' (numpress is not a streaming codec)")
        self._study = study_group
        self._name = run_name
        self._spectrum_class = spectrum_class
        self._acq = int(acquisition_mode)
        self._channels = list(channel_names)
        self._instrument = instrument_config
        self._batch = int(batch_spectra)
        self._nucleus, self._solvent = nucleus_type, solvent
        self._provenance = list(provenance_records or [])
        use_fdz = (signal_compression == "gzip" and not opt_disable_float_delta
                   and spectrum_class == SpectrumKind.MASS.value)
        self._codec = "float_delta_zstd" if use_fdz else signal_compression
        self._pending: list = []
        self._pending_n = 0
        self._count = 0
        self._g = None
        self._idx: dict[str, Any] = {}
        self._sig: dict[str, Any] = {}
        self._fdz_buf: dict[str, np.ndarray] = {}
        self._fdz_n: dict[str, int] = {}
        self._fdz_blocks: dict[str, int] = {}
        self._m74: bool | None = None
        self._centroided: bool | None = None
        self._chromatograms: list = []
        self._closed = False

    def set_chromatograms(self, chromatograms) -> None:
        """Chromatogram traces written at close (mzML carries them
        after the spectra)."""
        self._chromatograms = list(chromatograms or [])

    # ------------------------------------------------------------------
    @property
    def spectrum_count(self) -> int:
        return self._count

    def append(self, spectrum) -> None:
        """Append one :class:`~ttio.spectrum.Spectrum`."""
        from .importers.import_result import ImportedSpectrum, _pack_run
        arrs = [np.asarray(spectrum.signal_array(c).data, dtype=np.float64)
                for c in self._channels]
        imp = ImportedSpectrum(
            mz_or_chemical_shift=arrs[0], intensity=arrs[1] if len(arrs) > 1 else arrs[0],
            retention_time=float(getattr(spectrum, "scan_time_seconds", 0.0)),
            ms_level=int(getattr(spectrum, "ms_level", 1)),
            polarity=int(getattr(spectrum, "polarity", 2)),
            precursor_mz=float(getattr(spectrum, "precursor_mz", 0.0)),
            precursor_charge=int(getattr(spectrum, "precursor_charge", 0)),
        )
        run = _pack_run([imp], spectrum_class=self._spectrum_class,
                        acquisition_mode=self._acq, channel_x=self._channels[0])
        self.append_batch(run)

    def append_batch(self, batch) -> None:
        """Append every spectrum of a :class:`~ttio.spectral_dataset.WrittenRun`."""
        if self._closed:
            raise RuntimeError("writer is closed")
        n = int(batch.offsets.shape[0])
        if n == 0:
            return
        if set(batch.channel_data.keys()) != set(self._channels):
            raise ValueError(f"batch channels {sorted(batch.channel_data)} do not match "
                             f"writer channels {sorted(self._channels)}")
        self._pending.append(batch)
        self._pending_n += n
        if self._pending_n >= self._batch:
            self.flush()

    def flush(self) -> None:
        if not self._pending:
            return
        for b in self._pending:
            self._write_batch(b)
        self._pending = []
        self._pending_n = 0

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self.flush()
        if self._g is None:
            self._ensure_layout()
        for c in self._channels:
            if self._codec == "float_delta_zstd":
                buf = self._fdz_buf.get(c)
                if buf is not None and len(buf):
                    self._emit_fdz_block(c, buf)
                    self._fdz_buf[c] = np.zeros(0, dtype=np.float64)
                self._sig[c].write_slice(
                    0, np.frombuffer(fdz.header_bytes(self._fdz_n.get(c, 0),
                                                      self._fdz_blocks.get(c, 0)),
                                     dtype=np.uint8))
        io.write_int_attr(self._g, "spectrum_count", self._count)
        io.write_int_attr(self._g.open_group("spectrum_index"), "count", self._count)
        if self._provenance:
            from ._dataset_write_metadata import _write_provenance
            prov = self._g.create_group("provenance")
            _write_provenance(prov, self._provenance, dataset_name="steps")
        if self._chromatograms:
            from .acquisition_run import write_chromatograms_to_run_group
            write_chromatograms_to_run_group(self._g, self._chromatograms)

    def __enter__(self) -> "SpectralStreamWriter":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    # ------------------------------------------------------------------
    def _runs_group(self):
        # write_minimal keeps NMR runs under nmr_runs and everything
        # else (MS, IR, Raman, UV-Vis) under ms_runs.
        gname = "nmr_runs" if self._spectrum_class == SpectrumKind.NMR.value else "ms_runs"
        if self._study.has_child(gname):
            g = self._study.open_group(gname)
        else:
            g = self._study.create_group(gname)
            io.write_fixed_string_attr(g, "_run_names", "")
        names = [n for n in (io.read_string_attr(g, "_run_names", default="") or "").split(",") if n]
        if self._name not in names:
            names.append(self._name)
            io.write_fixed_string_attr(g, "_run_names", ",".join(names))
        return g

    def _ensure_layout(self, first=None) -> None:
        if self._g is not None:
            return
        parent = self._runs_group()
        if parent.has_child(self._name):
            raise ValueError(f"run {self._name!r} already exists")
        g = parent.create_group(self._name)
        io.write_int_attr(g, "acquisition_mode", self._acq)
        io.write_int_attr(g, "spectrum_count", 0)
        io.write_fixed_string_attr(g, "spectrum_class", self._spectrum_class)
        if self._nucleus:
            io.write_fixed_string_attr(g, "nucleus_type", self._nucleus)
        if self._solvent:
            io.write_fixed_string_attr(g, "solvent", self._solvent)
        cfg = g.create_group("instrument_config")
        for f in _INSTRUMENT_FIELDS:
            io.write_fixed_string_attr(cfg, f, str(getattr(self._instrument, f, "") or ""))
        idx = g.create_group("spectrum_index")
        io.write_int_attr(idx, "count", 0)
        cols = list(_INDEX_COLUMNS)
        if first is not None:
            m74 = (first.activation_methods, first.isolation_target_mzs,
                   first.isolation_lower_offsets, first.isolation_upper_offsets)
            self._m74 = all(c is not None for c in m74)
            if any(c is not None for c in m74) and not self._m74:
                raise ValueError("WrittenRun M74 columns must be either all-None or all-set")
            self._centroided = first.centroideds is not None
        if self._m74:
            cols += list(_M74_COLUMNS)
        if self._centroided:
            cols.append(("centroideds", Precision.INT32, "<i4"))
        for name, prec, _ in cols:
            self._idx[name] = idx.create_dataset(
                name, prec, 0, chunk_size=io.DEFAULT_INDEX_CHUNK,
                compression=Compression.ZLIB, compression_level=6, extendable=True)
        sig = g.create_group("signal_channels")
        io.write_fixed_string_attr(sig, "channel_names", ",".join(self._channels))
        for c in self._channels:
            if self._codec == "float_delta_zstd":
                ds = sig.create_dataset(f"{c}_values", Precision.UINT8, 0,
                                        chunk_size=io.DEFAULT_SIGNAL_CHUNK,
                                        compression=Compression.NONE, extendable=True)
                io.write_int_attr(ds, "compression", int(Compression.FLOAT_DELTA_ZSTD), dtype="<u1")
                ds.append(np.frombuffer(fdz.header_bytes(0, 0), dtype=np.uint8))
                self._fdz_buf[c] = np.zeros(0, dtype=np.float64)
                self._fdz_n[c] = 0
                self._fdz_blocks[c] = 0
            else:
                ds = sig.create_dataset(
                    f"{c}_values", Precision.FLOAT64, 0, chunk_size=io.DEFAULT_SIGNAL_CHUNK,
                    compression=(Compression.ZLIB if self._codec == "gzip" else Compression.NONE),
                    compression_level=6, extendable=True)
            self._sig[c] = ds
        self._g = g

    def _write_batch(self, b) -> None:
        self._ensure_layout(b)
        n = int(b.offsets.shape[0])
        cols = {"lengths": b.lengths, "retention_times": b.retention_times,
                "ms_levels": b.ms_levels, "polarities": b.polarities,
                "precursor_mzs": b.precursor_mzs, "precursor_charges": b.precursor_charges,
                "base_peak_intensities": b.base_peak_intensities}
        # Optional M74 / centroided columns are all-or-nothing on disk;
        # a batch that first carries them makes the writer create the
        # datasets and backfill zero sentinels for the spectra already
        # written, and a batch that lacks them appends zero sentinels.
        m74_batch = all(c is not None for c in (b.activation_methods, b.isolation_target_mzs,
                                                b.isolation_lower_offsets, b.isolation_upper_offsets))
        if m74_batch and not self._m74:
            self._m74 = True
            idx = self._g.open_group("spectrum_index")
            for name, prec, dt in _M74_COLUMNS:
                ds = idx.create_dataset(name, prec, 0, chunk_size=io.DEFAULT_INDEX_CHUNK,
                                        compression=Compression.ZLIB, compression_level=6,
                                        extendable=True)
                if self._count:
                    ds.append(np.zeros(self._count, dtype=dt))
                self._idx[name] = ds
        if b.centroideds is not None and not self._centroided:
            self._centroided = True
            idx = self._g.open_group("spectrum_index")
            ds = idx.create_dataset("centroideds", Precision.INT32, 0,
                                    chunk_size=io.DEFAULT_INDEX_CHUNK,
                                    compression=Compression.ZLIB, compression_level=6,
                                    extendable=True)
            if self._count:
                ds.append(np.zeros(self._count, dtype="<i4"))
            self._idx["centroideds"] = ds
        if self._m74:
            cols.update(activation_methods=b.activation_methods,
                        isolation_target_mzs=b.isolation_target_mzs,
                        isolation_lower_offsets=b.isolation_lower_offsets,
                        isolation_upper_offsets=b.isolation_upper_offsets)
        if self._centroided:
            cols["centroideds"] = b.centroideds
        for name, prec, dt in _INDEX_COLUMNS + _M74_COLUMNS + (("centroideds", Precision.INT32, "<i4"),):
            if name in self._idx:
                arr = cols.get(name)
                if arr is None:
                    arr = np.zeros(n, dtype=dt)
                self._idx[name].append(np.asarray(arr).astype(dt, copy=False))
        for c in self._channels:
            data = np.ascontiguousarray(b.channel_data[c], dtype=np.float64)
            if self._codec == "float_delta_zstd":
                buf = np.concatenate([self._fdz_buf[c], data]) if len(self._fdz_buf[c]) else data
                while len(buf) >= fdz.BLOCK_SIZE:
                    self._emit_fdz_block(c, buf[:fdz.BLOCK_SIZE])
                    buf = buf[fdz.BLOCK_SIZE:]
                self._fdz_buf[c] = np.array(buf, copy=True)
            else:
                self._sig[c].append(data.astype("<f8", copy=False))
        self._count += n
        io.write_int_attr(self._g, "spectrum_count", self._count)
        io.write_int_attr(self._g.open_group("spectrum_index"), "count", self._count)

    def _emit_fdz_block(self, c: str, values: np.ndarray) -> None:
        transform, body = fdz.encode_block(np.ascontiguousarray(values, dtype=np.float64))
        self._sig[c].append(np.frombuffer(fdz.block_bytes(transform, body), dtype=np.uint8))
        self._fdz_n[c] += len(values)
        self._fdz_blocks[c] += 1
