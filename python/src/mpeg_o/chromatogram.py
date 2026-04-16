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

    M24: added ``target_mz`` (XIC), ``precursor_mz`` / ``product_mz`` (SRM
    transition) for round-trip compatibility with the HDF5 chromatogram
    index and the mzML writer/reader's cvParam mapping.
    """

    retention_times: np.ndarray
    intensities: np.ndarray
    chromatogram_type: ChromatogramType = ChromatogramType.TIC
    target_mz: float = 0.0
    precursor_mz: float = 0.0
    product_mz: float = 0.0
    name: str = ""

    def __post_init__(self) -> None:
        if self.retention_times.shape != self.intensities.shape:
            raise ValueError(
                f"retention_times {self.retention_times.shape} and "
                f"intensities {self.intensities.shape} must match"
            )

    def __len__(self) -> int:
        return int(self.retention_times.shape[0])

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Chromatogram):
            return NotImplemented
        return (
            self.chromatogram_type == other.chromatogram_type
            and self.target_mz == other.target_mz
            and self.precursor_mz == other.precursor_mz
            and self.product_mz == other.product_mz
            and np.array_equal(self.retention_times, other.retention_times)
            and np.array_equal(self.intensities, other.intensities)
        )

    def __hash__(self) -> int:  # pragma: no cover
        return hash((
            self.chromatogram_type,
            self.target_mz,
            self.precursor_mz,
            self.product_mz,
            self.retention_times.tobytes(),
            self.intensities.tobytes(),
        ))
