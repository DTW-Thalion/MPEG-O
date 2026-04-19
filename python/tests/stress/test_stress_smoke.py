"""Smoke placeholder for the M62 stress / benchmark suite.

All tests in this directory should be marked ``@pytest.mark.stress``
so the default CI run skips them. The nightly job removes the marker
filter and runs everything.
"""
from __future__ import annotations

import pytest


@pytest.mark.stress
def test_stress_marker_collected() -> None:
    """Empty placeholder; verifies the stress marker is registered."""
