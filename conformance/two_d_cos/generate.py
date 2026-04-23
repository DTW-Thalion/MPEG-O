"""Deterministic 2D-COS reference fixture generator (M77).

Produces a small perturbation-series matrix plus the expected
synchronous and asynchronous matrices computed by the Python
reference implementation (``mpeg_o.analysis.two_d_cos.compute``).
Python, Java, and ObjC test suites all load the CSVs written here
and compare their own compute outputs against them with a
float-tolerance gate (rtol=1e-9, atol=1e-12).

Usage:
    python3 conformance/two_d_cos/generate.py

The CSVs are committed. Re-run only when the reference implementation
intentionally changes semantics — then bump the fixture tag in
WORKPLAN + CHANGELOG and notify all three language test owners.

Shape rationale:
    m (perturbation points) = 24
    n (spectral variables)  = 16

Small enough to keep the CSVs readable and the Java/ObjC nested-loop
matrix multiplies fast, large enough that the Hilbert-Noda matrix
introduces meaningful off-diagonal weight.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(REPO / "python" / "src"))

from mpeg_o.analysis import two_d_cos  # noqa: E402


M = 24
N = 16


def build_dynamic() -> np.ndarray:
    """Return the (m, n) perturbation-series matrix.

    Synthesised as a small sum of Gaussian bands whose centres and
    amplitudes evolve over the perturbation axis — representative of
    a real temperature/concentration-driven dataset but fully
    deterministic and numpy-independent to describe.
    """
    t = np.linspace(0.0, 1.0, M)                # perturbation axis
    v = np.linspace(0.0, 1.0, N)                # spectral axis
    a = np.zeros((M, N), dtype=np.float64)
    centres = [0.2, 0.5, 0.8]
    widths = [0.08, 0.06, 0.10]
    for k, (c0, w) in enumerate(zip(centres, widths)):
        # Centre drifts linearly with perturbation.
        centres_t = c0 + 0.05 * t * (1 - 2 * (k % 2))
        # Amplitude modulates sinusoidally, phase-shifted per band.
        amps = 1.0 + 0.5 * np.sin(2 * np.pi * t + k * np.pi / 3.0)
        for i in range(M):
            a[i] += amps[i] * np.exp(
                -0.5 * ((v - centres_t[i]) / w) ** 2
            )
    # Add a slow baseline drift so mean-centering is non-trivial.
    a += 0.1 * t[:, np.newaxis] * (1.0 - v[np.newaxis, :])
    return a


def _write_csv(path: Path, arr: np.ndarray) -> None:
    # repr-precision float64 (17 sig digits) round-trips exactly.
    with path.open("w", encoding="utf-8", newline="\n") as fh:
        for row in arr:
            fh.write(",".join(repr(float(x)) for x in row))
            fh.write("\n")


def main() -> None:
    dyn = build_dynamic()
    spec = two_d_cos.compute(dyn)
    _write_csv(HERE / "dynamic.csv", dyn)
    _write_csv(HERE / "sync.csv", spec.synchronous_matrix)
    _write_csv(HERE / "async.csv", spec.asynchronous_matrix)
    print(
        f"wrote dynamic.csv ({M}x{N}), "
        f"sync.csv + async.csv ({N}x{N}) to {HERE}"
    )


if __name__ == "__main__":
    main()
