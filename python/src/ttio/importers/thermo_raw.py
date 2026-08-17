"""Thermo .raw importer — M38.

Delegates to the user-installed `ThermoRawFileParser`_ binary to convert
``.raw`` → mzML, then parses the mzML via :mod:`ttio.importers.mzml`.
No proprietary code ships with TTI-O.

Binary resolution order:

1. Explicit ``thermorawfileparser=`` argument.
2. ``THERMORAWFILEPARSER`` environment variable.
3. ``ThermoRawFileParser`` on ``PATH`` (Linux .NET 8 self-contained build).
4. ``ThermoRawFileParser.exe`` on ``PATH`` — invoked through ``mono``.

.. _ThermoRawFileParser: https://github.com/compomics/ThermoRawFileParser

SPDX-License-Identifier: Apache-2.0

Cross-language equivalents
--------------------------
Objective-C: ``TTIOThermoRawReader`` (v0.4 stub; delegation to
ThermoRawFileParser is a future milestone in ObjC) · Java:
``global.thalion.ttio.importers.ThermoRawReader`` (shipped; delegates
to ThermoRawFileParser binary)

API status: Stable (shipped; delegates to ThermoRawFileParser binary).
"""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from . import mzml
from .import_result import ImportResult


def read(path: str | Path, *,
         thermorawfileparser: str | None = None) -> ImportResult:
    """Import a Thermo ``.raw`` file via ThermoRawFileParser delegation.

    Args:
        path: ``.raw`` file to import.
        thermorawfileparser: Override the resolved binary path.

    Raises:
        FileNotFoundError: Binary could not be located (check PATH or
            install ThermoRawFileParser — see ``docs/vendor-formats.md``).
        RuntimeError: Binary exited non-zero or produced no mzML.
    """
    raw = Path(path)
    if not raw.is_file():
        raise FileNotFoundError(f"Thermo .raw file not found: {raw}")

    cmd_prefix = _resolve_binary(thermorawfileparser)

    with tempfile.TemporaryDirectory(prefix="ttio_thermo_") as tmp:
        out_dir = Path(tmp)
        cmd = list(cmd_prefix) + [
            "-i", str(raw),
            "-o", str(out_dir),
            "-f", "2",  # format 2 = mzML
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            raise RuntimeError(
                f"ThermoRawFileParser exited {proc.returncode}: "
                f"{(proc.stderr or proc.stdout or '').strip()[:500]}")

        expected = out_dir / f"{raw.stem}.mzML"
        if not expected.is_file():
            mzml_files = list(out_dir.glob("*.mzML"))
            if not mzml_files:
                raise RuntimeError(
                    f"ThermoRawFileParser produced no mzML in {out_dir}")
            expected = mzml_files[0]

        return mzml.read(expected)


def _resolve_binary(explicit: str | None) -> list[str]:
    """Return the argv prefix (binary + any interpreter) for invocation."""
    if explicit is not None:
        p = Path(explicit)
        if not p.exists():
            raise FileNotFoundError(
                f"ThermoRawFileParser binary not found: {explicit}")
        return _with_mono_if_needed(str(p))

    env = os.environ.get("THERMORAWFILEPARSER")
    if env:
        p = Path(env)
        if not p.exists():
            raise FileNotFoundError(
                f"THERMORAWFILEPARSER env var points to missing binary: {env}")
        return _with_mono_if_needed(str(p))

    native = shutil.which("ThermoRawFileParser")
    if native:
        return [native]

    dotnet_exe = shutil.which("ThermoRawFileParser.exe")
    if dotnet_exe:
        mono = shutil.which("mono")
        if not mono:
            raise FileNotFoundError(
                "Found ThermoRawFileParser.exe but mono is not on PATH. "
                "Install mono or use the native .NET 8 build.")
        return [mono, dotnet_exe]

    raise FileNotFoundError(
        "ThermoRawFileParser not found on PATH and no explicit path given. "
        "See docs/vendor-formats.md for installation instructions.")


def _with_mono_if_needed(path: str) -> list[str]:
    if path.lower().endswith(".exe"):
        mono = shutil.which("mono")
        if not mono:
            raise FileNotFoundError(
                f"{path} requires mono, which is not on PATH.")
        return [mono, path]
    return [path]


def stream_source(path: str | Path, *, thermorawfileparser: str | None = None,
                  name: str = "run_0001", batch_spectra: int = 4096,
                  progress=None):
    """A :class:`~ttio.importers.import_result.SpectralStreamSource`
    that converts the ``.raw`` to mzML in a temporary directory and
    streams that mzML through :class:`~ttio.importers.mzml.MzMLStream`;
    the temporary directory lives until the stream is exhausted. Peak
    memory is one batch of spectra, not the run.
    """
    raw = Path(path)
    if not raw.is_file():
        raise FileNotFoundError(f"Thermo .raw file not found: {raw}")
    cmd_prefix = _resolve_binary(thermorawfileparser)
    return _converted_stream(
        cmd=list(cmd_prefix) + ["-i", str(raw), "-o", "{out}", "-f", "2"],
        stem=raw.stem, tmp_prefix="ttio_thermo_", name=name,
        batch_spectra=batch_spectra, progress=progress,
        error_cls=RuntimeError, tool="ThermoRawFileParser")


def _converted_stream(*, cmd, stem, tmp_prefix, name, batch_spectra, progress,
                      error_cls, tool):
    from .import_result import SpectralStreamSource
    from .mzml import MzMLStream

    holder = {}

    def _iter():
        tmp = tempfile.TemporaryDirectory(prefix=tmp_prefix)
        try:
            out_dir = Path(tmp.name)
            proc = subprocess.run([c.replace("{out}", str(out_dir)) for c in cmd],
                                  capture_output=True, text=True)
            if proc.returncode != 0:
                raise error_cls(f"{tool} exited {proc.returncode}: "
                                f"{(proc.stderr or proc.stdout or '').strip()[:500]}")
            expected = out_dir / f"{stem}.mzML"
            if not expected.is_file():
                files = list(out_dir.glob("*.mzML"))
                if not files:
                    raise error_cls(f"{tool} produced no mzML in {out_dir}")
                expected = files[0]
            stream = MzMLStream(expected, batch_spectra=batch_spectra, progress=progress)
            holder["stream"] = stream
            yield from stream.iter_batches()
        finally:
            tmp.cleanup()

    return SpectralStreamSource(
        name=name, iter_batches=_iter, batch_spectra=batch_spectra,
        chromatograms_after=lambda: (holder["stream"].chromatograms if "stream" in holder else []))
