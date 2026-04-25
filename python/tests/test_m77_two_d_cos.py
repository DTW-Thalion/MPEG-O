"""M77: 2D-COS compute primitives — shape/parity/symmetry/analytic cases."""
from __future__ import annotations

import numpy as np
import pytest

from ttio import AxisDescriptor, TwoDimensionalCorrelationSpectrum
from ttio.analysis import two_d_cos


def test_hilbert_noda_matrix_shape_and_antisymmetry() -> None:
    n = two_d_cos.hilbert_noda_matrix(8)
    assert n.shape == (8, 8)
    np.testing.assert_array_equal(np.diag(n), np.zeros(8))
    np.testing.assert_allclose(n.T, -n, atol=0.0)


def test_hilbert_noda_matrix_entries() -> None:
    n = two_d_cos.hilbert_noda_matrix(4)
    # N[j, k] = 1 / (pi * (k - j))
    assert n[0, 1] == pytest.approx(1.0 / np.pi)
    assert n[1, 0] == pytest.approx(-1.0 / np.pi)
    assert n[0, 3] == pytest.approx(1.0 / (3.0 * np.pi))


def test_hilbert_noda_matrix_m1_is_zero() -> None:
    n = two_d_cos.hilbert_noda_matrix(1)
    np.testing.assert_array_equal(n, np.zeros((1, 1)))


def test_hilbert_noda_matrix_rejects_m_zero() -> None:
    with pytest.raises(ValueError, match="m must be >= 1"):
        two_d_cos.hilbert_noda_matrix(0)


def test_compute_rejects_rank1() -> None:
    with pytest.raises(ValueError, match="rank-2"):
        two_d_cos.compute(np.zeros(10))


def test_compute_rejects_single_row() -> None:
    with pytest.raises(ValueError, match=">= 2 perturbation points"):
        two_d_cos.compute(np.zeros((1, 5)))


def test_compute_rejects_bad_reference_shape() -> None:
    with pytest.raises(ValueError, match="reference shape"):
        two_d_cos.compute(np.zeros((4, 5)), reference=np.zeros(7))


def test_compute_constant_perturbation_yields_zero_matrices() -> None:
    # Identical spectra at every perturbation point → dynamic spectra are
    # zero after mean-centering → both matrices must be zero.
    m, n = 6, 12
    a = np.tile(np.sin(np.linspace(0, np.pi, n)), (m, 1))
    spec = two_d_cos.compute(a)
    assert spec.matrix_size == n
    np.testing.assert_allclose(spec.synchronous_matrix, np.zeros((n, n)), atol=1e-20)
    np.testing.assert_allclose(spec.asynchronous_matrix, np.zeros((n, n)), atol=1e-20)


def test_compute_sync_is_symmetric_async_is_antisymmetric() -> None:
    rng = np.random.default_rng(42)
    a = rng.standard_normal((10, 8))
    spec = two_d_cos.compute(a)
    np.testing.assert_allclose(
        spec.synchronous_matrix, spec.synchronous_matrix.T, atol=1e-12
    )
    np.testing.assert_allclose(
        spec.asynchronous_matrix, -spec.asynchronous_matrix.T, atol=1e-12
    )


def test_compute_returns_container_with_metadata() -> None:
    rng = np.random.default_rng(0)
    a = rng.standard_normal((5, 4))
    spec = two_d_cos.compute(
        a,
        variable_axis=AxisDescriptor("wavenumber", "1/cm"),
        perturbation="temperature",
        perturbation_unit="K",
        source_modality="ir",
    )
    assert isinstance(spec, TwoDimensionalCorrelationSpectrum)
    assert spec.perturbation == "temperature"
    assert spec.perturbation_unit == "K"
    assert spec.source_modality == "ir"
    assert spec.variable_axis is not None
    assert spec.variable_axis.unit == "1/cm"


def test_compute_explicit_reference() -> None:
    # With an explicit reference equal to the column mean, result must
    # match default (mean-centered) 2D-COS.
    rng = np.random.default_rng(1)
    a = rng.standard_normal((7, 5))
    ref = a.mean(axis=0)
    default_spec = two_d_cos.compute(a)
    explicit_spec = two_d_cos.compute(a, reference=ref)
    np.testing.assert_allclose(
        default_spec.synchronous_matrix,
        explicit_spec.synchronous_matrix,
        atol=1e-12,
    )
    np.testing.assert_allclose(
        default_spec.asynchronous_matrix,
        explicit_spec.asynchronous_matrix,
        atol=1e-12,
    )


def test_compute_sine_perturbation_two_variables() -> None:
    # Two pure cosines 90° apart at different variables produce a known
    # 2×2 cross-peak pattern — synchronous diagonal positive, async
    # off-diagonal with opposite sign.
    m = 200
    t = np.linspace(0.0, 2.0 * np.pi, m, endpoint=False)
    a = np.column_stack([np.cos(t), np.cos(t - np.pi / 2.0)])
    spec = two_d_cos.compute(a)
    sync = spec.synchronous_matrix
    asyn = spec.asynchronous_matrix
    # Diagonal (autocorrelation) ≈ 1/2 for unit-amplitude cosine.
    assert sync[0, 0] > 0.0
    assert sync[1, 1] > 0.0
    # In-phase cross-peak between two orthogonal sinusoids ≈ 0.
    assert abs(sync[0, 1]) < 5e-2
    # Async cross-peak picks up the 90° phase offset — nonzero, antisymmetric.
    assert abs(asyn[0, 1]) > 1e-2
    np.testing.assert_allclose(asyn[1, 0], -asyn[0, 1], atol=1e-12)


def test_disrelation_spectrum_bounds() -> None:
    rng = np.random.default_rng(7)
    a = rng.standard_normal((12, 6))
    spec = two_d_cos.compute(a)
    d = two_d_cos.disrelation_spectrum(
        spec.synchronous_matrix, spec.asynchronous_matrix
    )
    finite = d[np.isfinite(d)]
    assert (finite >= 0.0).all()
    assert (finite <= 1.0).all()


def test_disrelation_spectrum_zero_case_is_nan() -> None:
    z = np.zeros((3, 3))
    d = two_d_cos.disrelation_spectrum(z, z)
    assert np.isnan(d).all()


def test_disrelation_spectrum_shape_mismatch() -> None:
    with pytest.raises(ValueError, match="shape mismatch"):
        two_d_cos.disrelation_spectrum(np.zeros((3, 3)), np.zeros((4, 4)))
