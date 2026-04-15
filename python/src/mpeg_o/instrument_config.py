"""``InstrumentConfig`` — human-readable acquisition instrument description."""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class InstrumentConfig:
    """Instrument configuration block persisted as HDF5 string attributes.

    All fields default to empty strings because the format spec explicitly
    allows every sub-field to be missing (§3 of ``docs/format-spec.md``).
    """

    manufacturer: str = ""
    model: str = ""
    serial_number: str = ""
    source_type: str = ""
    analyzer_type: str = ""
    detector_type: str = ""
