"""``EncodingSpec`` — storage precision, compression, byte order pairing."""
from __future__ import annotations

from dataclasses import dataclass

from .enums import Compression, Precision


@dataclass(frozen=True, slots=True)
class EncodingSpec:
    """Bundles the storage traits of a signal channel.

    Mirrors the ObjC ``MPGOEncodingSpec`` value class. Byte order is always
    little-endian on disk; the field is kept for API symmetry with the ObjC
    implementation and for future canonical-signature work (M18).
    """

    precision: Precision = Precision.FLOAT64
    compression: Compression = Compression.ZLIB
    compression_level: int = 6
    little_endian: bool = True
