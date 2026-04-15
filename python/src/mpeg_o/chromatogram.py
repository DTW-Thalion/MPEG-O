"""``Chromatogram`` — retention-time-indexed intensity trace."""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .enums import ChromatogramType


@dataclass(slots=True)
class Chromatogram:
    """A chromatogram trace: parallel retention-time and intensity arrays.

    Used for TIC, XIC, and SRM outputs. Matches the ObjC
    ``MPGOChromatogram`` value class.
    """

    retention_times: np.ndarray
    intensities: np.ndarray
    chromatogram_type: ChromatogramType = ChromatogramType.TIC
    name: str = ""

    def __post_init__(self) -> None:
        if self.retention_times.shape != self.intensities.shape:
            raise ValueError(
                f"retention_times {self.retention_times.shape} and "
                f"intensities {self.intensities.shape} must match"
            )

    def __len__(self) -> int:
        return int(self.retention_times.shape[0])
