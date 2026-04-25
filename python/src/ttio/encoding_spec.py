"""``EncodingSpec`` — storage precision, compression, byte order."""
from __future__ import annotations

from dataclasses import dataclass

from .enums import ByteOrder, Compression, Precision


_ELEMENT_SIZE: dict[Precision, int] = {
    Precision.FLOAT32: 4,
    Precision.FLOAT64: 8,
    Precision.INT32: 4,
    Precision.INT64: 8,
    Precision.UINT32: 4,
    Precision.COMPLEX128: 16,
    Precision.UINT8: 1,
}


@dataclass(frozen=True, slots=True)
class EncodingSpec:
    """Describes how a signal buffer is encoded on disk.

    Immutable value class pairing numeric precision, compression
    algorithm, and byte order.

    Parameters
    ----------
    precision : Precision, default Precision.FLOAT64
        Numeric precision of each sample.
    compression : Compression, default Compression.ZLIB
        Compression algorithm.
    byte_order : ByteOrder, default ByteOrder.LITTLE_ENDIAN
        Byte order on disk.

    Notes
    -----
    API status: Stable.

    The HDF5 compression level (0-9 for zlib) is a
    provider-configuration concern and lives on
    :class:`~ttio.providers.hdf5.Hdf5Provider` via
    ``create_dataset(compression_level=...)``, not on this value
    class.

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIOEncodingSpec`` · Java:
    ``global.thalion.ttio.EncodingSpec``.
    """

    precision: Precision = Precision.FLOAT64
    compression: Compression = Compression.ZLIB
    byte_order: ByteOrder = ByteOrder.LITTLE_ENDIAN

    def element_size(self) -> int:
        """Return the size in bytes of one element at this precision."""
        return _ELEMENT_SIZE[self.precision]
