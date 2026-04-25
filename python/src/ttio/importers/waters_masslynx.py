"""Waters MassLynx importer — v0.9 M63.

Delegates to the user-installed Waters conversion tool
(``masslynxraw`` is the usual CLI wrapper around the proprietary
MassLynxRaw SDK). The tool reads a Waters ``.raw`` **directory**
and writes mzML; TTI-O then parses the mzML via
:mod:`ttio.importers.mzml`. No proprietary code ships with TTI-O.

Binary resolution order:

1. Explicit ``converter=`` argument.
2. ``MASSLYNXRAW`` environment variable.
3. ``masslynxraw`` on ``PATH``.
4. ``MassLynxRaw.exe`` on ``PATH`` — invoked through ``mono`` on
   non-Windows hosts.

Waters ``.raw`` inputs are directories (not single files). The
``read()`` function validates the input is a directory before
invoking the converter.

SPDX-License-Identifier: Apache-2.0

Cross-language equivalents
--------------------------
Objective-C: ``TTIOWatersMassLynxReader``
Java:        ``com.dtwthalion.ttio.importers.WatersMassLynxReader``

API status: Provisional (v0.9 M63) — delegates to an external tool;
the CLI flag names below match the common ``masslynxraw`` wrapper
used by the proteomics community. Sites that deploy a different
wrapper (Waters Connect API, in-house scripts) can pass an
explicit ``converter=`` path and the CLI is invoked with the same
``-i <input> -o <output>`` convention.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from . import mzml
from .import_result import ImportResult


class WatersMassLynxError(RuntimeError):
    """Raised when the MassLynx converter exits non-zero or produces no mzML."""


def read(raw_dir: str | Path, *, converter: str | None = None) -> ImportResult:
    """Import a Waters ``.raw`` directory via the MassLynx converter.

    Args:
        raw_dir: Path to the Waters ``.raw`` directory (not a file).
        converter: Override the resolved binary path.

    Raises:
        FileNotFoundError: Binary could not be located, or ``raw_dir``
            is not a directory. Use :envvar:`MASSLYNXRAW` or install
            the converter — see ``docs/vendor-formats.md``.
        WatersMassLynxError: Binary exited non-zero or produced no mzML.
    """
    src = Path(raw_dir)
    if not src.is_dir():
        raise FileNotFoundError(f"Waters .raw directory not found: {src}")

    cmd_prefix = _resolve_binary(converter)

    with tempfile.TemporaryDirectory(prefix="ttio_masslynx_") as tmp:
        out_dir = Path(tmp)
        cmd = list(cmd_prefix) + [
            "-i", str(src),
            "-o", str(out_dir),
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            raise WatersMassLynxError(
                f"MassLynx converter exited {proc.returncode}: "
                f"{(proc.stderr or proc.stdout or '').strip()[:500]}")

        stem = src.name
        if stem.lower().endswith(".raw"):
            stem = stem[:-4]
        expected = out_dir / f"{stem}.mzML"
        if not expected.is_file():
            mzml_files = list(out_dir.glob("*.mzML"))
            if not mzml_files:
                raise WatersMassLynxError(
                    f"MassLynx converter produced no mzML in {out_dir}")
            expected = mzml_files[0]

        return mzml.read(expected)


def _resolve_binary(explicit: str | None) -> list[str]:
    """Return the argv prefix (binary + any interpreter) for invocation."""
    if explicit is not None:
        p = Path(explicit)
        if not p.exists():
            raise FileNotFoundError(
                f"MassLynx converter not found: {explicit}")
        return _with_mono_if_needed(str(p))

    env = os.environ.get("MASSLYNXRAW")
    if env:
        p = Path(env)
        if not p.exists():
            raise FileNotFoundError(
                f"MASSLYNXRAW env var points to missing binary: {env}")
        return _with_mono_if_needed(str(p))

    native = shutil.which("masslynxraw")
    if native:
        return [native]

    win_exe = shutil.which("MassLynxRaw.exe")
    if win_exe:
        mono = shutil.which("mono")
        if not mono:
            raise FileNotFoundError(
                "Found MassLynxRaw.exe but mono is not on PATH. "
                "Install mono or run this on Windows.")
        return [mono, win_exe]

    raise FileNotFoundError(
        "MassLynx converter ('masslynxraw' or 'MassLynxRaw.exe') not found "
        "on PATH and no explicit path given. See docs/vendor-formats.md "
        "for installation instructions.")


def _with_mono_if_needed(path: str) -> list[str]:
    if path.lower().endswith(".exe"):
        mono = shutil.which("mono")
        if not mono:
            raise FileNotFoundError(
                f"{path} requires mono, which is not on PATH.")
        return [mono, path]
    return [path]
