"""Enumerations mirroring the Objective-C ``MPGOEnums.h`` integer values.

All enums are ``IntEnum`` subclasses because every enum in the format is
persisted on disk as an integer attribute (for example
``@acquisition_mode = 0``). Keeping the Python-side values identical to the
Objective-C ``NS_ENUM`` values makes the HDF5 layer a direct pass-through and
removes any translation table to go stale.
"""
from __future__ import annotations

from enum import IntEnum


class SamplingMode(IntEnum):
    UNIFORM = 0
    NON_UNIFORM = 1


class Precision(IntEnum):
    FLOAT32 = 0
    FLOAT64 = 1
    INT32 = 2
    INT64 = 3
    UINT32 = 4
    COMPLEX128 = 5

    def numpy_dtype(self) -> str:
        return {
            Precision.FLOAT32: "<f4",
            Precision.FLOAT64: "<f8",
            Precision.INT32: "<i4",
            Precision.INT64: "<i8",
            Precision.UINT32: "<u4",
            Precision.COMPLEX128: "<c16",
        }[self]


class Compression(IntEnum):
    NONE = 0
    ZLIB = 1
    LZ4 = 2


class Polarity(IntEnum):
    UNKNOWN = 0
    POSITIVE = 1
    NEGATIVE = -1


class ChromatogramType(IntEnum):
    TIC = 0
    XIC = 1
    SRM = 2


class AcquisitionMode(IntEnum):
    MS1_DDA = 0
    MS2_DDA = 1
    DIA = 2
    SRM = 3
    NMR_1D = 4
    NMR_2D = 5
    IMAGING = 6


class EncryptionLevel(IntEnum):
    NONE = 0
    DATASET_GROUP = 1
    DATASET = 2
    DESCRIPTOR_STREAM = 3
    ACCESS_UNIT = 4
