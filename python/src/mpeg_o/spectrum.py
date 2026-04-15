"""``Spectrum`` — generic multi-channel spectrum base class."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Mapping

import numpy as np

from .enums import Polarity
from .signal_array import SignalArray


@dataclass(slots=True)
class Spectrum:
    """A multi-channel 1-D spectrum with per-scan metadata.

    ``channels`` maps a short channel name (``"mz"``, ``"intensity"``,
    ``"chemical_shift"``, ...) to its ``SignalArray``. Subclasses such as
    :class:`MassSpectrum` expose convenience properties for the standard
    channel names but do not constrain what may be stored.
    """

    channels: dict[str, SignalArray] = field(default_factory=dict)
    retention_time: float = 0.0
    ms_level: int = 0
    polarity: Polarity = Polarity.UNKNOWN
    precursor_mz: float = 0.0
    precursor_charge: int = 0
    base_peak_intensity: float = 0.0
    index: int = 0
    run_name: str = ""

    def channel(self, name: str) -> SignalArray:
        try:
            return self.channels[name]
        except KeyError as exc:
            raise KeyError(f"no such channel {name!r}; have {sorted(self.channels)}") from exc

    def has_channel(self, name: str) -> bool:
        return name in self.channels

    def channel_names(self) -> list[str]:
        return list(self.channels.keys())

    def __len__(self) -> int:
        if not self.channels:
            return 0
        return min(len(c) for c in self.channels.values())
