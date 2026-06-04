"""Export-format registry: the formats ``ttio export --format <fmt>``
accepts and how each maps a `.tio` layer to an output file.

Export mirror of :mod:`ttio.importers.registry` (W6.4). Each spec pairs a
format with a :class:`ttio.exporters.base.Writer` instance; ``export``
opens the `.tio` and dispatches via ``writer.write(ds, layer, output, opts)``.

Formats handled elsewhere / not yet reachable:

* ``fasta`` / ``fastq`` keep their richer dedicated CLIs
  (``ttio.tools.{fasta,fastq}_export_cli`` -- reference vs. run modes,
  line-width / PHRED options); ``ttio export`` delegates to those.
* ``nmrML`` / ``JCAMP-DX`` / ``imzML`` export from per-spectrum /
  per-pixel objects (``NMRSpectrum``, ``IRSpectrum`` / ``RamanSpectrum``
  / ``UVVisSpectrum``, ``ImzMLPixelSpectrum``) rather than a whole
  dataset, and the Python side has no `.tio`-layer→object extraction
  helper yet (the GUI does this in Java). Tracked as a parity gap; not
  yet reachable from the CLI.

Runtime tool availability (samtools for BAM/CRAM) is the exporter's
concern: the writer dispatches and raises its own clear error when the
tool is missing.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

from ..spectral_dataset import SpectralDataset
from .writers import (
    BamWriter,
    CramWriter,
    ImzMLWriter,
    IsaWriter,
    JcampDxWriter,
    MzMLWriter,
    MzTabWriter,
    NmrMLWriter,
)

if TYPE_CHECKING:
    from .base import Writer

CLI_DELEGATED = ("fasta", "fastq")
# jcamp-dx export was deferred until AcquisitionRun._materialize_spectrum
# could reconstruct the vibrational types (IR/Raman/UV-Vis); that landed
# with the §3.1 round-trip, so jcamp-dx is now a registered exporter.
DEFERRED_PYTHON: tuple[str, ...] = ()


class UnknownFormatError(ValueError):
    """Raised for a ``--format`` value that maps to no known exporter."""


@dataclass(frozen=True)
class ExportSpec:
    key: str
    display_name: str
    extensions: tuple[str, ...]
    required_tool: str | None
    writer: "Writer"               # serializes one layer -> output


_SPECS: tuple[ExportSpec, ...] = (
    ExportSpec("mzml", "mzML", (".mzML",), None, MzMLWriter()),
    ExportSpec("mztab", "mzTab", (".mzTab", ".mztab"), None, MzTabWriter()),
    ExportSpec("nmrml", "nmrML", (".nmrML",), None, NmrMLWriter()),
    ExportSpec("imzml", "imzML", (".imzML",), None, ImzMLWriter()),
    ExportSpec("jcamp-dx", "JCAMP-DX", (".jdx", ".dx", ".jcm"), None,
               JcampDxWriter()),
    ExportSpec("isa", "ISA-Tab/JSON", (".zip", ".json"), None, IsaWriter()),
    ExportSpec("bam", "BAM", (".bam", ".sam"), "samtools", BamWriter()),
    ExportSpec("cram", "CRAM", (".cram",), "samtools", CramWriter()),
)

_BY_KEY: dict[str, ExportSpec] = {s.key: s for s in _SPECS}

_ALIASES: dict[str, str] = {
    "isa-tab": "isa",
    "isatab": "isa",
    "jcamp": "jcamp-dx",
    "jdx": "jcamp-dx",
    "dx": "jcamp-dx",
    "jcm": "jcamp-dx",
}


def normalize(fmt: str) -> str:
    key = (fmt or "").strip().lower()
    return _ALIASES.get(key, key)


def is_registry_format(fmt: str) -> bool:
    return normalize(fmt) in _BY_KEY


def spec_for(fmt: str) -> ExportSpec:
    key = normalize(fmt)
    if key not in _BY_KEY:
        raise UnknownFormatError(fmt)
    return _BY_KEY[key]


def registry_keys() -> list[str]:
    return sorted(_BY_KEY)


def supported_export_formats() -> list[str]:
    return sorted({*_BY_KEY, *CLI_DELEGATED})


def export(fmt: str, tio_path, layer, output, **opts) -> None:
    spec = spec_for(fmt)
    with SpectralDataset.open(tio_path) as ds:
        spec.writer.write(ds, layer, output, opts)
