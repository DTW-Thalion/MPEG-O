"""``InstrumentConfig`` — human-readable acquisition instrument description."""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class InstrumentConfig:
    """Instrument configuration block persisted as HDF5 string attributes.

    All fields default to empty strings because the format spec
    explicitly allows every sub-field to be missing (§3 of
    ``docs/format-spec.md``).

    Parameters
    ----------
    manufacturer : str, default ""
        Instrument manufacturer (e.g. ``"Thermo Fisher Scientific"``).
    model : str, default ""
        Instrument model (e.g. ``"Orbitrap Eclipse"``).
    serial_number : str, default ""
        Serial number.
    source_type : str, default ""
        Ionization source (e.g. ``"ESI"``, ``"MALDI"``).
    analyzer_type : str, default ""
        Mass analyzer (e.g. ``"Orbitrap"``, ``"TOF"``).
    detector_type : str, default ""
        Detector (e.g. ``"inductive"``, ``"electron multiplier"``).

    Notes
    -----
    API status: Stable.

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIOInstrumentConfig`` · Java:
    ``com.dtwthalion.ttio.InstrumentConfig``.
    """

    manufacturer: str = ""
    model: str = ""
    serial_number: str = ""
    source_type: str = ""
    analyzer_type: str = ""
    detector_type: str = ""
