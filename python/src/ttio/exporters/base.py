"""``Writer`` — uniform exporter interface. A writer serializes one
layer of an *opened* :class:`SpectralDataset` to an output path. The
registry / caller owns opening the `.tio` and selecting the run.

Cross-language equivalents: Java ``exporters.Writer``, Objective-C
``TTIOWriter``.
"""
from __future__ import annotations

from typing import Mapping, Protocol, runtime_checkable

from ..spectral_dataset import SpectralDataset


@runtime_checkable
class Writer(Protocol):
    def write(self, ds: SpectralDataset, layer: str | None, output: str,
              opts: Mapping) -> None:
        ...
