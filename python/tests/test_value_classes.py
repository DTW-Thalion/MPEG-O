"""Tests for the pure value classes and enums."""
from __future__ import annotations

import pytest

from mpeg_o import (
    AxisDescriptor,
    CVParam,
    Compression,
    EncodingSpec,
    InstrumentConfig,
    Polarity,
    Precision,
    SamplingMode,
    ValueRange,
)
from mpeg_o.enums import AcquisitionMode, ChromatogramType, EncryptionLevel


def test_enum_integer_values_match_objc() -> None:
    """Fixtures store acquisition_mode as int64; the numeric values must
    agree with MPGOEnums.h or the disk round-trip fails silently."""
    assert AcquisitionMode.MS1_DDA == 0
    assert AcquisitionMode.NMR_1D == 4
    assert AcquisitionMode.IMAGING == 6
    assert Polarity.POSITIVE == 1
    assert Polarity.NEGATIVE == -1
    assert Polarity.UNKNOWN == 0
    assert Precision.FLOAT64 == 1
    assert Compression.ZLIB == 1
    assert SamplingMode.NON_UNIFORM == 1
    assert ChromatogramType.XIC == 1
    assert EncryptionLevel.DATASET == 2


def test_precision_numpy_dtype_is_little_endian() -> None:
    assert Precision.FLOAT64.numpy_dtype() == "<f8"
    assert Precision.FLOAT32.numpy_dtype() == "<f4"
    assert Precision.UINT32.numpy_dtype() == "<u4"
    assert Precision.COMPLEX128.numpy_dtype() == "<c16"


def test_value_range_contains_and_span() -> None:
    r = ValueRange(100.0, 2000.0)
    assert r.contains(100.0) and r.contains(2000.0) and r.contains(1500.0)
    assert not r.contains(99.9)
    assert r.span == pytest.approx(1900.0)


def test_value_range_is_frozen() -> None:
    r = ValueRange(0.0, 1.0)
    with pytest.raises(Exception):
        r.minimum = -1.0  # type: ignore[misc]


def test_cv_param_defaults() -> None:
    p = CVParam(accession="MS:1000515", name="intensity array")
    assert p.value == ""
    assert p.unit_accession is None


def test_axis_descriptor_default_sampling() -> None:
    a = AxisDescriptor(name="mz", unit="m/z")
    assert a.sampling_mode is SamplingMode.UNIFORM


def test_encoding_spec_defaults() -> None:
    e = EncodingSpec()
    assert e.precision is Precision.FLOAT64
    assert e.compression is Compression.ZLIB
    assert e.compression_level == 6
    assert e.little_endian is True


def test_instrument_config_all_empty_by_default() -> None:
    i = InstrumentConfig()
    for field in ("manufacturer", "model", "serial_number", "source_type",
                  "analyzer_type", "detector_type"):
        assert getattr(i, field) == ""
