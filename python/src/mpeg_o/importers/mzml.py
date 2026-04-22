"""mzML reader — Python port of ``MPGOMzMLReader``.

Uses ``xml.etree.ElementTree.iterparse`` for streaming. The namespace is
stripped on the fly (mzML files declare ``xmlns="http://psi.hupo.org/ms/mzml"``)
so element names match the ObjC parser exactly. Only the subset of fields
exercised by the reference fixtures is preserved; unused cvParams are
ignored rather than forwarded, matching the ObjC reader's behaviour.

Cross-language equivalents
--------------------------
Objective-C: ``MPGOMzMLReader`` · Java:
``com.dtwthalion.mpgo.importers.MzMLReader``

API status: Stable.
"""
from __future__ import annotations

from pathlib import Path
from typing import Any
from xml.etree.ElementTree import iterparse

import numpy as np

from ..enums import ActivationMethod, Polarity, Precision
from . import cv_term_mapper as cv
from ._base64_zlib import decode as decode_base64
from .import_result import ImportResult, ImportedChromatogram, ImportedSpectrum


class MzMLParseError(ValueError):
    """Raised when an mzML document cannot be decoded into an ImportResult."""


_PRECISION_NUMPY = {
    Precision.FLOAT32: "<f4",
    Precision.FLOAT64: "<f8",
    Precision.INT32: "<i4",
    Precision.INT64: "<i8",
}


def read(path: str | Path) -> ImportResult:
    """Parse an mzML file and return an :class:`ImportResult`.

    Supports the indexed (``<indexedmzML>``) and non-indexed wrappers. Only
    spectrum-level binary arrays are materialized; chromatograms are
    ignored in this minimal port (they will be added by M19).
    """
    path = Path(path)
    state = _State(source_file=str(path))

    for event, elem in iterparse(str(path), events=("start", "end")):
        tag = _local(elem.tag)
        if event == "start":
            _handle_start(state, tag, elem)
        else:
            _handle_end(state, tag, elem)
            elem.clear()

    if not state.spectra and not state.chromatograms:
        raise MzMLParseError(f"{path}: no usable spectra or chromatograms parsed")

    return ImportResult(
        title=state.run_id or "mzml_import",
        isa_investigation_id="",
        ms_spectra=state.spectra,
        chromatograms=state.chromatograms,
        source_file=str(path),
    )


# --------------------------------------------------------- parser state ---


class _State:
    __slots__ = (
        "source_file", "run_id", "spectra", "chromatograms",
        "in_spectrum", "spec_index", "spec_default_len",
        "ms_level", "polarity", "scan_time",
        "precursor_mz", "precursor_charge",
        "in_bin_array", "bin_precision", "bin_compressed", "bin_array_name",
        "bin_text",
        "spec_arrays",
        "in_precursor", "in_selected_ion", "in_scan", "in_scan_window",
        "in_activation", "in_isolation_window",
        "activation_method",
        "isolation_target_mz", "isolation_lower_offset", "isolation_upper_offset",
        "any_activation_detail",
        "in_chromatogram", "chrom_type", "chrom_target_mz",
        "chrom_precursor_mz", "chrom_product_mz",
    )

    def __init__(self, source_file: str) -> None:
        self.source_file = source_file
        self.run_id = ""
        self.spectra: list[ImportedSpectrum] = []
        self.chromatograms: list[ImportedChromatogram] = []
        self.in_spectrum = False
        self.spec_index = 0
        self.spec_default_len = 0
        self.ms_level = 1
        self.polarity = Polarity.UNKNOWN
        self.scan_time = 0.0
        self.precursor_mz = 0.0
        self.precursor_charge = 0
        self.in_bin_array = False
        self.bin_precision = Precision.FLOAT64
        self.bin_compressed = False
        self.bin_array_name: str | None = None
        self.bin_text: list[str] = []
        self.spec_arrays: dict[str, np.ndarray] = {}
        self.in_precursor = 0
        self.in_selected_ion = 0
        self.in_scan = 0
        self.in_scan_window = 0
        # M74: activation + isolation-window containers
        self.in_activation = 0
        self.in_isolation_window = 0
        self.activation_method = ActivationMethod.NONE
        self.isolation_target_mz = 0.0
        self.isolation_lower_offset = 0.0
        self.isolation_upper_offset = 0.0
        # Document-level flag: at least one spectrum had non-default
        # activation or isolation data. Used by import_result to decide
        # whether to emit the optional spectrum_index columns.
        self.any_activation_detail = False
        self.in_chromatogram = False
        # M24
        self.chrom_type = 0
        self.chrom_target_mz = 0.0
        self.chrom_precursor_mz = 0.0
        self.chrom_product_mz = 0.0

    def reset_spectrum(self) -> None:
        self.in_spectrum = False
        self.spec_index = 0
        self.spec_default_len = 0
        self.ms_level = 1
        self.polarity = Polarity.UNKNOWN
        self.scan_time = 0.0
        self.precursor_mz = 0.0
        self.precursor_charge = 0
        self.activation_method = ActivationMethod.NONE
        self.isolation_target_mz = 0.0
        self.isolation_lower_offset = 0.0
        self.isolation_upper_offset = 0.0
        self.spec_arrays.clear()

    def reset_chromatogram(self) -> None:
        self.in_chromatogram = False
        self.chrom_type = 0
        self.chrom_target_mz = 0.0
        self.chrom_precursor_mz = 0.0
        self.chrom_product_mz = 0.0
        self.spec_arrays.clear()

    def reset_bin(self) -> None:
        self.in_bin_array = False
        self.bin_precision = Precision.FLOAT64
        self.bin_compressed = False
        self.bin_array_name = None
        self.bin_text.clear()


# --------------------------------------------------------------- helpers ---


def _local(tag: str) -> str:
    if "}" in tag:
        return tag.split("}", 1)[1]
    return tag


def _handle_start(state: _State, tag: str, elem: Any) -> None:
    attrs = elem.attrib
    if tag == "run":
        state.run_id = attrs.get("id", "run")
        return
    if tag == "spectrum":
        state.reset_spectrum()
        state.in_spectrum = True
        try:
            state.spec_index = int(attrs.get("index", "0"))
        except ValueError:
            state.spec_index = 0
        try:
            state.spec_default_len = int(attrs.get("defaultArrayLength", "0"))
        except ValueError:
            state.spec_default_len = 0
        return
    if tag == "chromatogram":
        state.reset_chromatogram()
        state.in_chromatogram = True
        try:
            state.spec_default_len = int(attrs.get("defaultArrayLength", "0"))
        except ValueError:
            state.spec_default_len = 0
        return
    if tag == "userParam" and state.in_chromatogram:
        name = attrs.get("name", "")
        value = attrs.get("value", "") or ""
        if name == "target m/z":
            state.chrom_target_mz = _to_float(value)
        elif name == "precursor m/z":
            state.chrom_precursor_mz = _to_float(value)
        elif name == "product m/z":
            state.chrom_product_mz = _to_float(value)
        return
    if tag == "binaryDataArray":
        state.reset_bin()
        state.in_bin_array = True
        return
    if tag == "binary":
        state.bin_text.clear()
        return
    if tag == "precursor":
        state.in_precursor += 1
        return
    if tag == "selectedIon":
        state.in_selected_ion += 1
        return
    if tag == "scan":
        state.in_scan += 1
        return
    if tag == "scanWindow":
        state.in_scan_window += 1
        return
    if tag == "activation":
        state.in_activation += 1
        return
    if tag == "isolationWindow":
        state.in_isolation_window += 1
        return
    if tag == "cvParam":
        _handle_cv_param(state, attrs)


def _handle_cv_param(state: _State, attrs: dict[str, str]) -> None:
    acc = attrs.get("accession")
    if not acc:
        return
    value = attrs.get("value", "") or ""

    # 1. inside binaryDataArray: precision / compression / role
    if state.in_bin_array:
        name = cv.signal_array_name(acc)
        if name is not None:
            state.bin_array_name = name
            return
        if acc in cv.PRECISION_ACCESSIONS:
            state.bin_precision = cv.precision_for(acc)
            return
        if acc in cv.COMPRESSION_ACCESSIONS:
            state.bin_compressed = acc == "MS:1000574"
            return
        return

    # 2. inside selectedIon: precursor m/z and charge
    if state.in_selected_ion and state.in_spectrum:
        if acc == cv.SELECTED_ION_MZ:
            state.precursor_mz = _to_float(value)
            return
        if acc == cv.CHARGE_STATE:
            state.precursor_charge = _to_int(value)
            return
        return

    # 2a. (M74) inside <precursor><activation>: dissociation method cvParams.
    # Gate on `in_precursor` so <product> siblings (SRM) are ignored.
    if state.in_activation and state.in_precursor and state.in_spectrum:
        method = cv.activation_method_for(acc)
        if method is not None:
            state.activation_method = method
            state.any_activation_detail = True
        return

    # 2b. (M74) inside <precursor><isolationWindow>: target m/z + offsets.
    # Gate on `in_precursor` so <product><isolationWindow> is ignored.
    if state.in_isolation_window and state.in_precursor and state.in_spectrum:
        if acc == cv.ISOLATION_TARGET_MZ:
            state.isolation_target_mz = _to_float(value)
            state.any_activation_detail = True
            return
        if acc == cv.ISOLATION_LOWER_OFFSET:
            state.isolation_lower_offset = _to_float(value)
            state.any_activation_detail = True
            return
        if acc == cv.ISOLATION_UPPER_OFFSET:
            state.isolation_upper_offset = _to_float(value)
            state.any_activation_detail = True
            return
        return

    # 3. inside scanWindow: lower/upper limits (currently unused)
    if state.in_scan_window and state.in_spectrum:
        return

    # 4. inside scan (not scanWindow): scan start time
    if state.in_scan and state.in_spectrum:
        if acc == cv.SCAN_START_TIME:
            t = _to_float(value)
            if attrs.get("unitAccession") == cv.MINUTES_UNIT:
                t *= 60.0
            state.scan_time = t
        return

    # 5. directly inside spectrum
    if state.in_spectrum and not state.in_chromatogram:
        if acc == cv.MS_LEVEL:
            state.ms_level = _to_int(value)
            return
        if acc == cv.POSITIVE_POLARITY:
            state.polarity = Polarity.POSITIVE
            return
        if acc == cv.NEGATIVE_POLARITY:
            state.polarity = Polarity.NEGATIVE
            return
        if acc == cv.SCAN_START_TIME:
            t = _to_float(value)
            if attrs.get("unitAccession") == cv.MINUTES_UNIT:
                t *= 60.0
            state.scan_time = t
            return

    # 6. directly inside chromatogram: type CV terms (M24)
    if state.in_chromatogram:
        if acc == "MS:1000235":       # TIC
            state.chrom_type = 0
            return
        if acc == "MS:1000627":       # XIC / selected ion current
            state.chrom_type = 1
            return
        if acc == "MS:1001473":       # SRM chromatogram
            state.chrom_type = 2
            return


def _handle_end(state: _State, tag: str, elem: Any) -> None:
    if tag == "binary":
        if state.in_bin_array:
            state.bin_text.append(elem.text or "")
        return
    if tag == "binaryDataArray":
        _finish_bin_array(state)
        return
    if tag == "spectrum":
        _finish_spectrum(state)
        return
    if tag == "chromatogram":
        _finish_chromatogram(state)
        return
    if tag == "precursor":
        state.in_precursor -= 1
        return
    if tag == "selectedIon":
        state.in_selected_ion -= 1
        return
    if tag == "scan":
        state.in_scan -= 1
        return
    if tag == "scanWindow":
        state.in_scan_window -= 1
        return
    if tag == "activation":
        state.in_activation -= 1
        return
    if tag == "isolationWindow":
        state.in_isolation_window -= 1
        return


def _finish_bin_array(state: _State) -> None:
    state.in_bin_array = False
    if not state.bin_array_name:
        state.reset_bin()
        return
    raw = decode_base64("".join(state.bin_text), zlib_compressed=state.bin_compressed)
    dtype_str = _PRECISION_NUMPY.get(state.bin_precision, "<f8")
    arr = np.frombuffer(raw, dtype=dtype_str).astype(np.float64, copy=True)
    expected = state.spec_default_len
    if expected and arr.shape[0] != expected:
        raise MzMLParseError(
            f"spectrum index {state.spec_index}: array {state.bin_array_name!r} "
            f"length {arr.shape[0]} != defaultArrayLength {expected}"
        )
    state.spec_arrays[state.bin_array_name] = arr
    state.bin_text.clear()
    state.bin_array_name = None


def _finish_spectrum(state: _State) -> None:
    if not state.in_spectrum:
        return
    mz = state.spec_arrays.get("mz")
    it = state.spec_arrays.get("intensity")
    if mz is not None and it is not None and mz.shape == it.shape:
        state.spectra.append(ImportedSpectrum(
            mz_or_chemical_shift=mz,
            intensity=it,
            retention_time=state.scan_time,
            ms_level=state.ms_level,
            polarity=int(state.polarity),
            precursor_mz=state.precursor_mz,
            precursor_charge=state.precursor_charge,
            activation_method=int(state.activation_method),
            isolation_target_mz=state.isolation_target_mz,
            isolation_lower_offset=state.isolation_lower_offset,
            isolation_upper_offset=state.isolation_upper_offset,
        ))
    state.reset_spectrum()


def _finish_chromatogram(state: _State) -> None:
    if not state.in_chromatogram:
        return
    t = state.spec_arrays.get("time")
    i = state.spec_arrays.get("intensity")
    if t is not None and i is not None and t.shape == i.shape:
        state.chromatograms.append(ImportedChromatogram(
            retention_times=t,
            intensities=i,
            chromatogram_type=state.chrom_type,
            target_mz=state.chrom_target_mz,
            precursor_mz=state.chrom_precursor_mz,
            product_mz=state.chrom_product_mz,
        ))
    state.reset_chromatogram()


def _to_float(value: str) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def _to_int(value: str) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0
