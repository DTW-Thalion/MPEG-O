"""``NMR2DSpectrum`` — rank-2 NMR spectrum with two axis descriptors."""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from .axis_descriptor import AxisDescriptor
from .spectrum import Spectrum


@dataclass(slots=True)
class NMR2DSpectrum(Spectrum):
    """2-D NMR spectrum: rank-2 intensity matrix with F1 and F2 axes.

    Subclass of :class:`Spectrum`. The matrix is stored as a rank-2
    ``numpy.ndarray`` of shape ``(height, width)``.

    Parameters
    ----------
    intensity_matrix : numpy.ndarray
        Rank-2 intensity matrix; shape ``(height, width)``.
    f1_axis : AxisDescriptor or None, default None
        F1 axis descriptor.
    f2_axis : AxisDescriptor or None, default None
        F2 axis descriptor.
    nucleus_f1 : str, default ""
        Nucleus type on F1 (``"1H"``, ``"13C"``, ...).
    nucleus_f2 : str, default ""
        Nucleus type on F2.
    *plus all base :class:`Spectrum` parameters*

    Notes
    -----
    API status: Stable.

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIONMR2DSpectrum`` · Java:
    ``global.thalion.ttio.NMR2DSpectrum``.
    """

    intensity_matrix: np.ndarray = field(default_factory=lambda: np.zeros((0, 0)))
    f1_axis: AxisDescriptor | None = None
    f2_axis: AxisDescriptor | None = None
    nucleus_f1: str = ""
    nucleus_f2: str = ""

    def __post_init__(self) -> None:
        if self.intensity_matrix.ndim != 2:
            raise ValueError(
                f"intensity_matrix must be rank-2, got shape={self.intensity_matrix.shape}"
            )

    @property
    def matrix_height(self) -> int:
        return int(self.intensity_matrix.shape[0])

    @property
    def matrix_width(self) -> int:
        return int(self.intensity_matrix.shape[1])
