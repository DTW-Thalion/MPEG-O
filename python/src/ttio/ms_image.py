"""``MSImage`` — mass-spectrometry imaging cube."""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np


@dataclass(slots=True)
class MSImage:
    """Mass-spectrometry imaging dataset: a ``width x height`` grid of
    pixels, each pixel a spectral profile of ``spectral_points`` values.

    Parameters
    ----------
    width, height : int, default 0
        Image grid dimensions in pixels.
    spectral_points : int, default 0
        Number of float64 values per pixel.
    intensity : numpy.ndarray, default empty rank-3 array
        Rank-3 intensity cube of shape ``(height, width, spectral_points)``.
    mz_axis : numpy.ndarray, default empty 1-D array
        1-D float64 array of length ``spectral_points`` giving the m/z
        calibration for each spectral bin.  Empty when the file was
        written before format v1.2 (legacy files); use
        :meth:`to_pixel_spectra` only when this is populated.
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
        Dataset-level identifications (composed -- see Notes).
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
    Objective-C: ``TTIOMSImage`` - Java:
    ``global.thalion.ttio.MSImage``.
    """

    width: int = 0
    height: int = 0
    spectral_points: int = 0
    pixel_size_x: float = 0.0
    pixel_size_y: float = 0.0
    intensity: np.ndarray = field(default_factory=lambda: np.zeros((0, 0, 0)))
    mz_axis: np.ndarray = field(default_factory=lambda: np.zeros(0))
    scan_pattern: str = ""
    tile_size: int = 0

    # Dataset-level composition fields (ObjC inherits from TTIOSpectralDataset)
    title: str = ""
    isa_investigation_id: str = ""
    identifications: list = field(default_factory=list)
    quantifications: list = field(default_factory=list)
    provenance_records: list = field(default_factory=list)

    def __post_init__(self) -> None:
        if self.width == 0 and self.height == 0 and self.spectral_points == 0 and self.mz_axis.size == 0:
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
        if self.mz_axis.size > 0:
            if self.mz_axis.ndim != 1 or self.mz_axis.shape[0] != self.spectral_points:
                raise ValueError(
                    f"mz_axis shape {self.mz_axis.shape} does not match "
                    f"spectral_points={self.spectral_points}"
                )

    def write_to(self, study_group) -> None:
        """Write this image cube under ``<study_group>/image_cube/``.

        Mirrors :meth:`global.thalion.ttio.MSImage.writeTo` -- intensity
        as a 3-D ``[h, w, sp]`` dataset, optional ``mz_axis`` 1-D
        dataset when populated.
        """
        from ttio.enums import Compression, Precision
        ic = study_group.create_group("image_cube")
        ic.set_attribute("width", int(self.width))
        ic.set_attribute("height", int(self.height))
        ic.set_attribute("spectral_points", int(self.spectral_points))
        ic.set_attribute("pixel_size_x", float(self.pixel_size_x))
        ic.set_attribute("pixel_size_y", float(self.pixel_size_y))
        ic.set_attribute("scan_pattern", self.scan_pattern)

        intensity_ds = ic.create_dataset_nd(
            "intensity", Precision.FLOAT64,
            shape=(self.height, self.width, self.spectral_points),
            chunks=(1, 1, self.spectral_points),
            compression=Compression.ZLIB, compression_level=6,
        )
        intensity_ds.write(np.ascontiguousarray(self.intensity, dtype=np.float64))

        if self.mz_axis.size > 0:
            axis_ds = ic.create_dataset_nd(
                "mz_axis", Precision.FLOAT64,
                shape=(self.spectral_points,),
                chunks=(self.spectral_points,),
                compression=Compression.ZLIB, compression_level=6,
            )
            axis_ds.write(np.ascontiguousarray(self.mz_axis, dtype=np.float64))

    @classmethod
    def read_from(cls, study_group) -> "MSImage | None":
        """Read an MSImage cube from a study group; return None if absent."""
        if not study_group.has_child("image_cube"):
            return None
        ic = study_group.open_group("image_cube")
        width = int(ic.get_attribute("width"))
        height = int(ic.get_attribute("height"))
        spectral_points = int(ic.get_attribute("spectral_points"))
        pixel_size_x = (float(ic.get_attribute("pixel_size_x"))
                         if ic.has_attribute("pixel_size_x") else 0.0)
        pixel_size_y = (float(ic.get_attribute("pixel_size_y"))
                         if ic.has_attribute("pixel_size_y") else 0.0)
        scan_pattern = (ic.get_attribute("scan_pattern")
                         if ic.has_attribute("scan_pattern") else "")

        intensity_raw = np.asarray(ic.open_dataset("intensity").read())
        intensity = intensity_raw.reshape(height, width, spectral_points)

        if ic.has_child("mz_axis"):
            mz_axis = np.asarray(ic.open_dataset("mz_axis").read(), dtype=np.float64)
        else:
            mz_axis = np.zeros(0)

        return cls(
            width=width, height=height, spectral_points=spectral_points,
            pixel_size_x=pixel_size_x, pixel_size_y=pixel_size_y,
            intensity=intensity, mz_axis=mz_axis, scan_pattern=scan_pattern,
        )

    def to_pixel_spectra(self):
        """Project this image as a list of continuous-mode pixel records.

        Returns a list of :class:`ttio.importers.imzml.ImzMLPixelSpectrum`
        objects, one per pixel, all sharing :attr:`mz_axis` as their
        ``mz`` array.

        Raises ``RuntimeError`` when ``mz_axis`` is empty (legacy file).
        """
        if self.mz_axis.size == 0:
            raise RuntimeError(
                "MSImage has no mz_axis; cannot project to imzML pixels. "
                "The .tio was written before format v1.2 added the spectral "
                "axis. Re-import from a source format that carries m/z "
                "calibration (imzML, mzML), or supply mz_axis explicitly."
            )
        from ttio.importers.imzml import ImzMLPixelSpectrum
        pixels = []
        for row in range(self.height):
            for col in range(self.width):
                pixels.append(ImzMLPixelSpectrum(
                    x=col, y=row, z=1,
                    mz=self.mz_axis,
                    intensity=self.intensity[row, col],
                ))
        return pixels


__all__ = ["MSImage"]
