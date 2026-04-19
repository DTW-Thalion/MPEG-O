"""nmrML reader — Python port of ``MPGONmrMLReader``.

Handles ``spectrum1D`` files (1-D NMR). The acquisition parameter block
is recognised in both its cvParam and attribute-carrying forms. FID data
is parsed and discarded in this minimal port; it is reserved for a later
milestone that adds a ``FreeInductionDecay`` writer.

Cross-language equivalents
--------------------------
Objective-C: ``MPGONmrMLReader`` · Java:
``com.dtwthalion.mpgo.importers.NmrMLReader``

API status: Stable.
"""
from __future__ import annotations

from pathlib import Path
from typing import Any
from xml.etree.ElementTree import iterparse

import numpy as np

from . import cv_term_mapper as cv
from ._base64_zlib import decode as decode_base64
from .import_result import ImportResult, ImportedSpectrum


class NmrMLParseError(ValueError):
    pass


def read(path: str | Path) -> ImportResult:
    """Parse an nmrML file and return an :class:`ImportResult`."""
    path = Path(path)
    state = _State()

    for event, elem in iterparse(str(path), events=("start", "end")):
        tag = _local(elem.tag)
        if event == "start":
            _handle_start(state, tag, elem)
        else:
            _handle_end(state, tag, elem)
            elem.clear()

    # A file with only FID data and no processed spectrum1D is valid; the
    # caller can still inspect ``nucleus_type`` and the empty spectra list.
    return ImportResult(
        title="nmrml_import",
        isa_investigation_id="",
        nmr_spectra=state.spectra,
        nucleus_type=state.nucleus_type,
        source_file=str(path),
    )


# ------------------------------------------------------------------- state ---


class _State:
    __slots__ = (
        "spectra", "nucleus_type", "spectrometer_frequency_mhz",
        "dwell_time_seconds", "sweep_width_ppm", "number_of_scans",
        "in_acquisition_parameter_set",
        "in_spectrum1d", "in_x_axis", "in_y_axis",
        "in_spectrum_data_array", "current_array_compressed",
        "capturing_text", "text_buf",
        "current_x_axis", "current_y_axis", "current_index",
        "current_number_of_data_points",
    )

    def __init__(self) -> None:
        self.spectra: list[ImportedSpectrum] = []
        self.nucleus_type = ""
        self.spectrometer_frequency_mhz = 0.0
        self.dwell_time_seconds = 0.0
        self.sweep_width_ppm = 0.0
        self.number_of_scans = 0
        self.in_acquisition_parameter_set = False
        self.in_spectrum1d = False
        self.in_x_axis = False
        self.in_y_axis = False
        self.in_spectrum_data_array = False
        self.current_array_compressed = False
        self.capturing_text = False
        self.text_buf: list[str] = []
        self.current_x_axis: np.ndarray | None = None
        self.current_y_axis: np.ndarray | None = None
        self.current_index = 0
        self.current_number_of_data_points = 0


# ------------------------------------------------------------------ parsing ---


def _local(tag: str) -> str:
    if "}" in tag:
        return tag.split("}", 1)[1]
    return tag


_NUCLEUS_ALIASES = {
    "hydrogen": "1H",
    "proton": "1H",
    "carbon": "13C",
    "nitrogen": "15N",
    "phosphorus": "31P",
}


def _normalize_nucleus(name: str) -> str:
    low = name.lower()
    for key, canonical in _NUCLEUS_ALIASES.items():
        if key in low:
            return canonical
    return name


def _handle_start(state: _State, tag: str, elem: Any) -> None:
    attrs = elem.attrib
    if tag == "acquisitionParameterSet":
        state.in_acquisition_parameter_set = True
        ns = attrs.get("numberOfScans")
        if ns:
            try:
                state.number_of_scans = int(ns)
            except ValueError:
                pass
        return
    if state.in_acquisition_parameter_set:
        if tag == "acquisitionNucleus":
            name = attrs.get("name", "")
            if name:
                state.nucleus_type = _normalize_nucleus(name)
            return
        if tag == "irradiationFrequency":
            hz = _to_float(attrs.get("value", ""))
            if hz > 0:
                state.spectrometer_frequency_mhz = hz / 1.0e6
            return
        if tag == "sweepWidth":
            state.sweep_width_ppm = _to_float(attrs.get("value", ""))
            return
    if tag == "spectrum1D":
        state.in_spectrum1d = True
        state.current_x_axis = None
        state.current_y_axis = None
        try:
            state.current_number_of_data_points = int(
                attrs.get("numberOfDataPoints", "0") or "0"
            )
        except ValueError:
            state.current_number_of_data_points = 0
        return
    if tag == "xAxis":
        state.in_x_axis = True
        return
    if tag == "yAxis":
        state.in_y_axis = True
        return
    if tag == "spectrumDataArray":
        state.in_spectrum_data_array = True
        comp = attrs.get("compressed", "")
        state.current_array_compressed = comp in ("true", "zlib")
        state.capturing_text = True
        state.text_buf.clear()
        return
    if tag == "fidData":
        # Minimal port: accept and skip the content.
        state.capturing_text = True
        state.text_buf.clear()
        return
    if tag == "cvParam":
        _handle_cv_param(state, attrs)


def _handle_cv_param(state: _State, attrs: dict[str, str]) -> None:
    if not state.in_acquisition_parameter_set:
        return
    acc = attrs.get("accession")
    if not acc:
        return
    value = attrs.get("value", "")
    if acc == cv.NMR_SPECTROMETER_FREQUENCY:
        state.spectrometer_frequency_mhz = _to_float(value)
    elif acc == cv.NMR_NUCLEUS:
        state.nucleus_type = value or state.nucleus_type
    elif acc == cv.NMR_NUMBER_OF_SCANS:
        state.number_of_scans = _to_int(value)
    elif acc == cv.NMR_DWELL_TIME:
        state.dwell_time_seconds = _to_float(value)
    elif acc == cv.NMR_SWEEP_WIDTH:
        state.sweep_width_ppm = _to_float(value)


def _handle_end(state: _State, tag: str, elem: Any) -> None:
    if tag == "acquisitionParameterSet":
        state.in_acquisition_parameter_set = False
        return
    if tag == "spectrumDataArray":
        if state.capturing_text:
            state.text_buf.append(elem.text or "")
        raw = decode_base64("".join(state.text_buf), zlib_compressed=state.current_array_compressed)
        arr = np.frombuffer(raw, dtype="<f8").astype(np.float64, copy=True)
        if state.in_x_axis:
            # Legacy form: <xAxis><spectrumDataArray>x_values</></>
            state.current_x_axis = arr
        elif state.in_y_axis:
            # Legacy form: <yAxis><spectrumDataArray>y_values</></>
            state.current_y_axis = arr
        elif state.in_spectrum1d:
            # Canonical v0.9+ form: single <spectrumDataArray> directly
            # inside <spectrum1D>. Interleaved (x,y) pairs → deinterleave;
            # plain y-only (external nmrML) → generate x from 0..N-1.
            if arr.size > 0 and arr.size % 2 == 0 and arr.size >= 2:
                # Heuristic: if the array length matches 2 * N then
                # it's interleaved (x,y) pairs. We can't always tell
                # without numberOfDataPoints from the spectrum1D
                # attribute, but even-length is necessary for pairs.
                # When numberOfDataPoints is known, use it as the
                # definitive tie-breaker.
                n_attr = state.current_number_of_data_points
                if n_attr > 0 and arr.size == 2 * n_attr:
                    state.current_x_axis = arr[0::2].copy()
                    state.current_y_axis = arr[1::2].copy()
                elif n_attr > 0 and arr.size == n_attr:
                    state.current_y_axis = arr
                    state.current_x_axis = np.arange(n_attr, dtype=np.float64)
                else:
                    # Fall back: assume interleaved pairs when even.
                    state.current_x_axis = arr[0::2].copy()
                    state.current_y_axis = arr[1::2].copy()
            else:
                # Odd-length: must be y-only (external nmrML convention)
                state.current_y_axis = arr
                state.current_x_axis = np.arange(arr.size, dtype=np.float64)
        state.in_spectrum_data_array = False
        state.capturing_text = False
        state.text_buf.clear()
        return
    if tag == "xAxis":
        state.in_x_axis = False
        return
    if tag == "yAxis":
        state.in_y_axis = False
        return
    if tag == "spectrum1D":
        _finish_spectrum1d(state)
        state.in_spectrum1d = False
        return
    if tag == "fidData":
        state.capturing_text = False
        state.text_buf.clear()
        return


def _finish_spectrum1d(state: _State) -> None:
    x = state.current_x_axis
    y = state.current_y_axis
    if x is None or y is None or x.shape != y.shape:
        return
    state.spectra.append(ImportedSpectrum(
        mz_or_chemical_shift=x,
        intensity=y,
        retention_time=0.0,
        ms_level=0,
        polarity=0,
        precursor_mz=0.0,
        precursor_charge=0,
    ))
    state.current_index += 1
    state.current_x_axis = None
    state.current_y_axis = None


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
