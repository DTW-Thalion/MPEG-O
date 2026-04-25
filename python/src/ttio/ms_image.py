"""``MSImage`` — mass-spectrometry imaging cube."""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from .spectral_dataset import SpectralDataset


@dataclass(slots=True)
class MSImage:
    """Mass-spectrometry imaging dataset: a ``width × height`` grid of
    pixels, each pixel a spectral profile of ``spectral_points`` values.

    Parameters
    ----------
    width, height : int, default 0
        Image grid dimensions in pixels.
    spectral_points : int, default 0
        Number of float64 values per pixel.
    intensity : numpy.ndarray, default empty rank-3 array
        Rank-3 intensity cube of shape ``(height, width, spectral_points)``.
    pixel_size_x, pixel_size_y : float, default 0.0
        Spatial pixel size (implementation-defined units).
    scan_pattern : str, default ""
        Scan pattern label (e.g. ``"raster"``, ``"random_access"``).
    tile_size : int, default 0
        HDF5 chunk tile size for reads; 0 means native cube chunks.
    title, isa_investigation_id : str, default ""
        Dataset-level metadata. In Objective-C these are inherited
        from ``TTIOSpectralDataset``; in Python they are composed
        directly onto ``MSImage``.
    identifications : list, default []
        Dataset-level identifications (composed — see Notes).
    quantifications : list, default []
        Dataset-level quantifications (composed).
    provenance_records : list, default []
        Dataset-level provenance records (composed).

    Notes
    -----
    API status: Stable.

    **Composition vs inheritance.** In Objective-C ``TTIOMSImage``
    inherits from ``TTIOSpectralDataset`` so dataset-level fields come
    for free. In Python, ``SpectralDataset`` is a file-handle wrapper
    whose lifecycle does not map cleanly to an MSImage subclass;
    composition is used here (the five dataset-level fields live on
    ``MSImage`` directly). This is a known stylistic difference
    between the language implementations, recorded in
    :doc:`/api-review-v0.6`.

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIOMSImage`` · Java:
    ``com.dtwthalion.ttio.MSImage``.
    """

    width: int = 0
    height: int = 0
    spectral_points: int = 0
    pixel_size_x: float = 0.0
    pixel_size_y: float = 0.0
    intensity: np.ndarray = field(default_factory=lambda: np.zeros((0, 0, 0)))
    scan_pattern: str = ""
    tile_size: int = 0

    # Dataset-level composition fields (ObjC inherits from TTIOSpectralDataset)
    title: str = ""
    isa_investigation_id: str = ""
    identifications: list = field(default_factory=list)
    quantifications: list = field(default_factory=list)
    provenance_records: list = field(default_factory=list)

    def __post_init__(self) -> None:
        if self.width == 0 and self.height == 0 and self.spectral_points == 0:
            return  # empty default OK
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


__all__ = ["MSImage", "SpectralDataset"]
