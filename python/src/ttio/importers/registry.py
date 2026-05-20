"""Encode-format registry: the single source of truth for the formats
``ttio encode --format <fmt>`` accepts and how each maps to a `.tio`.

Mirrors the tio-browser GUI ``ImportFormatRegistry`` so the CLI and the
desktop app cover the same spec §4 format set (W6.4). Each spec wraps a
format's existing importer in a uniform
``adapter(inputs, output, **opts) -> None`` that writes a `.tio`.

Two formats stand apart and are intentionally NOT in this registry:

* ``fasta`` / ``fastq`` keep their richer dedicated CLIs
  (``ttio.tools.{fasta,fastq}_import_cli`` -- reference vs. unaligned
  modes, PHRED options); ``ttio encode`` delegates to those directly.
* ``JCAMP-DX`` -- the Python ``ttio.importers.jcamp_dx`` module reads
  JDX into vibrational ``Spectrum`` objects but has no `.tio` bridge
  (that conversion is GUI/Java-only today). Tracked as a Python-side
  parity gap; not yet reachable from the CLI.

Runtime tool availability (samtools for BAM/SAM/CRAM, the vendor
converters for Thermo / Waters / Bruker) is the importer's concern: the
adapter dispatches and the importer raises its own clear error when the
tool is missing. "Has a codec" (registered here) is distinct from "the
external tool is installed right now".
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

# Importers delegated to the dedicated CLIs rather than this registry.
CLI_DELEGATED = ("fasta", "fastq")

# Python reads the format but has no `.tio` importer yet (GUI/Java only).
DEFERRED_PYTHON = ("jcamp-dx",)


class UnknownFormatError(ValueError):
    """Raised for a ``--format`` value that maps to no known codec."""


@dataclass(frozen=True)
class FormatSpec:
    key: str                       # canonical lowercase key
    display_name: str              # GUI-matching label (e.g. "mzML")
    extensions: tuple[str, ...]
    required_tool: str | None      # external binary, or None
    adapter: Callable[..., None]   # (inputs, output, **opts) -> None


# ---- adapters (lazy imports keep optional deps out of import time) ----

def _adapt_import_result(reader_module: str):
    """Adapter for importers exposing ``read(path) -> X`` where X has
    ``to_ttio(output)`` (mzML / mzTab / imzML / nmrML / Thermo / Waters)."""
    def _adapter(inputs, output, **opts):
        import importlib
        mod = importlib.import_module(f"ttio.importers.{reader_module}")
        result = mod.read(inputs[0])
        result.to_ttio(output)
    return _adapter


def _adapt_imzml(inputs, output, **opts):
    from ttio.importers import imzml
    ibd = opts.get("ibd")
    if ibd is None and len(inputs) > 1:
        ibd = inputs[1]
    imzml.read(inputs[0], ibd_path=ibd).to_ttio(output)


def _adapt_bruker(inputs, output, **opts):
    from ttio.importers import bruker_tdf
    bruker_tdf.read(inputs[0], output, ms2=bool(opts.get("ms2", False)))


def _adapt_genomic(reader_attr: str):
    """Adapter for BAM/SAM/CRAM: read into a genomic run, write minimal."""
    def _adapter(inputs, output, **opts):
        from ttio.importers import bam as bam_mod
        from ttio.importers import cram as cram_mod
        from ttio.importers import sam as sam_mod
        from ttio.spectral_dataset import SpectralDataset
        reader_cls = {
            "BamReader": bam_mod.BamReader,
            "SamReader": sam_mod.SamReader,
            "CramReader": cram_mod.CramReader,
        }[reader_attr]
        name = opts.get("name", "genomic_0001")
        run = reader_cls(inputs[0]).to_genomic_run(
            name=name, sample_name=opts.get("sample"))
        SpectralDataset.write_minimal(
            output, title="", isa_investigation_id="",
            runs={}, genomic_runs={name: run})
    return _adapter


_SPECS: tuple[FormatSpec, ...] = (
    FormatSpec("mzml", "mzML", (".mzML", ".mzML.gz"), None,
               _adapt_import_result("mzml")),
    FormatSpec("mztab", "mzTab", (".mzTab", ".mztab"), None,
               _adapt_import_result("mztab")),
    FormatSpec("imzml", "imzML", (".imzML",), None, _adapt_imzml),
    FormatSpec("nmrml", "nmrML", (".nmrML",), None,
               _adapt_import_result("nmrml")),
    FormatSpec("bruker-timstof", "Bruker timsTOF", (".d",),
               "Bruker Python helper", _adapt_bruker),
    FormatSpec("waters-masslynx", "Waters MassLynx", (".raw",),
               "masslynxraw", _adapt_import_result("waters_masslynx")),
    FormatSpec("thermo-raw", "Thermo .raw", (".raw",),
               "ThermoRawFileParser", _adapt_import_result("thermo_raw")),
    FormatSpec("bam", "BAM", (".bam",), "samtools", _adapt_genomic("BamReader")),
    FormatSpec("sam", "SAM", (".sam",), "samtools", _adapt_genomic("SamReader")),
    FormatSpec("cram", "CRAM", (".cram",), "samtools", _adapt_genomic("CramReader")),
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
    spec_for(fmt).adapter(list(inputs), output, **opts)
