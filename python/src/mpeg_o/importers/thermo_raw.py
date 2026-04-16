"""Thermo .raw reader stub — Milestone 29.

Defines the public API for a future Thermo .raw importer. In v0.4 all
functions raise :class:`NotImplementedError` with guidance on the Thermo
RawFileReader SDK dependency. The stub exists so downstream code can
import the module and handle the error cleanly.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

from pathlib import Path

from .import_result import ImportResult


def read(path: str | Path) -> ImportResult:
    """Read a Thermo .raw file. **Not yet implemented.**

    Raises :class:`NotImplementedError` with SDK guidance.
    """
    raise NotImplementedError(
        "Thermo .raw import is not yet implemented. It requires the "
        "Thermo RawFileReader SDK (proprietary; free-as-in-beer license "
        "from Thermo Fisher Scientific) or the pythonnet bridge to "
        "ThermoFisher.CommonCore.RawFileReader. "
        "See docs/vendor-formats.md for integration guidance. "
        "Targeted for MPEG-O v0.5+."
    )
