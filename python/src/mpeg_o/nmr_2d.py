"""``NMR2DSpectrum`` — native rank-2 NMR spectrum with dimension scales."""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np


@dataclass(slots=True)
class NMR2DSpectrum:
    """A 2-D NMR spectrum stored as a rank-2 intensity matrix with two
    1-D chemical-shift scales (``f1_scale``, ``f2_scale``).

    Mirrors the ObjC ``MPGONMR2DSpectrum`` class. The v0.2 on-disk layout is
    described in §8 of ``docs/format-spec.md``.
    """

    intensity_matrix: np.ndarray
    f1_scale: np.ndarray
    f2_scale: np.ndarray
    nucleus_f1: str = ""
    nucleus_f2: str = ""
    index: int = 0
    run_name: str = ""

    def __post_init__(self) -> None:
        if self.intensity_matrix.ndim != 2:
            raise ValueError(
                f"intensity_matrix must be rank-2, got shape={self.intensity_matrix.shape}"
            )
        h, w = self.intensity_matrix.shape
        if self.f1_scale.shape != (h,):
            raise ValueError(
                f"f1_scale shape {self.f1_scale.shape} does not match height {h}"
            )
        if self.f2_scale.shape != (w,):
            raise ValueError(
                f"f2_scale shape {self.f2_scale.shape} does not match width {w}"
            )

    @property
    def matrix_height(self) -> int:
        return int(self.intensity_matrix.shape[0])

    @property
    def matrix_width(self) -> int:
        return int(self.intensity_matrix.shape[1])
