"""``RamanImage`` — Raman hyperspectral imaging cube."""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np


@dataclass(slots=True)
class RamanImage:
    """Raman hyperspectral imaging dataset: a ``width × height`` grid of
    pixels, each pixel a spectrum of ``spectral_points`` intensity values
    sampled at a shared rank-1 ``wavenumbers`` axis.

    Parameters
    ----------
    width, height : int, default 0
        Image grid dimensions in pixels.
    spectral_points : int, default 0
        Number of float64 intensity values per pixel.
    intensity : numpy.ndarray, default empty rank-3 array
        Rank-3 intensity cube of shape ``(height, width, spectral_points)``.
    wavenumbers : numpy.ndarray, default empty rank-1 array
        Rank-1 wavenumber axis of length ``spectral_points`` (1/cm).
    pixel_size_x, pixel_size_y : float, default 0.0
        Spatial pixel size (implementation-defined units).
    scan_pattern : str, default ""
        Scan pattern label (``"raster"``, ``"random_access"``, ...).
    tile_size : int, default 0
        HDF5 chunk tile size for reads; 0 means native cube chunks.
    excitation_wavelength_nm : float, default 0.0
        Laser excitation wavelength in nanometres.
    laser_power_mw : float, default 0.0
        Incident laser power in milliwatts.
    title, isa_investigation_id : str, default ""
        Dataset-level metadata.
    identifications, quantifications, provenance_records : list, default []
        Dataset-level composition fields (ObjC inherits these from
        ``TTIOSpectralDataset``).

    Notes
    -----
    API status: Stable (v0.11, M73).

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIORamanImage`` · Java:
    ``global.thalion.ttio.RamanImage``.
    """

    width: int = 0
    height: int = 0
    spectral_points: int = 0
    pixel_size_x: float = 0.0
    pixel_size_y: float = 0.0
    intensity: np.ndarray = field(default_factory=lambda: np.zeros((0, 0, 0)))
    wavenumbers: np.ndarray = field(default_factory=lambda: np.zeros((0,)))
    scan_pattern: str = ""
    tile_size: int = 0
    excitation_wavelength_nm: float = 0.0
    laser_power_mw: float = 0.0

    title: str = ""
    isa_investigation_id: str = ""
    identifications: list = field(default_factory=list)
    quantifications: list = field(default_factory=list)
    provenance_records: list = field(default_factory=list)

    def __post_init__(self) -> None:
        if self.width == 0 and self.height == 0 and self.spectral_points == 0:
            return
        if self.intensity.ndim != 3:
            raise ValueError(
                f"intensity must be rank-3, got shape={self.intensity.shape}"
            )
        h, w, sp = self.intensity.shape
        if (h, w, sp) != (self.height, self.width, self.spectral_points):
            raise ValueError(
                f"intensity shape {(h, w, sp)} does not match "
                f"(height, width, spectral_points)="
                f"{(self.height, self.width, self.spectral_points)}"
            )
        if self.wavenumbers.ndim != 1 or self.wavenumbers.shape[0] != self.spectral_points:
            raise ValueError(
                f"wavenumbers shape {self.wavenumbers.shape} does not match "
                f"spectral_points={self.spectral_points}"
            )


__all__ = ["RamanImage"]
