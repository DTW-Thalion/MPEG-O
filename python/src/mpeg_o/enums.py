"""Enumerations mirroring the Objective-C ``MPGOEnums.h`` integer values.

All enums are ``IntEnum`` subclasses because every enum in the format
is persisted on disk as an integer attribute (for example
``@acquisition_mode = 0``). Keeping the Python-side values identical
to the Objective-C ``NS_ENUM`` values makes the HDF5 layer a direct
pass-through and removes any translation table to go stale.

Cross-language equivalents
--------------------------
Objective-C: ``MPGOEnums.h`` ·
Java: ``com.dtwthalion.mpgo.Enums``
"""
from __future__ import annotations

from enum import IntEnum


class SamplingMode(IntEnum):
    """Axis sampling regularity.

    Cross-language: ObjC ``MPGOSamplingMode`` · Java
    ``Enums.SamplingMode``.
    """

    UNIFORM = 0
    NON_UNIFORM = 1


class Precision(IntEnum):
    """Numeric precision of a signal buffer.

    Cross-language: ObjC ``MPGOPrecision`` · Java
    ``Enums.Precision``.
    """

    FLOAT32 = 0
    FLOAT64 = 1
    INT32 = 2
    INT64 = 3
    UINT32 = 4
    COMPLEX128 = 5

    def numpy_dtype(self) -> str:
        """Return the little-endian NumPy dtype string for this precision."""
        return {
            Precision.FLOAT32: "<f4",
            Precision.FLOAT64: "<f8",
            Precision.INT32: "<i4",
            Precision.INT64: "<i8",
            Precision.UINT32: "<u4",
            Precision.COMPLEX128: "<c16",
        }[self]


class Compression(IntEnum):
    """Compression algorithm applied to a signal buffer.

    Cross-language: ObjC ``MPGOCompression`` · Java
    ``Enums.Compression``.
    """

    NONE = 0
    ZLIB = 1
    LZ4 = 2
    NUMPRESS_DELTA = 3


class ByteOrder(IntEnum):
    """Byte order of a signal buffer on disk.

    Cross-language: ObjC ``MPGOByteOrder`` · Java
    ``Enums.ByteOrder``.
    """

    LITTLE_ENDIAN = 0
    BIG_ENDIAN = 1


class Polarity(IntEnum):
    """Ion polarity for mass spectrometry.

    Cross-language: ObjC ``MPGOPolarity`` · Java
    ``Enums.Polarity``.
    """

    UNKNOWN = 0
    POSITIVE = 1
    NEGATIVE = -1


class ChromatogramType(IntEnum):
    """Chromatogram kind.

    Cross-language: ObjC ``MPGOChromatogramType`` · Java
    ``Enums.ChromatogramType``.
    """

    TIC = 0
    XIC = 1
    SRM = 2


class AcquisitionMode(IntEnum):
    """High-level acquisition scheme for a run.

    Cross-language: ObjC ``MPGOAcquisitionMode`` · Java
    ``Enums.AcquisitionMode``.
    """

    MS1_DDA = 0
    MS2_DDA = 1
    DIA = 2
    SRM = 3
    NMR_1D = 4
    NMR_2D = 5
    IMAGING = 6


class EncryptionLevel(IntEnum):
    """Multi-level protection granularity (MPEG-G style).

    Cross-language: ObjC ``MPGOEncryptionLevel`` · Java
    ``Enums.EncryptionLevel``.
    """

    NONE = 0
    DATASET_GROUP = 1
    DATASET = 2
    DESCRIPTOR_STREAM = 3
    ACCESS_UNIT = 4
