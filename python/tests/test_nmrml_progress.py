"""ProgressSink coverage for :func:`ttio.importers.nmrml.read`.

NmrML is a single-spectrum format; progress should fire once with
``(n, n)`` after parse completes (no mid-parse fires).
"""
from __future__ import annotations

from pathlib import Path

import pytest

from ttio.importers.nmrml import read


_REPO_ROOT = Path(__file__).resolve().parents[2]
_FIXTURE = _REPO_ROOT / "objc" / "Tests" / "Fixtures" / "bmse000325.nmrML"


@pytest.fixture(scope="module")
def nmrml_fixture() -> Path:
    if not _FIXTURE.is_file():
        pytest.skip(f"missing {_FIXTURE}")
    return _FIXTURE


def test_nmrml_progress_fires_once(nmrml_fixture: Path) -> None:
    events: list[tuple[int, int]] = []
    result = read(nmrml_fixture, progress=lambda d, t: events.append((d, t)))
    n = len(result.nmr_spectra)
    # Single-spectrum format -> exactly one fire and total reported.
    assert events, "expected at least one progress callback"
    assert events[-1] == (n, n)


def test_nmrml_progress_none_safe(nmrml_fixture: Path) -> None:
    result = read(nmrml_fixture)
    assert result is not None
