"""M77 cross-language conformance gate — Python side.

Loads ``conformance/two_d_cos/dynamic.csv``, computes the 2D-COS
decomposition via ``mpeg_o.analysis.two_d_cos.compute``, and asserts
it matches the committed ``sync.csv`` / ``async.csv`` within
``rtol=1e-9, atol=1e-12``. The Java and ObjC suites ship analogous
tests — together they form the M77 cross-language float-tolerance
gate.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from mpeg_o.analysis import two_d_cos


def _find_conformance_dir() -> Path | None:
    here = Path(__file__).resolve().parent
    for candidate in [here] + list(here.parents):
        probe = candidate / "conformance" / "two_d_cos"
        if probe.is_dir():
            return probe
    return None


def _read_csv(path: Path) -> np.ndarray:
    rows: list[list[float]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        rows.append([float(x) for x in line.split(",")])
    return np.array(rows, dtype=np.float64)


def test_m77_two_d_cos_conformance_fixture() -> None:
    conf = _find_conformance_dir()
    if conf is None:
        pytest.skip("conformance/two_d_cos not reachable from test CWD")
    dyn = _read_csv(conf / "dynamic.csv")
    expected_sync = _read_csv(conf / "sync.csv")
    expected_async = _read_csv(conf / "async.csv")

    spec = two_d_cos.compute(dyn)

    np.testing.assert_allclose(
        spec.synchronous_matrix, expected_sync, rtol=1e-9, atol=1e-12
    )
    np.testing.assert_allclose(
        spec.asynchronous_matrix, expected_async, rtol=1e-9, atol=1e-12
    )
