"""``MSImage`` — mass-spectrometry imaging cube.

Thin placeholder for M16: the cube layout is specified in §7 of
``docs/format-spec.md`` but no fixture currently exercises it. We expose the
value class so the public API surface matches the ObjC reference; full
reader/writer support lands with M19/M21.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .spectral_dataset import SpectralDataset


@dataclass(slots=True)
class MSImage:
    """An MSI acquisition as a rank-3 ``(H, W, SP)`` intensity cube."""

    width: int
    height: int
    spectral_points: int
    pixel_size_x: float
    pixel_size_y: float
    intensity: np.ndarray
    scan_pattern: str = ""
    tile_size: int = 0

    def __post_init__(self) -> None:
        if self.intensity.ndim != 3:
            raise ValueError(
                f"intensity must be rank-3, got shape={self.intensity.shape}"
            )
        h, w, sp = self.intensity.shape
        if (h, w, sp) != (self.height, self.width, self.spectral_points):
            raise ValueError(
                f"intensity shape {(h, w, sp)} does not match "
                f"(height, width, spectral_points)={(self.height, self.width, self.spectral_points)}"
            )


__all__ = ["MSImage", "SpectralDataset"]
