"""v0.11.1 parity: TwoDimensionalCorrelationSpectrum."""
from __future__ import annotations

import numpy as np
import pytest

from mpeg_o import AxisDescriptor, TwoDimensionalCorrelationSpectrum


def _sync_async_fixture(n: int = 16) -> tuple[np.ndarray, np.ndarray]:
    rng = np.random.default_rng(0)
    sync = rng.standard_normal((n, n))
    sync = 0.5 * (sync + sync.T)  # Noda synchronous ⇒ symmetric
    asyn = rng.standard_normal((n, n))
    asyn = 0.5 * (asyn - asyn.T)  # Noda asynchronous ⇒ antisymmetric
    return sync, asyn


def test_two_d_cos_constructs() -> None:
    sync, asyn = _sync_async_fixture(32)
    s = TwoDimensionalCorrelationSpectrum(
        synchronous_matrix=sync,
        asynchronous_matrix=asyn,
        variable_axis=AxisDescriptor("wavenumber", "1/cm"),
        perturbation="temperature",
        perturbation_unit="K",
        source_modality="ir",
    )
    assert s.matrix_size == 32
    assert s.perturbation == "temperature"
    assert s.perturbation_unit == "K"
    assert s.source_modality == "ir"
    assert s.variable_axis is not None
    assert s.variable_axis.unit == "1/cm"


def test_two_d_cos_rejects_non_rank2_sync() -> None:
    with pytest.raises(ValueError, match="synchronous_matrix must be rank-2"):
        TwoDimensionalCorrelationSpectrum(
            synchronous_matrix=np.zeros(10),
            asynchronous_matrix=np.zeros((10, 10)),
        )


def test_two_d_cos_rejects_non_rank2_async() -> None:
    with pytest.raises(ValueError, match="asynchronous_matrix must be rank-2"):
        TwoDimensionalCorrelationSpectrum(
            synchronous_matrix=np.zeros((10, 10)),
            asynchronous_matrix=np.zeros(10),
        )


def test_two_d_cos_rejects_shape_mismatch() -> None:
    with pytest.raises(ValueError, match="must share shape"):
        TwoDimensionalCorrelationSpectrum(
            synchronous_matrix=np.zeros((10, 10)),
            asynchronous_matrix=np.zeros((12, 12)),
        )


def test_two_d_cos_rejects_non_square() -> None:
    with pytest.raises(ValueError, match="must be square"):
        TwoDimensionalCorrelationSpectrum(
            synchronous_matrix=np.zeros((10, 16)),
            asynchronous_matrix=np.zeros((10, 16)),
        )


def test_two_d_cos_default_empty() -> None:
    s = TwoDimensionalCorrelationSpectrum()
    assert s.matrix_size == 0
    assert s.perturbation == ""
    assert s.source_modality == ""
