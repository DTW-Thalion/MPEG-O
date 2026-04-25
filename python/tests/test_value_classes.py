"""Tests for the pure value classes and enums."""
from __future__ import annotations

import pytest

from ttio import (
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
from ttio.enums import AcquisitionMode, ChromatogramType, EncryptionLevel


def test_enum_integer_values_match_objc() -> None:
    """Fixtures store acquisition_mode as int64; the numeric values must
    agree with TTIOEnums.h or the disk round-trip fails silently."""
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
    from ttio.enums import ByteOrder
    e = EncodingSpec()
    assert e.precision is Precision.FLOAT64
    assert e.compression is Compression.ZLIB
    assert e.byte_order is ByteOrder.LITTLE_ENDIAN


def test_instrument_config_all_empty_by_default() -> None:
    i = InstrumentConfig()
    for field in ("manufacturer", "model", "serial_number", "source_type",
                  "analyzer_type", "detector_type"):
        assert getattr(i, field) == ""


def test_verifier_status_wrapping():
    from ttio.verifier import Verifier, VerificationStatus
    from ttio import signatures

    data = b"hello, ttio"
    key = b"0" * 32

    # NOT_SIGNED
    assert Verifier.verify(data, None, key) == VerificationStatus.NOT_SIGNED
    assert Verifier.verify(data, "", key) == VerificationStatus.NOT_SIGNED

    # VALID (construct a legitimate v2 signature)
    sig = "v2:" + signatures.hmac_sha256_b64(data, key)
    assert Verifier.verify(data, sig, key) == VerificationStatus.VALID

    # INVALID (wrong key)
    wrong_key = b"1" * 32
    assert Verifier.verify(data, sig, wrong_key) == VerificationStatus.INVALID


def test_compression_includes_numpress_delta():
    from ttio.enums import Compression
    assert Compression.NUMPRESS_DELTA.value == 3


def test_byte_order_enum_exists():
    from ttio.enums import ByteOrder
    assert ByteOrder.LITTLE_ENDIAN.value == 0
    assert ByteOrder.BIG_ENDIAN.value == 1

def test_value_range_span_and_contains():
    from ttio.value_range import ValueRange
    r = ValueRange(0.0, 10.0)
    assert r.span == 10.0
    assert r.contains(5.0)
    assert not r.contains(-1.0)


def test_axis_descriptor_has_value_range():
    from ttio.axis_descriptor import AxisDescriptor
    from ttio.value_range import ValueRange
    from ttio.enums import SamplingMode

    a = AxisDescriptor(
        name="mz",
        unit="m/z",
        value_range=ValueRange(100.0, 1000.0),
        sampling_mode=SamplingMode.NON_UNIFORM,
    )
    assert a.value_range == ValueRange(100.0, 1000.0)
    assert a.sampling_mode is SamplingMode.NON_UNIFORM


def test_encoding_spec_uses_byte_order_enum():
    from ttio.encoding_spec import EncodingSpec
    from ttio.enums import Precision, Compression, ByteOrder
    e = EncodingSpec(
        precision=Precision.FLOAT64,
        compression=Compression.ZLIB,
        byte_order=ByteOrder.LITTLE_ENDIAN,
    )
    assert e.byte_order is ByteOrder.LITTLE_ENDIAN


def test_encoding_spec_element_size():
    from ttio.encoding_spec import EncodingSpec
    from ttio.enums import Precision
    assert EncodingSpec(precision=Precision.FLOAT32).element_size() == 4
    assert EncodingSpec(precision=Precision.FLOAT64).element_size() == 8
    assert EncodingSpec(precision=Precision.COMPLEX128).element_size() == 16


def test_cv_param_has_ontology_ref_and_single_unit():
    from ttio.cv_param import CVParam
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
    from ttio.spectrum import Spectrum
    from ttio.signal_array import SignalArray
    from ttio.axis_descriptor import AxisDescriptor
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
    from ttio.mass_spectrum import MassSpectrum
    from ttio.signal_array import SignalArray
    from ttio.enums import Polarity
    from ttio.value_range import ValueRange
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


def test_activation_method_integer_values_match_objc():
    """M74: values persist as int32 in spectrum_index; must match ObjC."""
    from ttio import ActivationMethod
    assert ActivationMethod.NONE == 0
    assert ActivationMethod.CID == 1
    assert ActivationMethod.HCD == 2
    assert ActivationMethod.ETD == 3
    assert ActivationMethod.UVPD == 4
    assert ActivationMethod.ECD == 5
    assert ActivationMethod.EThcD == 6


def test_isolation_window_bounds_and_width():
    from ttio import IsolationWindow
    w = IsolationWindow(target_mz=500.0, lower_offset=1.0, upper_offset=2.0)
    assert w.target_mz == 500.0
    assert w.lower_offset == 1.0
    assert w.upper_offset == 2.0
    assert w.lower_bound == pytest.approx(499.0)
    assert w.upper_bound == pytest.approx(502.0)
    assert w.width == pytest.approx(3.0)


def test_isolation_window_is_frozen():
    from ttio import IsolationWindow
    w = IsolationWindow(target_mz=500.0, lower_offset=1.0, upper_offset=1.0)
    with pytest.raises(Exception):
        w.target_mz = 600.0  # type: ignore[misc]


def test_isolation_window_equality():
    from ttio import IsolationWindow
    a = IsolationWindow(target_mz=500.0, lower_offset=0.5, upper_offset=0.5)
    b = IsolationWindow(target_mz=500.0, lower_offset=0.5, upper_offset=0.5)
    c = IsolationWindow(target_mz=500.0, lower_offset=0.5, upper_offset=1.0)
    assert a == b
    assert a != c
    assert hash(a) == hash(b)


def test_mass_spectrum_has_activation_and_isolation_fields():
    from ttio.mass_spectrum import MassSpectrum
    from ttio.signal_array import SignalArray
    from ttio.enums import ActivationMethod, Polarity
    from ttio.isolation_window import IsolationWindow
    import numpy as np

    mz = SignalArray(data=np.array([100.0, 200.0]))
    intensity = SignalArray(data=np.array([1.0, 2.0]))

    # MS1 defaults: activation_method=NONE, isolation_window=None.
    ms1 = MassSpectrum(signal_arrays={"mz": mz, "intensity": intensity}, axes=[])
    assert ms1.activation_method is ActivationMethod.NONE
    assert ms1.isolation_window is None

    # MS2 populates both fields.
    iw = IsolationWindow(target_mz=500.0, lower_offset=1.0, upper_offset=1.0)
    ms2 = MassSpectrum(
        signal_arrays={"mz": mz, "intensity": intensity},
        axes=[],
        ms_level=2,
        polarity=Polarity.POSITIVE,
        precursor_mz=500.0,
        precursor_charge=2,
        activation_method=ActivationMethod.HCD,
        isolation_window=iw,
    )
    assert ms2.activation_method is ActivationMethod.HCD
    assert ms2.isolation_window is iw
    assert ms2.isolation_window.target_mz == 500.0


def test_signal_array_is_cv_annotatable():
    import numpy as np
    from ttio.signal_array import SignalArray
    from ttio.cv_param import CVParam
    from ttio.protocols import CVAnnotatable

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
    from ttio.nmr_spectrum import NMRSpectrum
    from ttio.signal_array import SignalArray
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
    from ttio.nmr_2d import NMR2DSpectrum
    from ttio.spectrum import Spectrum
    from ttio.axis_descriptor import AxisDescriptor
    from ttio.value_range import ValueRange
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
    from ttio.acquisition_run import SpectrumIndex
    from ttio.value_range import ValueRange
    from ttio.enums import Polarity
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
    from ttio.acquisition_run import AcquisitionRun
    from ttio.enums import AcquisitionMode
    from ttio.protocols import Indexable, Streamable, Provenanceable

    tmp = Path(tempfile.mkstemp(suffix=".h5")[1])
    try:
        with h5py.File(tmp, "w") as f:
            g = f.create_group("run0")
            g.attrs["acquisition_mode"] = np.int64(AcquisitionMode.MS1_DDA)
            g.attrs["spectrum_class"] = "TTIOMassSpectrum"
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
    from ttio.ms_image import MSImage
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


def test_identification_fields():
    from ttio.identification import Identification
    i = Identification(
        run_name="run_0001",
        spectrum_index=42,
        chemical_entity="CHEBI:17234",
        confidence_score=0.95,
        evidence_chain=["MS:1002217", "MS:1001143"],
    )
    assert i.run_name == "run_0001"
    assert i.spectrum_index == 42
    assert i.chemical_entity == "CHEBI:17234"
    assert i.confidence_score == 0.95
    assert i.evidence_chain == ["MS:1002217", "MS:1001143"]


def test_quantification_fields():
    from ttio.quantification import Quantification
    q = Quantification(
        chemical_entity="CHEBI:17234",
        sample_ref="sample1",
        abundance=1234.5,
        normalization_method="median",
    )
    assert q.chemical_entity == "CHEBI:17234"
    assert q.sample_ref == "sample1"
    assert q.abundance == 1234.5
    assert q.normalization_method == "median"


def test_provenance_record_contains_input_ref():
    from ttio.provenance import ProvenanceRecord
    r = ProvenanceRecord(
        timestamp_unix=1700000000,
        software="MSConvert 3.0",
        parameters={"threshold": "100"},
        input_refs=["file:///data/raw/run.mzML"],
        output_refs=["file:///data/processed/run.tio"],
    )
    assert r.contains_input_ref("file:///data/raw/run.mzML")
    assert not r.contains_input_ref("file:///data/raw/other.mzML")


def test_transition_list_count_and_index():
    from ttio.transition_list import Transition, TransitionList
    from ttio.value_range import ValueRange
    t = Transition(
        precursor_mz=500.0, product_mz=100.0, collision_energy=25.0,
        retention_time_window=ValueRange(10.0, 20.0))
    tl = TransitionList(transitions=(t,))
    assert tl.count() == 1
    assert tl.transition_at_index(0) is t
    assert tl.transition_at_index(0).retention_time_window == ValueRange(10.0, 20.0)


def test_access_policy_holds_dict():
    from ttio.access_policy import AccessPolicy
    p = AccessPolicy(policy={"subjects": ["alice"], "key_id": "kek-1"})
    assert p.policy["subjects"] == ["alice"]
    assert p.policy["key_id"] == "kek-1"

    default = AccessPolicy()
    assert default.policy == {}


def test_anonymization_policy_defaults():
    from ttio.anonymization import AnonymizationPolicy
    p = AnonymizationPolicy()  # defaults
    assert hasattr(p, "redact_saav_spectra")
    assert hasattr(p, "mask_intensity_below_quantile")
    assert hasattr(p, "coarsen_mz_decimals")


def test_encryption_round_trip():
    from ttio import encryption

    key = b"0" * 32
    plaintext = b"hello, ttio encryption"
    blob = encryption.encrypt_bytes(plaintext, key)
    recovered = encryption.decrypt_bytes(blob, key)
    assert recovered == plaintext


def test_key_rotation_fresh_manager_has_no_envelope():
    import h5py, tempfile
    from pathlib import Path
    from ttio.key_rotation import has_envelope_encryption

    tmp = Path(tempfile.mkstemp(suffix=".h5")[1])
    try:
        with h5py.File(tmp, "w"):
            pass  # empty file
        with h5py.File(tmp, "r") as f:
            assert not has_envelope_encryption(f)
    finally:
        tmp.unlink(missing_ok=True)


def test_signature_round_trip():
    from ttio import signatures
    import base64

    data = b"hello, ttio signatures"
    key = b"0" * 32
    sig = signatures.hmac_sha256_b64(data, key)
    # Expected: base64(hmac_sha256(data, key))
    assert base64.b64decode(sig) == signatures.hmac_sha256(data, key)


def test_acquisition_run_has_encryptable_surface():
    import h5py
    import numpy as np
    import tempfile
    from pathlib import Path
    from ttio.acquisition_run import AcquisitionRun
    from ttio.access_policy import AccessPolicy
    from ttio.enums import AcquisitionMode
    from ttio.protocols import Encryptable

    tmp = Path(tempfile.mkstemp(suffix=".h5")[1])
    try:
        with h5py.File(tmp, "w") as f:
            g = f.create_group("run0")
            g.attrs["acquisition_mode"] = np.int64(AcquisitionMode.MS1_DDA)
            g.attrs["spectrum_class"] = "TTIOMassSpectrum"
            idx = g.create_group("spectrum_index")
            idx.create_dataset("offsets", data=np.array([0], dtype="<u8"))
            idx.create_dataset("lengths", data=np.array([0], dtype="<u4"))
            idx.create_dataset("retention_times", data=np.array([0.0], dtype="<f8"))
            idx.create_dataset("ms_levels", data=np.array([1], dtype="<i4"))
            idx.create_dataset("polarities", data=np.array([1], dtype="<i4"))
            idx.create_dataset("precursor_mzs", data=np.array([0.0], dtype="<f8"))
            idx.create_dataset("precursor_charges", data=np.array([0], dtype="<i4"))
            idx.create_dataset("base_peak_intensities", data=np.array([0.0], dtype="<f8"))
            sc = g.create_group("signal_channels")
            sc.attrs["channel_names"] = "mz,intensity"
            sc.create_dataset("mz_values", data=np.array([], dtype="<f8"))
            sc.create_dataset("intensity_values", data=np.array([], dtype="<f8"))

        with h5py.File(tmp, "r") as f:
            run = AcquisitionRun.open(f["run0"], name="run0")
            assert isinstance(run, Encryptable)
            assert run.access_policy() is None
            pol = AccessPolicy(policy={"owner": "alice"})
            run.set_access_policy(pol)
            assert run.access_policy() is pol
    finally:
        tmp.unlink(missing_ok=True)


def test_spectral_dataset_has_encryptable_surface():
    from ttio.spectral_dataset import SpectralDataset
    from ttio.protocols import Encryptable
    assert hasattr(SpectralDataset, "encrypt_with_key")
    assert hasattr(SpectralDataset, "decrypt_with_key")
    assert hasattr(SpectralDataset, "access_policy")
    assert hasattr(SpectralDataset, "set_access_policy")
    assert issubclass(SpectralDataset, Encryptable)


def test_query_builder_intersects():
    import numpy as np
    from ttio.acquisition_run import SpectrumIndex
    from ttio.query import Query
    from ttio.value_range import ValueRange
    from ttio.enums import Polarity

    idx = SpectrumIndex(
        offsets=np.array([0, 10, 20, 30], dtype="<u8"),
        lengths=np.array([10, 10, 10, 10], dtype="<u4"),
        retention_times=np.array([1.0, 2.0, 3.0, 4.0], dtype="<f8"),
        ms_levels=np.array([1, 2, 2, 1], dtype="<i4"),
        polarities=np.array([1, 1, -1, 1], dtype="<i4"),
        precursor_mzs=np.array([0.0, 500.0, 510.0, 0.0], dtype="<f8"),
        precursor_charges=np.array([0, 2, 2, 0], dtype="<i4"),
        base_peak_intensities=np.array([100.0, 200.0, 300.0, 400.0], dtype="<f8"),
    )
    matches = (Query.on_index(idx)
               .with_ms_level(2)
               .with_retention_time_range(ValueRange(1.5, 2.5))
               .matching_indices())
    assert matches == [1]

    matches = (Query.on_index(idx)
               .with_polarity(Polarity.NEGATIVE)
               .matching_indices())
    assert matches == [2]


def test_stream_reader_iterates_spectra(tmp_path):
    import h5py
    import numpy as np
    from ttio.stream_reader import StreamReader
    from ttio.enums import AcquisitionMode

    path = str(tmp_path / "minimal.tio")
    with h5py.File(path, "w") as f:
        study = f.create_group("study")
        runs = study.create_group("ms_runs")
        g = runs.create_group("run0")
        g.attrs["acquisition_mode"] = np.int64(AcquisitionMode.MS1_DDA)
        g.attrs["spectrum_class"] = "TTIOMassSpectrum"
        idx = g.create_group("spectrum_index")
        idx.create_dataset("offsets", data=np.array([0, 2], dtype="<u8"))
        idx.create_dataset("lengths", data=np.array([2, 2], dtype="<u4"))
        idx.create_dataset("retention_times", data=np.array([1.0, 2.0], dtype="<f8"))
        idx.create_dataset("ms_levels", data=np.array([1, 1], dtype="<i4"))
        idx.create_dataset("polarities", data=np.array([1, 1], dtype="<i4"))
        idx.create_dataset("precursor_mzs", data=np.array([0.0, 0.0], dtype="<f8"))
        idx.create_dataset("precursor_charges", data=np.array([0, 0], dtype="<i4"))
        idx.create_dataset("base_peak_intensities", data=np.array([10.0, 20.0], dtype="<f8"))
        sc = g.create_group("signal_channels")
        sc.attrs["channel_names"] = "mz,intensity"
        sc.create_dataset("mz_values", data=np.array([100.0, 200.0, 100.0, 200.0], dtype="<f8"))
        sc.create_dataset("intensity_values", data=np.array([1.0, 2.0, 3.0, 4.0], dtype="<f8"))

    with StreamReader(path, "run0") as reader:
        assert reader.total_count == 2
        assert not reader.at_end()
        s0 = reader.next_spectrum()
        assert s0 is not None
        assert reader.current_position == 1
        reader.reset()
        assert reader.current_position == 0


def test_stream_writer_buffers_spectra():
    import numpy as np
    from ttio.stream_writer import StreamWriter
    from ttio.mass_spectrum import MassSpectrum
    from ttio.signal_array import SignalArray
    from ttio.instrument_config import InstrumentConfig
    from ttio.enums import AcquisitionMode

    w = StreamWriter(
        file_path="/tmp/does-not-matter-not-flushed.tio",
        run_name="run0",
        acquisition_mode=AcquisitionMode.MS1_DDA,
        instrument_config=InstrumentConfig(),
    )
    assert w.spectrum_count == 0

    mz = SignalArray(data=np.array([100.0, 200.0]))
    intensity = SignalArray(data=np.array([1.0, 2.0]))
    ms = MassSpectrum(signal_arrays={"mz": mz, "intensity": intensity}, axes=[])
    w.append_spectrum(ms)
    assert w.spectrum_count == 1

    w.close()


def test_provider_registry_discovers_builtin_providers() -> None:
    from ttio.providers import discover_providers

    providers = discover_providers()
    # Two built-in providers must be present.
    assert 'hdf5' in providers
    assert 'memory' in providers


def test_memory_provider_round_trip() -> None:
    from ttio.providers.memory import MemoryProvider
    from ttio.providers.base import StorageProvider

    # MemoryProvider.open() is the entry point (constructor requires
    # internal args); mode='w' creates a fresh in-process store.
    url = 'memory://test-value-classes-smoke'
    p = MemoryProvider.open(url, mode='w')
    assert isinstance(p, StorageProvider)
    assert p.is_open()
    # root_group() is reachable without error.
    root = p.root_group()
    assert root is not None
    p.close()
    assert not p.is_open()
    MemoryProvider.discard_store(url)


# ── M41.8 Task 1: Import/Export subsystem xref parity tests ──────────────────


def test_cv_term_mapper_basic_accessions():
    from ttio.importers import cv_term_mapper as m
    from ttio.enums import Precision
    # MS:1000521 = 32-bit float; MS:1000523 = 64-bit float.
    assert m.precision_for("MS:1000523") == Precision.FLOAT64
    assert m.precision_for("MS:1000521") == Precision.FLOAT32
    # Unknown accession → Float64 sentinel per ObjC spec.
    assert m.precision_for("MS:9999999") == Precision.FLOAT64


def test_base64_zlib_round_trip():
    import base64
    import zlib
    from ttio.importers._base64_zlib import decode
    raw = b"hello ttio base64"
    # Round trip without zlib: encode manually, decode via module.
    encoded_plain = base64.b64encode(raw).decode("ascii")
    assert decode(encoded_plain, zlib_compressed=False) == raw
    # Round trip with zlib: encode manually, decode via module.
    encoded_z = base64.b64encode(zlib.compress(raw)).decode("ascii")
    assert decode(encoded_z, zlib_compressed=True) == raw


def test_stream_writer_flush_round_trip(tmp_path):
    """StreamWriter.flush writes a valid .tio file that can be re-read."""
    import numpy as np
    from ttio.stream_writer import StreamWriter
    from ttio.mass_spectrum import MassSpectrum
    from ttio.signal_array import SignalArray
    from ttio.instrument_config import InstrumentConfig
    from ttio.enums import AcquisitionMode, Polarity
    from ttio import SpectralDataset

    path = tmp_path / "streamed.tio"
    writer = StreamWriter(
        file_path=str(path),
        run_name="run_0001",
        acquisition_mode=AcquisitionMode.MS1_DDA,
        instrument_config=InstrumentConfig(),
    )

    # Append 3 spectra
    for i in range(3):
        mz = SignalArray(data=np.array([100.0 + i, 200.0 + i], dtype="<f8"))
        intensity = SignalArray(data=np.array([1.0 + i, 2.0 + i], dtype="<f8"))
        ms = MassSpectrum(
            signal_arrays={"mz": mz, "intensity": intensity},
            axes=[],
            index_position=i,
            scan_time_seconds=float(i),
            ms_level=1,
            polarity=Polarity.POSITIVE,
        )
        writer.append_spectrum(ms)

    assert writer.spectrum_count == 3
    writer.flush()

    # Re-open and verify
    ds = SpectralDataset.open(str(path))
    try:
        run = ds.ms_runs["run_0001"]
        assert run.count() == 3
    finally:
        ds.close()
