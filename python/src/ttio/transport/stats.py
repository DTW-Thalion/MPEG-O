"""Per-AccessUnit summary statistics (no payload decoding)."""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any

from .packets import AccessUnit

_SPECTRUM_CLASS_MS_IMAGE_PIXEL = 4
_SPECTRUM_CLASS_GENOMIC_READ = 5


@dataclass(frozen=True, slots=True)
class AUStats:
    """Lightweight per-AU descriptor — every field is derivable from
    an :class:`AccessUnit` without decoding signal-channel payload.
    Used by the workbench server's ``stats-only`` and
    ``stats-with-payload`` download modes.

    Cross-language equivalents:
      * Objective-C: ``TTIOAUStats``
      * Java:       ``global.thalion.ttio.transport.AUStats``

    The :meth:`json_string` form is byte-stable across languages
    (sorted keys, no whitespace).
    """

    au_sequence: int
    spectrum_class: int
    ms_level: int
    polarity: int
    retention_time: float
    precursor_mz: float
    precursor_charge: int
    ion_mobility: float
    base_peak_intensity: float
    channel_count: int
    total_elements: int
    payload_bytes: int
    chromosome: str | None = None
    position: int = 0
    mapping_quality: int = 0
    flags: int = 0
    pixel_x: int = 0
    pixel_y: int = 0
    pixel_z: int = 0

    @classmethod
    def from_access_unit(cls, au: AccessUnit, au_sequence: int) -> "AUStats":
        total_elements = sum(c.n_elements for c in au.channels)
        payload_bytes = sum(len(c.data) for c in au.channels)
        chromosome: str | None = None
        position = 0
        mapping_quality = 0
        flags = 0
        if au.spectrum_class == _SPECTRUM_CLASS_GENOMIC_READ:
            chromosome = au.chromosome or ""
            position = au.position
            mapping_quality = au.mapping_quality
            flags = au.flags
        pixel_x = pixel_y = pixel_z = 0
        if au.spectrum_class == _SPECTRUM_CLASS_MS_IMAGE_PIXEL:
            pixel_x = au.pixel_x
            pixel_y = au.pixel_y
            pixel_z = au.pixel_z
        return cls(
            au_sequence=int(au_sequence),
            spectrum_class=int(au.spectrum_class),
            ms_level=int(au.ms_level),
            polarity=int(au.polarity),
            retention_time=float(au.retention_time),
            precursor_mz=float(au.precursor_mz),
            precursor_charge=int(au.precursor_charge),
            ion_mobility=float(au.ion_mobility),
            base_peak_intensity=float(au.base_peak_intensity),
            channel_count=int(len(au.channels)),
            total_elements=int(total_elements),
            payload_bytes=int(payload_bytes),
            chromosome=chromosome,
            position=int(position),
            mapping_quality=int(mapping_quality),
            flags=int(flags),
            pixel_x=int(pixel_x),
            pixel_y=int(pixel_y),
            pixel_z=int(pixel_z),
        )

    def to_dict(self) -> dict[str, Any]:
        """Mirrors :class:`TTIOAUStats` JSON shape: genomic and
        image keys appear only for their respective spectrum
        classes; all other keys are always present."""
        d: dict[str, Any] = {
            "au_sequence": self.au_sequence,
            "spectrum_class": self.spectrum_class,
            "ms_level": self.ms_level,
            "polarity": self.polarity,
            "retention_time": self.retention_time,
            "precursor_mz": self.precursor_mz,
            "precursor_charge": self.precursor_charge,
            "ion_mobility": self.ion_mobility,
            "base_peak_intensity": self.base_peak_intensity,
            "channel_count": self.channel_count,
            "total_elements": self.total_elements,
            "payload_bytes": self.payload_bytes,
        }
        if self.spectrum_class == _SPECTRUM_CLASS_GENOMIC_READ:
            d["chromosome"] = self.chromosome or ""
            d["position"] = self.position
            d["mapping_quality"] = self.mapping_quality
            d["flags"] = self.flags
        if self.spectrum_class == _SPECTRUM_CLASS_MS_IMAGE_PIXEL:
            d["pixel_x"] = self.pixel_x
            d["pixel_y"] = self.pixel_y
            d["pixel_z"] = self.pixel_z
        return d

    def json_string(self) -> str:
        """Byte-stable JSON: sorted keys, no spaces. Matches the
        ObjC ``NSJSONWritingSortedKeys`` output and Java
        ``JsonOrderedSerializer`` output."""
        return json.dumps(self.to_dict(), sort_keys=True, separators=(",", ":"))

    @classmethod
    def json_string_for(cls, au: AccessUnit, au_sequence: int) -> str:
        return cls.from_access_unit(au, au_sequence).json_string()
