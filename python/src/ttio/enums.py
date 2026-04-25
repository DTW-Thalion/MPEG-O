"""Enumerations mirroring the Objective-C ``TTIOEnums.h`` integer values.

All enums are ``IntEnum`` subclasses because every enum in the format
is persisted on disk as an integer attribute (for example
``@acquisition_mode = 0``). Keeping the Python-side values identical
to the Objective-C ``NS_ENUM`` values makes the HDF5 layer a direct
pass-through and removes any translation table to go stale.

Cross-language equivalents
--------------------------
Objective-C: ``TTIOEnums.h`` ·
Java: ``global.thalion.ttio.Enums``
"""
from __future__ import annotations

from enum import IntEnum


class SamplingMode(IntEnum):
    """Axis sampling regularity.

    Cross-language: ObjC ``TTIOSamplingMode`` · Java
    ``Enums.SamplingMode``.
    """

    UNIFORM = 0
    NON_UNIFORM = 1


class Precision(IntEnum):
    """Numeric precision of a signal buffer.

    Cross-language: ObjC ``TTIOPrecision`` · Java
    ``Enums.Precision``.

    Appendix B Gap 7: ``Precision`` is a pure enum. The HDF5 type
    mapping (``H5T_NATIVE_DOUBLE`` &c.) lives in
    ``ttio.providers.hdf5`` so non-HDF5 providers (SQLite, Memory,
    future Zarr) can import ``Precision`` without pulling HDF5
    dependencies onto their classpath. See v0.6.1 Appendix B gap 7
    in ``docs/api-review-v0.6.md`` for the motivating bug.
    """

    FLOAT32 = 0
    FLOAT64 = 1
    INT32 = 2
    INT64 = 3
    UINT32 = 4
    COMPLEX128 = 5
    UINT8 = 6           # v0.11 M79: genomic quality scores + packed bases
    UINT64 = 9          # v0.11 M82: genomic index offsets (byte offsets into signal channels)

    def numpy_dtype(self) -> str:
        """Return the little-endian NumPy dtype string for this precision."""
        return {
            Precision.FLOAT32: "<f4",
            Precision.FLOAT64: "<f8",
            Precision.INT32: "<i4",
            Precision.INT64: "<i8",
            Precision.UINT32: "<u4",
            Precision.COMPLEX128: "<c16",
            Precision.UINT8: "u1",
            Precision.UINT64: "<u8",
        }[self]


class Compression(IntEnum):
    """Compression algorithm applied to a signal buffer.

    Cross-language: ObjC ``TTIOCompression`` · Java
    ``Enums.Compression``.
    """

    NONE = 0
    ZLIB = 1
    LZ4 = 2
    NUMPRESS_DELTA = 3
    # v0.11 M79: genomic codecs (clean-room implementations land in M75+).
    RANS_ORDER0 = 4
    RANS_ORDER1 = 5
    BASE_PACK = 6
    QUALITY_BINNED = 7
    NAME_TOKENIZED = 8


class ByteOrder(IntEnum):
    """Byte order of a signal buffer on disk.

    Cross-language: ObjC ``TTIOByteOrder`` · Java
    ``Enums.ByteOrder``.
    """

    LITTLE_ENDIAN = 0
    BIG_ENDIAN = 1


class Polarity(IntEnum):
    """Ion polarity for mass spectrometry.

    Cross-language: ObjC ``TTIOPolarity`` · Java
    ``Enums.Polarity``.
    """

    UNKNOWN = 0
    POSITIVE = 1
    NEGATIVE = -1


class ChromatogramType(IntEnum):
    """Chromatogram kind.

    Cross-language: ObjC ``TTIOChromatogramType`` · Java
    ``Enums.ChromatogramType``.
    """

    TIC = 0
    XIC = 1
    SRM = 2


class AcquisitionMode(IntEnum):
    """High-level acquisition scheme for a run.

    Cross-language: ObjC ``TTIOAcquisitionMode`` · Java
    ``Enums.AcquisitionMode``.
    """

    MS1_DDA = 0
    MS2_DDA = 1
    DIA = 2
    SRM = 3
    NMR_1D = 4
    NMR_2D = 5
    IMAGING = 6
    GENOMIC_WGS = 7   # v0.11 M79: whole-genome sequencing
    GENOMIC_WES = 8   # v0.11 M79: whole-exome sequencing


class IRMode(IntEnum):
    """Infrared y-axis interpretation.

    Cross-language: ObjC ``TTIOIRMode`` · Java
    ``Enums.IRMode``.
    """

    TRANSMITTANCE = 0
    ABSORBANCE = 1


class EncryptionLevel(IntEnum):
    """Multi-level protection granularity (MPEG-G style).

    Cross-language: ObjC ``TTIOEncryptionLevel`` · Java
    ``Enums.EncryptionLevel``.
    """

    NONE = 0
    DATASET_GROUP = 1
    DATASET = 2
    DESCRIPTOR_STREAM = 3
    ACCESS_UNIT = 4


class ActivationMethod(IntEnum):
    """MS/MS precursor activation (dissociation) method.

    Stored as ``int32`` in the optional ``activation_methods`` column of
    ``spectrum_index`` (see ``opt_ms2_activation_detail``). ``NONE`` is
    the sentinel for MS1 scans and for MS2+ scans whose activation method
    was not reported by the source instrument.

    Cross-language: ObjC ``TTIOActivationMethod`` · Java
    ``Enums.ActivationMethod``.
    """

    NONE = 0
    CID = 1
    HCD = 2
    ETD = 3
    UVPD = 4
    ECD = 5
    EThcD = 6
