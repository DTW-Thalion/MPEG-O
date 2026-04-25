"""2D-COS compute primitives — Noda's synchronous/asynchronous decomposition.

Given a perturbation series ``A`` of shape ``(m, n)``:

- ``m`` = number of perturbation points (time, temperature, concentration...)
- ``n`` = number of spectral variables (shared axis)

The dynamic spectra ``Ã = A - reference`` (reference defaults to the
column-wise mean) are decomposed into:

- Synchronous matrix ``Φ = (1 / (m - 1)) · Ãᵀ · Ã``, symmetric.
- Asynchronous matrix ``Ψ = (1 / (m - 1)) · Ãᵀ · N · Ã``, antisymmetric,
  where ``N`` is the discrete Hilbert-Noda transform matrix of size
  ``(m, m)``.

``N[j, k] = 0`` when ``j == k`` else ``1 / (π · (k - j))``.

The disrelation-like significance spectrum ``|Φ| / (|Φ| + |Ψ|)`` is
bounded in ``[0, 1]`` (cells where both matrices vanish return ``NaN``).

Cross-language equivalents: Java
``global.thalion.ttio.analysis.TwoDCos`` · Objective-C
``TTIOTwoDCos``.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

from typing import TYPE_CHECKING

import numpy as np

from ..two_dimensional_correlation_spectrum import TwoDimensionalCorrelationSpectrum

if TYPE_CHECKING:
    from ..axis_descriptor import AxisDescriptor

__all__ = [
    "hilbert_noda_matrix",
    "compute",
    "disrelation_spectrum",
]


def hilbert_noda_matrix(m: int) -> np.ndarray:
    """Return the discrete Hilbert-Noda transform matrix of size ``(m, m)``.

    Entry ``(j, k)`` is ``0`` on the diagonal and ``1 / (π · (k - j))``
    off-diagonal. The matrix is antisymmetric, so
    ``hilbert_noda_matrix(m).T == -hilbert_noda_matrix(m)``.
    """
    if m < 1:
        raise ValueError(f"m must be >= 1, got {m}")
    n = np.zeros((m, m), dtype=np.float64)
    if m == 1:
        return n
    idx = np.arange(m)
    # k - j as a 2D grid: rows indexed by j, cols by k.
    diff = idx[np.newaxis, :] - idx[:, np.newaxis]
    with np.errstate(divide="ignore"):
        n = np.where(diff == 0, 0.0, 1.0 / (np.pi * diff))
    return n


def compute(
    dynamic_spectra: np.ndarray,
    *,
    reference: np.ndarray | None = None,
    variable_axis: "AxisDescriptor | None" = None,
    perturbation: str = "",
    perturbation_unit: str = "",
    source_modality: str = "",
) -> TwoDimensionalCorrelationSpectrum:
    """Compute synchronous + asynchronous correlation matrices via Noda 2D-COS.

    Parameters
    ----------
    dynamic_spectra
        Perturbation-series matrix ``A`` of shape ``(m, n)``. Each row
        is one spectrum sampled at the same ``n`` spectral variables.
    reference
        Reference spectrum to subtract, shape ``(n,)``. Defaults to the
        column-wise mean of ``dynamic_spectra`` (standard mean-centered
        2D-COS). Pass an explicit baseline to compute difference 2D-COS.
    variable_axis, perturbation, perturbation_unit, source_modality
        Forwarded to the returned
        :class:`~ttio.TwoDimensionalCorrelationSpectrum`.

    Returns
    -------
    TwoDimensionalCorrelationSpectrum
        Wrapping the ``(n, n)`` synchronous and asynchronous matrices.
    """
    a = np.asarray(dynamic_spectra, dtype=np.float64)
    if a.ndim != 2:
        raise ValueError(
            f"dynamic_spectra must be rank-2, got shape={a.shape}"
        )
    m, n = a.shape
    if m < 2:
        raise ValueError(
            f"need >= 2 perturbation points for 2D-COS, got m={m}"
        )

    if reference is None:
        ref = a.mean(axis=0)
    else:
        ref = np.asarray(reference, dtype=np.float64)
        if ref.shape != (n,):
            raise ValueError(
                f"reference shape must be ({n},), got {ref.shape}"
            )

    dyn = a - ref[np.newaxis, :]

    scale = 1.0 / (m - 1)
    sync = scale * (dyn.T @ dyn)

    nmat = hilbert_noda_matrix(m)
    asyn = scale * (dyn.T @ (nmat @ dyn))

    return TwoDimensionalCorrelationSpectrum(
        synchronous_matrix=sync,
        asynchronous_matrix=asyn,
        variable_axis=variable_axis,
        perturbation=perturbation,
        perturbation_unit=perturbation_unit,
        source_modality=source_modality,
    )


def disrelation_spectrum(
    synchronous: np.ndarray,
    asynchronous: np.ndarray,
) -> np.ndarray:
    """Return ``|Φ| / (|Φ| + |Ψ|)`` — synchronous dominance in ``[0, 1]``.

    Cells where both matrices vanish yield ``NaN`` (no information).
    High values (→ 1) indicate cross-peaks dominated by in-phase
    variation; low values (→ 0) indicate sequential variation.
    """
    s = np.asarray(synchronous, dtype=np.float64)
    a = np.asarray(asynchronous, dtype=np.float64)
    if s.shape != a.shape:
        raise ValueError(
            f"synchronous/asynchronous shape mismatch: {s.shape} vs {a.shape}"
        )
    num = np.abs(s)
    denom = num + np.abs(a)
    with np.errstate(invalid="ignore", divide="ignore"):
        return np.where(denom > 0.0, num / denom, np.nan)
