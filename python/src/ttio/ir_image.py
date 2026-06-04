"""``IRImage`` — infrared hyperspectral imaging cube."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import ClassVar

import numpy as np

from .enums import IRMode, ImageKind, SpectralAxisKind
from .image import Image


def _parse_double_attr(value) -> float:
    """Parse a double attribute that may be a float/int (native) or str (legacy)."""
    if isinstance(value, (int, float)):
        return float(value)
    return float(str(value))


@dataclass(slots=True)
class IRImage(Image):
    """Infrared hyperspectral imaging dataset: a ``width × height`` grid
    of pixels, each pixel an IR spectrum of ``spectral_points`` intensity
    values sampled at a shared rank-1 ``wavenumbers`` axis.

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
    mode : IRMode, default ``IRMode.TRANSMITTANCE``
        Whether y-values are absorbance or transmittance.
    resolution_cm_inv : float, default 0.0
        Spectral resolution in reciprocal centimetres.
    title, isa_investigation_id : str, default ""
        Dataset-level metadata.
    identifications, quantifications, provenance_records : list, default []
        Dataset-level composition fields.

    Notes
    -----
    API status: Stable (v0.11, M73).

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIOIRImage`` · Java:
    ``global.thalion.ttio.IRImage``.
    """

    # Common fields are inherited from Image; only IR-specific fields here.
    wavenumbers: np.ndarray = field(default_factory=lambda: np.zeros((0,)))
    mode: IRMode = IRMode.TRANSMITTANCE
    resolution_cm_inv: float = 0.0

    kind: ClassVar[ImageKind] = ImageKind.IR

    @property
    def spectral_axis(self) -> np.ndarray:
        """The wavenumber axis (alias of :attr:`wavenumbers`)."""
        return self.wavenumbers

    @property
    def spectral_axis_kind(self) -> SpectralAxisKind:
        return SpectralAxisKind.WAVENUMBER

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

    def write_to(self, study_group) -> None:
        """Write this IR image cube under ``<study_group>/ir_image_cube/``.

        Mirrors :meth:`global.thalion.ttio.IRImage.writeTo` — intensity
        as a 3-D ``[h, w, sp]`` dataset, ``wavenumbers`` 1-D dataset,
        and IR-specific scalar attributes (``ir_mode``,
        ``resolution_cm_inv``).

        Pixel size attributes are written as **native double** (not
        strings), applying the PR #31 lesson immediately so legacy-string
        reads remain backwards-compatible via :meth:`read_from`.
        """
        from ttio.enums import Compression, Precision
        ic = study_group.create_group("ir_image_cube")
        ic.set_attribute("width", int(self.width))
        ic.set_attribute("height", int(self.height))
        ic.set_attribute("spectral_points", int(self.spectral_points))
        ic.set_attribute("pixel_size_x", float(self.pixel_size_x))
        ic.set_attribute("pixel_size_y", float(self.pixel_size_y))
        ic.set_attribute("scan_pattern", self.scan_pattern)
        ic.set_attribute("ir_mode", int(self.mode))
        ic.set_attribute("resolution_cm_inv", float(self.resolution_cm_inv))

        intensity_ds = ic.create_dataset_nd(
            "intensity", Precision.FLOAT64,
            shape=(self.height, self.width, self.spectral_points),
            chunks=(1, 1, self.spectral_points),
            compression=Compression.ZLIB, compression_level=6,
        )
        intensity_ds.write(np.ascontiguousarray(self.intensity, dtype=np.float64))

        wn_ds = ic.create_dataset_nd(
            "wavenumbers", Precision.FLOAT64,
            shape=(self.spectral_points,),
            chunks=(self.spectral_points,),
            compression=Compression.ZLIB, compression_level=6,
        )
        wn_ds.write(np.ascontiguousarray(self.wavenumbers, dtype=np.float64))

    @classmethod
    def read_from(cls, study_group) -> "IRImage | None":
        """Read an IR image cube from a study group; return None if absent.

        Accepts both native-double (written by this class) and legacy
        string forms for ``pixel_size_x/y`` and ``resolution_cm_inv``.
        """
        if not study_group.has_child("ir_image_cube"):
            return None
        ic = study_group.open_group("ir_image_cube")
        width = int(ic.get_attribute("width"))
        height = int(ic.get_attribute("height"))
        spectral_points = int(ic.get_attribute("spectral_points"))
        pixel_size_x = (_parse_double_attr(ic.get_attribute("pixel_size_x"))
                        if ic.has_attribute("pixel_size_x") else 0.0)
        pixel_size_y = (_parse_double_attr(ic.get_attribute("pixel_size_y"))
                        if ic.has_attribute("pixel_size_y") else 0.0)
        scan_pattern = (ic.get_attribute("scan_pattern")
                        if ic.has_attribute("scan_pattern") else "")
        ir_mode_raw = (ic.get_attribute("ir_mode")
                       if ic.has_attribute("ir_mode") else 0)
        try:
            ir_mode_int = int(ir_mode_raw)
        except (TypeError, ValueError):
            ir_mode_int = int(str(ir_mode_raw))
        mode = IRMode(ir_mode_int) if ir_mode_int in (0, 1) else IRMode.TRANSMITTANCE
        resolution_cm_inv = (
            _parse_double_attr(ic.get_attribute("resolution_cm_inv"))
            if ic.has_attribute("resolution_cm_inv") else 0.0
        )

        intensity_raw = np.asarray(ic.open_dataset("intensity").read())
        intensity = intensity_raw.reshape(height, width, spectral_points)
        wavenumbers = np.asarray(ic.open_dataset("wavenumbers").read(), dtype=np.float64)

        return cls(
            width=width, height=height, spectral_points=spectral_points,
            pixel_size_x=pixel_size_x, pixel_size_y=pixel_size_y,
            intensity=intensity, wavenumbers=wavenumbers,
            scan_pattern=scan_pattern,
            mode=mode, resolution_cm_inv=resolution_cm_inv,
        )


__all__ = ["IRImage"]
