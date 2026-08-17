# tools/perf/compression_suite/formats/__init__.py
"""Format modules. Each registers Format objects into REGISTRY at import."""
from __future__ import annotations

import importlib
from pathlib import Path
from typing import Protocol


class Format(Protocol):
    key: str
    tier: str          # aligned | unaligned | ms
    lossy: bool
    def encode(self, inp: Path, out_dir: Path, ref: Path | None) -> Path: ...
    def decode(self, enc: Path, out_dir: Path, ref: Path | None) -> Path: ...
    def version(self) -> str: ...


REGISTRY: dict[str, Format] = {}


def register(fmt: Format) -> Format:
    REGISTRY[fmt.key] = fmt
    return fmt


def load_all() -> dict[str, Format]:
    for mod in ("bam_cram", "mpegg", "ttio_fmt", "fastq", "mzml"):
        importlib.import_module(f"formats.{mod}")
    return REGISTRY
