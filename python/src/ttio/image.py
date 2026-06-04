"""``Image`` — shared base for the imaging cube modalities.

Holds the fields common to every imaging modality (the ``width × height``
pixel grid, the rank-3 ``intensity`` cube, spatial pixel sizes, scan
metadata, and the dataset-level composition fields). The three concrete
imaging classes — :class:`ttio.ms_image.MSImage`,
:class:`ttio.raman_image.RamanImage`, and :class:`ttio.ir_image.IRImage` —
subclass this base, contribute their own distinct spectral-axis fields,
and keep their own on-disk group plus ``read_from`` / ``write_to``.

This is an in-memory abstraction only: extracting these common fields does
**not** change the ``.tio`` wire format. Each subclass still writes/reads
its modality-specific group with the identical bytes.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import ClassVar

import numpy as np

from .enums import ImageKind, SpectralAxisKind


@dataclass(slots=True)
class Image:
    """Shared base for imaging cubes; see the module docstring.

    Parameters
    ----------
    width, height : int, default 0
        Image grid dimensions in pixels.
    spectral_points : int, default 0
        Number of float64 values per pixel.
    pixel_size_x, pixel_size_y : float, default 0.0
        Spatial pixel size (implementation-defined units).
    intensity : numpy.ndarray, default empty rank-3 array
        Rank-3 intensity cube of shape ``(height, width, spectral_points)``.
    scan_pattern : str, default ""
        Scan pattern label (e.g. ``"raster"``, ``"random_access"``).
    tile_size : int, default 0
        HDF5 chunk tile size for reads; 0 means native cube chunks.
    title, isa_investigation_id : str, default ""
        Dataset-level metadata.
    identifications, quantifications, provenance_records : list, default []
        Dataset-level composition fields.

    Notes
    -----
    Subclasses set the ``kind`` class variable and override the
    :attr:`spectral_axis` / :attr:`spectral_axis_kind` properties.
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

    #: Modality discriminator; each concrete subclass overrides this.
    kind: ClassVar[ImageKind]

    @property
    def spectral_axis(self) -> np.ndarray:
        """The modality's spectral axis (m/z for MS, wavenumbers for Raman/IR).

        Overridden by each subclass to alias its distinct axis field.
        """
        raise NotImplementedError

    @property
    def spectral_axis_kind(self) -> SpectralAxisKind:
        """Interpretation of :attr:`spectral_axis` for this modality."""
        raise NotImplementedError


__all__ = ["Image"]
