"""``SpectralDataset`` — root ``.mpgo`` reader / writer façade.

This class is the main public entry point. It owns the underlying
``h5py.File`` handle, provides mapping-style access to runs, and exposes the
feature-flag / identifications / quantifications / provenance metadata.

Only reading and minimal writing are implemented in M16. Full writing
support (feature flags, compound datasets, signal channels for new runs)
uses the same helpers in :mod:`_hdf5_io` and is fleshed out alongside the
mzML/nmrML importers in M16.7.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from types import TracebackType
from typing import Iterator, Mapping

import h5py
import numpy as np

from . import _hdf5_io as io
from .acquisition_run import AcquisitionRun
from .feature_flags import FeatureFlags
from .identification import Identification
from .provenance import ProvenanceRecord
from .quantification import Quantification


def _split_run_names(value: str | None) -> tuple[str, ...]:
    if not value:
        return ()
    return tuple(name for name in value.split(",") if name)


@dataclass(slots=True)
class SpectralDataset:
    """A read view over a ``.mpgo`` file.

    Use :meth:`SpectralDataset.open` as the main entry point; it returns an
    object that can be used as a context manager.
    """

    path: Path
    file: h5py.File
    feature_flags: FeatureFlags
    title: str
    isa_investigation_id: str
    ms_runs: dict[str, AcquisitionRun] = field(default_factory=dict)
    nmr_runs: dict[str, AcquisitionRun] = field(default_factory=dict)
    encrypted_algorithm: str = ""
    _closed: bool = False

    # ------------------------------------------------------------- lifecycle

    @classmethod
    def open(cls, path: str | Path) -> "SpectralDataset":
        p = Path(path)
        f = h5py.File(p, "r")
        try:
            return cls._from_open_file(p, f)
        except Exception:
            f.close()
            raise

    @classmethod
    def _from_open_file(cls, path: Path, f: h5py.File) -> "SpectralDataset":
        version, features = io.read_feature_flags(f)
        flags = FeatureFlags.from_iterable(version, features)
        encrypted = io.read_string_attr(f, "encrypted", default="") or ""

        if "study" not in f:
            raise ValueError(f"{path}: missing /study group; not a v0.2+ .mpgo file")
        study = f["study"]

        title = io.read_string_attr(study, "title", default="") or ""
        isa = io.read_string_attr(study, "isa_investigation_id", default="") or ""

        ms_runs: dict[str, AcquisitionRun] = {}
        if "ms_runs" in study:
            ms_group = study["ms_runs"]
            names = _split_run_names(io.read_string_attr(ms_group, "_run_names", default=""))
            for name in names:
                if name in ms_group:
                    ms_runs[name] = AcquisitionRun.open(ms_group[name], name)

        nmr_runs: dict[str, AcquisitionRun] = {}
        if "nmr_runs" in study:
            nmr_group = study["nmr_runs"]
            names = _split_run_names(io.read_string_attr(nmr_group, "_run_names", default=""))
            for name in names:
                if name in nmr_group:
                    nmr_runs[name] = AcquisitionRun.open(nmr_group[name], name)

        return cls(
            path=path,
            file=f,
            feature_flags=flags,
            title=title,
            isa_investigation_id=isa,
            ms_runs=ms_runs,
            nmr_runs=nmr_runs,
            encrypted_algorithm=encrypted,
        )

    def close(self) -> None:
        if not self._closed:
            self.file.close()
            self._closed = True

    def __enter__(self) -> "SpectralDataset":
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        self.close()

    def __del__(self) -> None:
        try:
            self.close()
        except Exception:
            pass

    # --------------------------------------------------------------- queries

    @property
    def is_encrypted(self) -> bool:
        return bool(self.encrypted_algorithm)

    @property
    def all_runs(self) -> Mapping[str, AcquisitionRun]:
        """Union of MS and NMR runs, keyed by run name."""
        merged: dict[str, AcquisitionRun] = dict(self.ms_runs)
        for k, v in self.nmr_runs.items():
            merged.setdefault(k, v)
        return merged

    def identifications(self) -> list[Identification]:
        study = self.file["study"]
        if "identifications" in study:
            return [
                Identification(
                    run_name=r["run_name"],
                    spectrum_index=int(r["spectrum_index"]),
                    chemical_entity=r["chemical_entity"],
                    confidence_score=float(r["confidence_score"]),
                    evidence_chain=_maybe_json_list(r.get("evidence_chain_json", "[]")),
                )
                for r in io.read_compound_dataset(study, "identifications")
            ]
        blob = io.read_string_attr(study, "identifications_json", default="")
        return _decode_identifications_json(blob) if blob else []

    def quantifications(self) -> list[Quantification]:
        study = self.file["study"]
        if "quantifications" in study:
            return [
                Quantification(
                    chemical_entity=r["chemical_entity"],
                    sample_ref=r["sample_ref"],
                    abundance=float(r["abundance"]),
                    normalization_method=r.get("normalization_method", ""),
                )
                for r in io.read_compound_dataset(study, "quantifications")
            ]
        blob = io.read_string_attr(study, "quantifications_json", default="")
        return _decode_quantifications_json(blob) if blob else []

    def provenance(self) -> list[ProvenanceRecord]:
        study = self.file["study"]
        if "provenance" in study:
            out: list[ProvenanceRecord] = []
            for r in io.read_compound_dataset(study, "provenance"):
                out.append(
                    ProvenanceRecord(
                        timestamp_unix=int(r["timestamp_unix"]),
                        software=r["software"],
                        parameters=_maybe_json_dict(r.get("parameters_json", "{}")),
                        input_refs=_maybe_json_list(r.get("input_refs_json", "[]")),
                        output_refs=_maybe_json_list(r.get("output_refs_json", "[]")),
                    )
                )
            return out
        blob = io.read_string_attr(study, "provenance_json", default="")
        return _decode_provenance_json(blob) if blob else []

    # ---------------------------------------------------------------- writer

    @classmethod
    def write_minimal(
        cls,
        path: str | Path,
        *,
        title: str,
        isa_investigation_id: str,
        runs: Mapping[str, "WrittenRun"],
        identifications: list[Identification] | None = None,
        quantifications: list[Quantification] | None = None,
        provenance: list[ProvenanceRecord] | None = None,
        features: list[str] | None = None,
    ) -> Path:
        """Write a minimal v1.1 ``.mpgo`` file from in-memory data.

        This is the simplest write path — enough to round-trip through the
        Python reader and to feed the ``mpgo-verify`` ObjC CLI in M16.9.
        """
        p = Path(path)
        feature_list = features or [
            "base_v1",
            "compound_identifications",
            "compound_quantifications",
            "compound_provenance",
            "opt_compound_headers",
        ]
        with h5py.File(p, "w") as f:
            io.write_feature_flags(f, "1.1", feature_list)
            study = f.create_group("study")
            io.write_fixed_string_attr(study, "title", title)
            io.write_fixed_string_attr(study, "isa_investigation_id", isa_investigation_id)

            ms_group = study.create_group("ms_runs")
            io.write_fixed_string_attr(ms_group, "_run_names", ",".join(runs.keys()))
            for rname, run in runs.items():
                _write_run(ms_group, rname, run)

            nmr_group = study.create_group("nmr_runs")
            io.write_fixed_string_attr(nmr_group, "_run_names", "")

            if identifications:
                _write_identifications(study, identifications)
            if quantifications:
                _write_quantifications(study, quantifications)
            if provenance:
                _write_provenance(study, provenance)
        return p


# ------------------------------------------------------------ writer helpers

@dataclass(slots=True)
class WrittenRun:
    """Simple container passed to :meth:`SpectralDataset.write_minimal`."""

    spectrum_class: str  # "MPGOMassSpectrum" or "MPGONMRSpectrum"
    acquisition_mode: int
    channel_data: dict[str, np.ndarray]  # concatenated signal buffers
    offsets: np.ndarray
    lengths: np.ndarray
    retention_times: np.ndarray
    ms_levels: np.ndarray
    polarities: np.ndarray
    precursor_mzs: np.ndarray
    precursor_charges: np.ndarray
    base_peak_intensities: np.ndarray
    nucleus_type: str = ""


def _write_run(parent: h5py.Group, name: str, run: WrittenRun) -> None:
    g = parent.create_group(name)
    io.write_int_attr(g, "acquisition_mode", run.acquisition_mode)
    io.write_int_attr(g, "spectrum_count", int(run.offsets.shape[0]))
    io.write_fixed_string_attr(g, "spectrum_class", run.spectrum_class)
    if run.nucleus_type:
        io.write_fixed_string_attr(g, "nucleus_type", run.nucleus_type)

    cfg = g.create_group("instrument_config")
    for field_name in ("manufacturer", "model", "serial_number",
                       "source_type", "analyzer_type", "detector_type"):
        io.write_fixed_string_attr(cfg, field_name, "")

    idx = g.create_group("spectrum_index")
    io.write_int_attr(idx, "count", int(run.offsets.shape[0]))
    for dname, data, dtype in [
        ("offsets", run.offsets, "<u8"),
        ("lengths", run.lengths, "<u4"),
        ("retention_times", run.retention_times, "<f8"),
        ("ms_levels", run.ms_levels, "<i4"),
        ("polarities", run.polarities, "<i4"),
        ("precursor_mzs", run.precursor_mzs, "<f8"),
        ("precursor_charges", run.precursor_charges, "<i4"),
        ("base_peak_intensities", run.base_peak_intensities, "<f8"),
    ]:
        io.write_signal_channel(idx, dname, data.astype(dtype, copy=False),
                                chunk_size=io.DEFAULT_INDEX_CHUNK)

    sig = g.create_group("signal_channels")
    io.write_fixed_string_attr(sig, "channel_names", ",".join(run.channel_data.keys()))
    for cname, buffer in run.channel_data.items():
        io.write_signal_channel(sig, f"{cname}_values",
                                buffer.astype("<f8", copy=False))


def _write_identifications(study: h5py.Group, records: list[Identification]) -> None:
    fields = [
        ("run_name", io.vl_str()),
        ("spectrum_index", "<u4"),
        ("chemical_entity", io.vl_str()),
        ("confidence_score", "<f8"),
        ("evidence_chain_json", io.vl_str()),
    ]
    io.write_compound_dataset(study, "identifications", [
        {
            "run_name": r.run_name,
            "spectrum_index": int(r.spectrum_index),
            "chemical_entity": r.chemical_entity,
            "confidence_score": float(r.confidence_score),
            "evidence_chain_json": json.dumps(r.evidence_chain),
        } for r in records
    ], fields)


def _write_quantifications(study: h5py.Group, records: list[Quantification]) -> None:
    fields = [
        ("chemical_entity", io.vl_str()),
        ("sample_ref", io.vl_str()),
        ("abundance", "<f8"),
        ("normalization_method", io.vl_str()),
    ]
    io.write_compound_dataset(study, "quantifications", [
        {
            "chemical_entity": r.chemical_entity,
            "sample_ref": r.sample_ref,
            "abundance": float(r.abundance),
            "normalization_method": r.normalization_method,
        } for r in records
    ], fields)


def _write_provenance(study: h5py.Group, records: list[ProvenanceRecord]) -> None:
    fields = [
        ("timestamp_unix", "<i8"),
        ("software", io.vl_str()),
        ("parameters_json", io.vl_str()),
        ("input_refs_json", io.vl_str()),
        ("output_refs_json", io.vl_str()),
    ]
    io.write_compound_dataset(study, "provenance", [
        {
            "timestamp_unix": int(r.timestamp_unix),
            "software": r.software,
            "parameters_json": json.dumps(r.parameters),
            "input_refs_json": json.dumps(r.input_refs),
            "output_refs_json": json.dumps(r.output_refs),
        } for r in records
    ], fields)


# --------------------------------------------------------- JSON fallback ---


def _maybe_json_list(value: str) -> list[str]:
    try:
        parsed = json.loads(value) if value else []
    except json.JSONDecodeError:
        return []
    if isinstance(parsed, list):
        return [str(x) for x in parsed]
    return []


def _maybe_json_dict(value: str) -> dict[str, object]:
    try:
        parsed = json.loads(value) if value else {}
    except json.JSONDecodeError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _decode_identifications_json(blob: str) -> list[Identification]:
    try:
        data = json.loads(blob)
    except json.JSONDecodeError:
        return []
    out: list[Identification] = []
    for r in data if isinstance(data, list) else []:
        out.append(Identification(
            run_name=str(r.get("run_name", "")),
            spectrum_index=int(r.get("spectrum_index", 0)),
            chemical_entity=str(r.get("chemical_entity", "")),
            confidence_score=float(r.get("confidence_score", 0.0)),
            evidence_chain=[str(x) for x in r.get("evidence_chain", [])],
        ))
    return out


def _decode_quantifications_json(blob: str) -> list[Quantification]:
    try:
        data = json.loads(blob)
    except json.JSONDecodeError:
        return []
    out: list[Quantification] = []
    for r in data if isinstance(data, list) else []:
        out.append(Quantification(
            chemical_entity=str(r.get("chemical_entity", "")),
            sample_ref=str(r.get("sample_ref", "")),
            abundance=float(r.get("abundance", 0.0)),
            normalization_method=str(r.get("normalization_method", "")),
        ))
    return out


def _decode_provenance_json(blob: str) -> list[ProvenanceRecord]:
    try:
        data = json.loads(blob)
    except json.JSONDecodeError:
        return []
    out: list[ProvenanceRecord] = []
    items = data if isinstance(data, list) else []
    for r in items:
        out.append(ProvenanceRecord(
            timestamp_unix=int(r.get("timestamp_unix", 0)),
            software=str(r.get("software", "")),
            parameters=r.get("parameters", {}) if isinstance(r.get("parameters"), dict) else {},
            input_refs=[str(x) for x in r.get("input_refs", [])],
            output_refs=[str(x) for x in r.get("output_refs", [])],
        ))
    return out
