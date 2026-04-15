"""``FreeInductionDecay`` — time-domain NMR signal."""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np


@dataclass(slots=True)
class FreeInductionDecay:
    """A time-domain NMR free-induction-decay signal.

    The data array is typically real-valued (one channel) or complex-valued
    (quadrature detection). ``dwell_time_s`` is the sample spacing in seconds.
    """

    data: np.ndarray
    dwell_time_s: float
    spectrometer_frequency_mhz: float = 0.0
    nucleus: str = ""

    def __len__(self) -> int:
        return int(self.data.shape[0])
