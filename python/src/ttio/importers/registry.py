"""Encode-format registry: the single source of truth for the formats
``ttio encode --format <fmt>`` accepts and how each maps to a `.tio`.

Mirrors the tio-browser GUI ``ImportFormatRegistry`` so the CLI and the
desktop app cover the same spec §4 format set (W6.4). Each spec pairs a
format with a :class:`ttio.importers.base.Reader` instance; ``encode``
dispatches via ``reader.read(inputs, opts) -> ImportedDataset`` then
``.write(output)``.

Two formats stand apart and are intentionally NOT in this registry:

* ``fasta`` / ``fastq`` keep their richer dedicated CLIs
  (``ttio.tools.{fasta,fastq}_import_cli`` -- reference vs. unaligned
  modes, PHRED options); ``ttio encode`` delegates to those directly.
Runtime tool availability (samtools for BAM/SAM/CRAM, the vendor
converters for Thermo / Waters / Bruker) is the importer's concern: the
reader dispatches and the importer raises its own clear error when the
tool is missing. "Has a codec" (registered here) is distinct from "the
external tool is installed right now".
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

from .readers import (
    BamReader,
    BrukerReader,
    CramReader,
    ImzMLReader,
    JcampDxReader,
    MzMLReader,
    MzTabReader,
    NmrMLReader,
    SamReader,
    ThermoRawReader,
    WatersMassLynxReader,
)

if TYPE_CHECKING:
    from .base import Reader

# Importers delegated to the dedicated CLIs rather than this registry.
CLI_DELEGATED = ("fasta", "fastq")

# Formats read into Spectrum objects but not yet bridged to `.tio`.
# (jcamp-dx was here until the vibrational `.tio` round-trip landed.)
DEFERRED_PYTHON: tuple[str, ...] = ()


class UnknownFormatError(ValueError):
    """Raised for a ``--format`` value that maps to no known codec."""


@dataclass(frozen=True)
class FormatSpec:
    key: str                       # canonical lowercase key
    display_name: str              # GUI-matching label (e.g. "mzML")
    extensions: tuple[str, ...]
    required_tool: str | None      # external binary, or None
    reader: "Reader"               # parses inputs -> ImportedDataset


_SPECS: tuple[FormatSpec, ...] = (
    FormatSpec("mzml", "mzML", (".mzML", ".mzML.gz"), None, MzMLReader()),
    FormatSpec("mztab", "mzTab", (".mzTab", ".mztab"), None, MzTabReader()),
    FormatSpec("imzml", "imzML", (".imzML",), None, ImzMLReader()),
    FormatSpec("nmrml", "nmrML", (".nmrML",), None, NmrMLReader()),
    FormatSpec("jcamp-dx", "JCAMP-DX", (".jdx", ".dx", ".jcm"), None,
               JcampDxReader()),
    FormatSpec("bruker-timstof", "Bruker timsTOF", (".d",),
               "Bruker Python helper", BrukerReader()),
    FormatSpec("waters-masslynx", "Waters MassLynx", (".raw",),
               "masslynxraw", WatersMassLynxReader()),
    FormatSpec("thermo-raw", "Thermo .raw", (".raw",),
               "ThermoRawFileParser", ThermoRawReader()),
    FormatSpec("bam", "BAM", (".bam",), "samtools", BamReader()),
    FormatSpec("sam", "SAM", (".sam",), "samtools", SamReader()),
    FormatSpec("cram", "CRAM", (".cram",), "samtools", CramReader()),
)

_BY_KEY: dict[str, FormatSpec] = {s.key: s for s in _SPECS}

# Aliases -> canonical key. Lets users pass "thermo", "raw", "timstof",
# "masslynx", etc.
_ALIASES: dict[str, str] = {
    "thermo": "thermo-raw",
    "thermo.raw": "thermo-raw",
    "raw": "thermo-raw",
    "waters": "waters-masslynx",
    "masslynx": "waters-masslynx",
    "bruker": "bruker-timstof",
    "timstof": "bruker-timstof",
    "tdf": "bruker-timstof",
    "jcamp": "jcamp-dx",
    "jdx": "jcamp-dx",
    "dx": "jcamp-dx",
    "jcm": "jcamp-dx",
}


def normalize(fmt: str) -> str:
    """Canonicalise a user-supplied format token (lowercase, alias-mapped)."""
    key = (fmt or "").strip().lower()
    return _ALIASES.get(key, key)


def is_registry_format(fmt: str) -> bool:
    return normalize(fmt) in _BY_KEY


def spec_for(fmt: str) -> FormatSpec:
    key = normalize(fmt)
    if key not in _BY_KEY:
        raise UnknownFormatError(fmt)
    return _BY_KEY[key]


def registry_keys() -> list[str]:
    """Canonical keys handled by this registry (sorted)."""
    return sorted(_BY_KEY)


def supported_encode_formats() -> list[str]:
    """All formats ``ttio encode`` accepts: registry + CLI-delegated."""
    return sorted({*_BY_KEY, *CLI_DELEGATED})


def encode(fmt: str, inputs, output, **opts) -> None:
    """Dispatch ``inputs`` -> ``output`` `.tio` for a registry format.

    Raises :class:`UnknownFormatError` for non-registry formats (the CLI
    handles the ``fasta`` / ``fastq`` delegation separately)."""
    spec = spec_for(fmt)
    progress = opts.pop("progress", None)
    spec.reader.read(list(inputs), opts, progress=progress).write(output)
