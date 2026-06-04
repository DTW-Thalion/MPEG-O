"""``Reader`` — uniform importer interface. A reader parses one or more
source files into an in-memory :class:`ImportedDataset`; it does NOT
write any `.tio` file (the registry / caller calls ``.write()``).

Cross-language equivalents: Java ``importers.Reader``, Objective-C
``TTIOReader``.
"""
from __future__ import annotations

from typing import Mapping, Protocol, runtime_checkable

from .imported_dataset import ImportedDataset


@runtime_checkable
class Reader(Protocol):
    def read(self, inputs: list, opts: Mapping, progress=None) -> ImportedDataset:
        """Parse ``inputs`` into a draft. ``inputs[0]`` is the primary
        source; extra entries carry secondary files (e.g. imzML ``.ibd``).
        ``opts`` carries format-specific knobs (``reference``, ``ms2``,
        ``name``, ``sample``, ``encoding``)."""
        ...
