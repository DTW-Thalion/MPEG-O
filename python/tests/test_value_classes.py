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
    p = CVParam(ontology_ref="MS", accession="MS:1000515", name="intensity array")
    assert p.value == ""
    assert p.unit is None


def test_axis_descriptor_default_sampling() -> None:
    a = AxisDescriptor(name="mz", unit="m/z")
    assert a.sampling_mode is SamplingMode.UNIFORM


def test_encoding_spec_defaults() -> None:
    from mpeg_o.enums import ByteOrder
    e = EncodingSpec()
    assert e.precision is Precision.FLOAT64
    assert e.compression is Compression.ZLIB
    assert e.byte_order is ByteOrder.LITTLE_ENDIAN


def test_instrument_config_all_empty_by_default() -> None:
    i = InstrumentConfig()
    for field in ("manufacturer", "model", "serial_number", "source_type",
                  "analyzer_type", "detector_type"):
        assert getattr(i, field) == ""


def test_compression_includes_numpress_delta():
    from mpeg_o.enums import Compression
    assert Compression.NUMPRESS_DELTA.value == 3


def test_byte_order_enum_exists():
    from mpeg_o.enums import ByteOrder
    assert ByteOrder.LITTLE_ENDIAN.value == 0
    assert ByteOrder.BIG_ENDIAN.value == 1

def test_value_range_span_and_contains():
    from mpeg_o.value_range import ValueRange
    r = ValueRange(0.0, 10.0)
    assert r.span == 10.0
    assert r.contains(5.0)
    assert not r.contains(-1.0)


def test_axis_descriptor_has_value_range():
    from mpeg_o.axis_descriptor import AxisDescriptor
    from mpeg_o.value_range import ValueRange
    from mpeg_o.enums import SamplingMode

    a = AxisDescriptor(
        name="mz",
        unit="m/z",
        value_range=ValueRange(100.0, 1000.0),
        sampling_mode=SamplingMode.NON_UNIFORM,
    )
    assert a.value_range == ValueRange(100.0, 1000.0)
    assert a.sampling_mode is SamplingMode.NON_UNIFORM


def test_encoding_spec_uses_byte_order_enum():
    from mpeg_o.encoding_spec import EncodingSpec
    from mpeg_o.enums import Precision, Compression, ByteOrder
    e = EncodingSpec(
        precision=Precision.FLOAT64,
        compression=Compression.ZLIB,
        byte_order=ByteOrder.LITTLE_ENDIAN,
    )
    assert e.byte_order is ByteOrder.LITTLE_ENDIAN


def test_encoding_spec_element_size():
    from mpeg_o.encoding_spec import EncodingSpec
    from mpeg_o.enums import Precision
    assert EncodingSpec(precision=Precision.FLOAT32).element_size() == 4
    assert EncodingSpec(precision=Precision.FLOAT64).element_size() == 8
    assert EncodingSpec(precision=Precision.COMPLEX128).element_size() == 16


def test_cv_param_has_ontology_ref_and_single_unit():
    from mpeg_o.cv_param import CVParam
    p = CVParam(
        ontology_ref="MS",
        accession="MS:1000515",
        name="intensity array",
        value="",
        unit="MS:1000131",
    )
    assert p.ontology_ref == "MS"
    assert p.accession == "MS:1000515"
    assert p.unit == "MS:1000131"


def test_spectrum_base_fields_match_objc():
    from mpeg_o.spectrum import Spectrum
    from mpeg_o.signal_array import SignalArray
    from mpeg_o.axis_descriptor import AxisDescriptor
    import numpy as np

    mz = SignalArray(data=np.array([100.0, 200.0]))
    intensity = SignalArray(data=np.array([1.0, 2.0]))
    s = Spectrum(
        signal_arrays={"mz": mz, "intensity": intensity},
        axes=[AxisDescriptor(name="mz", unit="m/z")],
        index_position=3,
        scan_time_seconds=45.2,
        precursor_mz=500.0,
        precursor_charge=2,
    )
    assert s.signal_arrays["mz"] is mz
    assert s.axes[0].name == "mz"
    assert s.index_position == 3
    assert s.scan_time_seconds == 45.2
    assert s.precursor_mz == 500.0
    assert s.precursor_charge == 2
    assert not hasattr(s, "ms_level")
    assert not hasattr(s, "polarity")
    assert not hasattr(s, "base_peak_intensity")
    assert not hasattr(s, "channels")
    assert not hasattr(s, "retention_time")
    assert not hasattr(s, "run_name")


def test_mass_spectrum_has_typed_fields():
    from mpeg_o.mass_spectrum import MassSpectrum
    from mpeg_o.signal_array import SignalArray
    from mpeg_o.enums import Polarity
    from mpeg_o.value_range import ValueRange
    import numpy as np

    mz = SignalArray(data=np.array([100.0, 200.0]))
    intensity = SignalArray(data=np.array([1.0, 2.0]))
    ms = MassSpectrum(
        signal_arrays={"mz": mz, "intensity": intensity},
        axes=[],
        index_position=0,
        scan_time_seconds=10.0,
        precursor_mz=500.0,
        precursor_charge=2,
        ms_level=2,
        polarity=Polarity.POSITIVE,
        scan_window=ValueRange(50.0, 2000.0),
    )
    assert ms.ms_level == 2
    assert ms.polarity is Polarity.POSITIVE
    assert ms.scan_window == ValueRange(50.0, 2000.0)
    assert isinstance(ms.mz_array, SignalArray)
    assert isinstance(ms.intensity_array, SignalArray)
    # Fields that should NOT be on MassSpectrum:
    assert not hasattr(ms, "base_peak_intensity")
    assert not hasattr(ms, "run_name")


def test_signal_array_is_cv_annotatable():
    import numpy as np
    from mpeg_o.signal_array import SignalArray
    from mpeg_o.cv_param import CVParam
    from mpeg_o.protocols import CVAnnotatable

    sa = SignalArray(data=np.array([1.0, 2.0, 3.0]), axis=None)
    param = CVParam(
        ontology_ref="MS", accession="MS:1000515",
        name="intensity array", value="", unit=None)
    sa.add_cv_param(param)
    assert sa.all_cv_params() == [param]
    assert sa.has_cv_param_with_accession("MS:1000515")
    assert sa.cv_params_for_accession("MS:1000515") == [param]
    assert sa.cv_params_for_ontology_ref("MS") == [param]
    sa.remove_cv_param(param)
    assert sa.all_cv_params() == []
    assert isinstance(sa, CVAnnotatable)


def test_nmr_spectrum_has_nucleus_type_and_frequency():
    from mpeg_o.nmr_spectrum import NMRSpectrum
    from mpeg_o.signal_array import SignalArray
    import numpy as np

    cs = SignalArray(data=np.array([1.0, 2.0, 3.0]))
    intensity = SignalArray(data=np.array([0.1, 0.2, 0.3]))
    nmr = NMRSpectrum(
        signal_arrays={"chemical_shift": cs, "intensity": intensity},
        axes=[],
        index_position=0,
        scan_time_seconds=0.0,
        nucleus_type="1H",
        spectrometer_frequency_mhz=400.0,
    )
    assert nmr.nucleus_type == "1H"
    assert nmr.spectrometer_frequency_mhz == 400.0
    assert isinstance(nmr.chemical_shift_array, SignalArray)
    assert not hasattr(nmr, "run_name")
    assert not hasattr(nmr, "nucleus")  # old name gone


def test_nmr_2d_uses_axis_descriptors_and_inherits_spectrum():
    from mpeg_o.nmr_2d import NMR2DSpectrum
    from mpeg_o.spectrum import Spectrum
    from mpeg_o.axis_descriptor import AxisDescriptor
    from mpeg_o.value_range import ValueRange
    import numpy as np

    f1 = AxisDescriptor(name="1H", unit="ppm", value_range=ValueRange(0.0, 10.0))
    f2 = AxisDescriptor(name="13C", unit="ppm", value_range=ValueRange(0.0, 200.0))
    matrix = np.zeros((10, 20))
    spec = NMR2DSpectrum(
        intensity_matrix=matrix,
        f1_axis=f1,
        f2_axis=f2,
        nucleus_f1="1H",
        nucleus_f2="13C",
    )
    assert isinstance(spec, Spectrum)
    assert spec.f1_axis is f1
    assert spec.f2_axis is f2
    assert spec.matrix_height == 10
    assert spec.matrix_width == 20


def test_spectrum_index_element_accessors():
    from mpeg_o.acquisition_run import SpectrumIndex
    from mpeg_o.value_range import ValueRange
    from mpeg_o.enums import Polarity
    import numpy as np

    idx = SpectrumIndex(
        offsets=np.array([0, 10, 20], dtype="<u8"),
        lengths=np.array([10, 10, 10], dtype="<u4"),
        retention_times=np.array([1.0, 2.0, 3.0], dtype="<f8"),
        ms_levels=np.array([1, 2, 1], dtype="<i4"),
        polarities=np.array([1, 1, -1], dtype="<i4"),
        precursor_mzs=np.array([0.0, 500.0, 0.0], dtype="<f8"),
        precursor_charges=np.array([0, 2, 0], dtype="<i4"),
        base_peak_intensities=np.array([100.0, 200.0, 300.0], dtype="<f8"),
    )
    assert idx.offset_at(1) == 10
    assert idx.length_at(2) == 10
    assert idx.retention_time_at(0) == 1.0
    assert idx.ms_level_at(1) == 2
    assert idx.polarity_at(2) is Polarity.NEGATIVE
    assert idx.precursor_mz_at(1) == 500.0
    assert idx.precursor_charge_at(1) == 2
    assert idx.base_peak_intensity_at(2) == 300.0

    assert idx.indices_in_retention_time_range(ValueRange(1.5, 2.5)) == [1]
    assert idx.indices_for_ms_level(1) == [0, 2]


def test_acquisition_run_conforms_to_protocols():
    import h5py
    import numpy as np
    import tempfile
    from pathlib import Path
    from mpeg_o.acquisition_run import AcquisitionRun
    from mpeg_o.enums import AcquisitionMode
    from mpeg_o.protocols import Indexable, Streamable, Provenanceable

    tmp = Path(tempfile.mkstemp(suffix=".h5")[1])
    try:
        with h5py.File(tmp, "w") as f:
            g = f.create_group("run0")
            g.attrs["acquisition_mode"] = np.int64(AcquisitionMode.MS1_DDA)
            g.attrs["spectrum_class"] = "MPGOMassSpectrum"
            idx = g.create_group("spectrum_index")
            idx.create_dataset("offsets", data=np.array([0, 2], dtype="<u8"))
            idx.create_dataset("lengths", data=np.array([2, 2], dtype="<u4"))
            idx.create_dataset("retention_times", data=np.array([0.0, 1.0], dtype="<f8"))
            idx.create_dataset("ms_levels", data=np.array([1, 1], dtype="<i4"))
            idx.create_dataset("polarities", data=np.array([1, 1], dtype="<i4"))
            idx.create_dataset("precursor_mzs", data=np.array([0.0, 0.0], dtype="<f8"))
            idx.create_dataset("precursor_charges", data=np.array([0, 0], dtype="<i4"))
            idx.create_dataset("base_peak_intensities", data=np.array([10.0, 20.0], dtype="<f8"))
            sc = g.create_group("signal_channels")
            sc.attrs["channel_names"] = "mz,intensity"
            sc.create_dataset("mz_values", data=np.array([100.0, 200.0, 100.0, 200.0], dtype="<f8"))
            sc.create_dataset("intensity_values", data=np.array([1.0, 2.0, 3.0, 4.0], dtype="<f8"))

        with h5py.File(tmp, "r") as f:
            run = AcquisitionRun.open(f["run0"], name="run0")

            assert isinstance(run, Indexable)
            assert run.count() == 2
            assert run.object_at_index(0) is not None

            assert isinstance(run, Streamable)
            assert run.has_more()
            s0 = run.next_object()
            assert s0 is not None
            assert run.current_position() == 1
            run.reset()
            assert run.current_position() == 0

            assert isinstance(run, Provenanceable)
            assert run.provenance_chain() == []
            assert run.input_entities() == []
            assert run.output_entities() == []
    finally:
        tmp.unlink(missing_ok=True)


def test_ms_image_has_dataset_level_fields():
    from mpeg_o.ms_image import MSImage
    import numpy as np

    img = MSImage(
        width=2, height=2, spectral_points=3,
        intensity=np.zeros((2, 2, 3)),
        tile_size=64,
        title="imaging run",
        isa_investigation_id="ISA-001",
    )
    assert img.title == "imaging run"
    assert img.isa_investigation_id == "ISA-001"
    assert img.identifications == []
    assert img.quantifications == []
    assert img.provenance_records == []
    assert img.tile_size == 64
