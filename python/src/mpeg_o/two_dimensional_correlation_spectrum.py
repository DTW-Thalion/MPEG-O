"""``TwoDimensionalCorrelationSpectrum`` — 2D-COS synchronous/asynchronous pair."""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from .axis_descriptor import AxisDescriptor
from .spectrum import Spectrum


@dataclass(slots=True)
class TwoDimensionalCorrelationSpectrum(Spectrum):
    """2D correlation spectrum (Noda 2D-COS): synchronous + asynchronous matrices.

    A 2D-COS observation carries a pair of square rank-2 correlation
    matrices — synchronous (in-phase) and asynchronous
    (quadrature) — both keyed on the same spectral-variable axis
    (e.g. wavenumber ν₁ = ν₂). The diagonal of the synchronous matrix
    is the perturbation-modulated autocorrelation; off-diagonal
    cross-peaks report simultaneous changes. Off-diagonal asynchronous
    cross-peaks report sequential changes.

    Parameters
    ----------
    synchronous_matrix : numpy.ndarray
        Rank-2 synchronous correlation matrix, shape ``(n, n)``.
    asynchronous_matrix : numpy.ndarray
        Rank-2 asynchronous correlation matrix, shape ``(n, n)``.
    variable_axis : AxisDescriptor or None, default None
        Shared axis descriptor (applies to both F1 and F2).
    perturbation : str, default ""
        Free-form description of the driving perturbation
        (``"temperature"``, ``"concentration"``, ...).
    perturbation_unit : str, default ""
        Unit for the perturbation (e.g. ``"K"``, ``"mM"``).
    source_modality : str, default ""
        Originating spectroscopy (``"raman"``, ``"ir"``, ``"uv-vis"``, ...).
    *plus all base :class:`Spectrum` parameters*

    Notes
    -----
    API status: Stable (v0.11.1).

    Cross-language equivalents
    --------------------------
    Objective-C: ``MPGOTwoDimensionalCorrelationSpectrum`` · Java:
    ``com.dtwthalion.mpgo.TwoDimensionalCorrelationSpectrum``.
    """

    synchronous_matrix: np.ndarray = field(default_factory=lambda: np.zeros((0, 0)))
    asynchronous_matrix: np.ndarray = field(default_factory=lambda: np.zeros((0, 0)))
    variable_axis: AxisDescriptor | None = None
    perturbation: str = ""
    perturbation_unit: str = ""
    source_modality: str = ""

    def __post_init__(self) -> None:
        if self.synchronous_matrix.ndim != 2:
            raise ValueError(
                f"synchronous_matrix must be rank-2, got shape="
                f"{self.synchronous_matrix.shape}"
            )
        if self.asynchronous_matrix.ndim != 2:
            raise ValueError(
                f"asynchronous_matrix must be rank-2, got shape="
                f"{self.asynchronous_matrix.shape}"
            )
        if self.synchronous_matrix.shape != self.asynchronous_matrix.shape:
            raise ValueError(
                "synchronous/asynchronous matrices must share shape; got "
                f"{self.synchronous_matrix.shape} vs "
                f"{self.asynchronous_matrix.shape}"
            )
        h, w = self.synchronous_matrix.shape
        if h != w:
            raise ValueError(
                f"2D-COS matrices must be square; got {h}x{w}"
            )

    @property
    def matrix_size(self) -> int:
        """Return the length of the shared variable axis."""
        return int(self.synchronous_matrix.shape[0])
