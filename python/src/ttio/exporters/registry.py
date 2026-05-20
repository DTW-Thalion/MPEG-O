"""Export-format registry: the formats ``ttio export --format <fmt>``
accepts and how each maps a `.tio` layer to an output file.

Export mirror of :mod:`ttio.importers.registry` (W6.4). Each spec wraps
an existing exporter in a uniform
``adapter(tio_path, layer, output, **opts) -> None``.

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
concern: the adapter dispatches and the writer raises its own clear
error when the tool is missing.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

from ..spectral_dataset import SpectralDataset

CLI_DELEGATED = ("fasta", "fastq")
DEFERRED_PYTHON = ("nmrml", "jcamp-dx", "imzml")


class UnknownFormatError(ValueError):
    """Raised for a ``--format`` value that maps to no known exporter."""


@dataclass(frozen=True)
class ExportSpec:
    key: str
    display_name: str
    extensions: tuple[str, ...]
    required_tool: str | None
    adapter: Callable[..., None]


def _adapt_mzml(tio_path, layer, output, **opts):
    from ..exporters import mzml
    with SpectralDataset.open(tio_path) as ds:
        mzml.write_dataset(ds, output)


def _adapt_mztab(tio_path, layer, output, **opts):
    from ..exporters import mztab
    with SpectralDataset.open(tio_path) as ds:
        mztab.write_dataset(ds, output)


def _adapt_isa(tio_path, layer, output, **opts):
    from ..exporters import isa
    # ISA writes a multi-file bundle into a directory.
    with SpectralDataset.open(tio_path) as ds:
        isa.write_bundle_for_dataset(ds, output)


def _adapt_bam(tio_path, layer, output, **opts):
    from ..exporters.bam import BamWriter
    with SpectralDataset.open(tio_path) as ds:
        BamWriter(output).write(_genomic_run(ds, layer))


def _adapt_cram(tio_path, layer, output, **opts):
    from ..exporters.cram import CramWriter
    reference = opts.get("reference")
    if not reference:
        raise ValueError(
            "CRAM export is reference-compressed; pass the reference FASTA "
            "via --extra --reference <path>")
    with SpectralDataset.open(tio_path) as ds:
        CramWriter(output, reference).write(_genomic_run(ds, layer))


def _genomic_run(ds, layer):
    runs = ds.genomic_runs
    if not runs:
        raise KeyError("no genomic runs in dataset")
    if layer:
        if layer not in runs:
            raise KeyError(
                f"genomic run {layer!r} not found; have: "
                + ", ".join(sorted(runs)))
        return runs[layer]
    if len(runs) == 1:
        return next(iter(runs.values()))
    raise KeyError(
        "multiple genomic runs present; pass --layer <name>: "
        + ", ".join(sorted(runs)))


_SPECS: tuple[ExportSpec, ...] = (
    ExportSpec("mzml", "mzML", (".mzML",), None, _adapt_mzml),
    ExportSpec("mztab", "mzTab", (".mzTab", ".mztab"), None, _adapt_mztab),
    ExportSpec("isa", "ISA-Tab/JSON", (".zip", ".json"), None, _adapt_isa),
    ExportSpec("bam", "BAM", (".bam", ".sam"), "samtools", _adapt_bam),
    ExportSpec("cram", "CRAM", (".cram",), "samtools", _adapt_cram),
)

_BY_KEY: dict[str, ExportSpec] = {s.key: s for s in _SPECS}

_ALIASES: dict[str, str] = {
    "isa-tab": "isa",
    "isatab": "isa",
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
    spec_for(fmt).adapter(tio_path, layer, output, **opts)
