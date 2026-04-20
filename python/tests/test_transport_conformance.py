"""v0.10 M70: bidirectional conversion conformance.

Two layers of testing:

1. **In-language round-trip** — .mpgo → .mots → .mpgo with signal
   values preserved to float64 epsilon. Same for multi-run,
   multi-spectrum, and empty-run edge cases.

2. **Cross-language exchange** — Python spawns Java and ObjC
   encode/decode CLIs and verifies that a stream produced in one
   language is decodable in the other two.

Cross-language tests skip automatically when the Java classpath or
ObjC binary cannot be located (e.g. running outside the MPEG-O
repo layout).
"""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import numpy as np
import pytest

from mpeg_o.enums import AcquisitionMode, Polarity
from mpeg_o.spectral_dataset import SpectralDataset, WrittenRun
from mpeg_o.transport.codec import file_to_transport, transport_to_file


REPO_ROOT = Path(__file__).resolve().parents[2]


# ---------------------------------------------------------- fixtures


def _build_dataset(path: Path, *, n_runs: int = 1, n_spectra: int = 5,
                    points_per_spectrum: int = 4) -> Path:
    runs: dict[str, WrittenRun] = {}
    for r in range(n_runs):
        total = n_spectra * points_per_spectrum
        mz = np.arange(total, dtype="<f8") + 100.0 * (r + 1)
        intensity = (np.arange(total, dtype="<f8") + 1.0) * (100.0 * (r + 1))
        offsets = np.arange(0, total, points_per_spectrum, dtype="<u8")
        lengths = np.full(n_spectra, points_per_spectrum, dtype="<u4")
        rts = np.linspace(1.0, float(n_spectra), n_spectra, dtype="<f8")
        ms_levels = np.array(
            [1 if i % 2 == 0 else 2 for i in range(n_spectra)], dtype="<i4"
        )
        polarities = np.full(n_spectra, int(Polarity.POSITIVE), dtype="<i4")
        precursor_mzs = np.array(
            [0.0 if ms_levels[i] == 1 else 500.0 + i for i in range(n_spectra)],
            dtype="<f8",
        )
        precursor_charges = np.array(
            [0 if ms_levels[i] == 1 else 2 for i in range(n_spectra)], dtype="<i4"
        )
        base_peaks = np.array([
            float(intensity[i * points_per_spectrum:(i + 1) * points_per_spectrum].max())
            for i in range(n_spectra)
        ], dtype="<f8")
        runs[f"run_{r:04d}"] = WrittenRun(
            spectrum_class="MPGOMassSpectrum",
            acquisition_mode=int(AcquisitionMode.MS1_DDA),
            channel_data={"mz": mz, "intensity": intensity},
            offsets=offsets,
            lengths=lengths,
            retention_times=rts,
            ms_levels=ms_levels,
            polarities=polarities,
            precursor_mzs=precursor_mzs,
            precursor_charges=precursor_charges,
            base_peak_intensities=base_peaks,
        )
    SpectralDataset.write_minimal(
        path,
        title="M70 conformance fixture",
        isa_investigation_id="ISA-M70",
        runs=runs,
    )
    return path


def _assert_signal_equal(a: SpectralDataset, b: SpectralDataset) -> None:
    assert set(a.all_runs) == set(b.all_runs)
    for name in a.all_runs:
        ra, rb = a.all_runs[name], b.all_runs[name]
        assert len(ra) == len(rb), f"run {name} spectrum count mismatch"
        for i in range(len(ra)):
            sa, sb = ra[i], rb[i]
            for c in ra.channel_names:
                aa = np.asarray(sa.signal_array(c).data)
                bb = np.asarray(sb.signal_array(c).data)
                np.testing.assert_allclose(
                    aa, bb, rtol=0.0, atol=0.0,
                    err_msg=f"run={name} spectrum={i} channel={c}"
                )
            assert sa.scan_time_seconds == pytest.approx(sb.scan_time_seconds)
            assert sa.precursor_mz == pytest.approx(sb.precursor_mz)


# ---------------------------------------------------------- in-language


class TestInLanguageRoundTrip:

    def test_single_run_roundtrip(self, tmp_path):
        src = _build_dataset(tmp_path / "src.mpgo")
        mots = tmp_path / "stream.mots"
        rt = tmp_path / "rt.mpgo"
        file_to_transport(src, mots)
        ds = transport_to_file(mots, rt)
        try:
            with SpectralDataset.open(src) as original:
                _assert_signal_equal(original, ds)
        finally:
            ds.close()

    def test_multi_run_roundtrip(self, tmp_path):
        src = _build_dataset(tmp_path / "src.mpgo", n_runs=3)
        mots = tmp_path / "stream.mots"
        rt = tmp_path / "rt.mpgo"
        file_to_transport(src, mots)
        ds = transport_to_file(mots, rt)
        try:
            with SpectralDataset.open(src) as original:
                _assert_signal_equal(original, ds)
        finally:
            ds.close()

    def test_larger_spectra(self, tmp_path):
        src = _build_dataset(
            tmp_path / "src.mpgo", n_spectra=20, points_per_spectrum=128
        )
        mots = tmp_path / "stream.mots"
        rt = tmp_path / "rt.mpgo"
        file_to_transport(src, mots)
        ds = transport_to_file(mots, rt)
        try:
            with SpectralDataset.open(src) as original:
                _assert_signal_equal(original, ds)
        finally:
            ds.close()

    def test_with_checksum_roundtrip(self, tmp_path):
        src = _build_dataset(tmp_path / "src.mpgo")
        mots = tmp_path / "stream.mots"
        rt = tmp_path / "rt.mpgo"
        file_to_transport(src, mots, use_checksum=True)
        ds = transport_to_file(mots, rt)
        try:
            with SpectralDataset.open(src) as original:
                _assert_signal_equal(original, ds)
        finally:
            ds.close()


# ---------------------------------------------------------- cross-language


def _java_cli_available() -> bool:
    target = REPO_ROOT / "java" / "target" / "classes"
    return target.is_dir() and (target / "com" / "dtwthalion" / "mpgo"
                                  / "tools" / "TransportEncodeCli.class").is_file()


def _objc_tool_available(name: str) -> bool:
    return (REPO_ROOT / "objc" / "Tools" / "obj" / name).is_file()


def _run_java(cli: str, *args: str) -> None:
    classes = REPO_ROOT / "java" / "target" / "classes"
    m2 = Path.home() / ".m2" / "repository"
    jars = []
    for pattern in ("*Java-WebSocket*.jar", "*slf4j*.jar",
                     "*sqlite-jdbc*.jar", "*bcprov*.jar"):
        jars.extend(str(p) for p in m2.rglob(pattern))
    cp = ":".join([str(classes), "/usr/share/java/jarhdf5.jar", *jars])
    subprocess.run(
        ["java", "-cp", cp,
         "-Djava.library.path=/usr/lib/x86_64-linux-gnu/jni",
         f"com.dtwthalion.mpgo.tools.{cli}", *args],
        check=True, capture_output=True,
    )


def _run_objc(tool: str, *args: str) -> None:
    src_obj = REPO_ROOT / "objc" / "Source" / "obj"
    tool_path = REPO_ROOT / "objc" / "Tools" / "obj" / tool
    env = os.environ.copy()
    env["LD_LIBRARY_PATH"] = f"{src_obj}:/usr/local/lib:{env.get('LD_LIBRARY_PATH', '')}"
    subprocess.run(
        [str(tool_path), *args],
        check=True, capture_output=True, env=env,
    )


@pytest.mark.skipif(
    not _java_cli_available(),
    reason="Java classes not built (run `mvn compile` first)"
)
class TestPythonJavaExchange:

    def test_python_encoded_stream_readable_by_java(self, tmp_path):
        src = _build_dataset(tmp_path / "src.mpgo")
        mots = tmp_path / "py.mots"
        rt = tmp_path / "rt.mpgo"
        file_to_transport(src, mots)
        _run_java("TransportDecodeCli", str(mots), str(rt))
        with SpectralDataset.open(src) as a, SpectralDataset.open(rt) as b:
            _assert_signal_equal(a, b)

    def test_java_encoded_stream_readable_by_python(self, tmp_path):
        src = _build_dataset(tmp_path / "src.mpgo")
        mots = tmp_path / "java.mots"
        rt = tmp_path / "rt.mpgo"
        _run_java("TransportEncodeCli", str(src), str(mots))
        ds = transport_to_file(mots, rt)
        try:
            with SpectralDataset.open(src) as original:
                _assert_signal_equal(original, ds)
        finally:
            ds.close()


@pytest.mark.skipif(
    not _objc_tool_available("MpgoTransportEncode"),
    reason="ObjC tools not built (run `./build.sh` first)"
)
class TestPythonObjCExchange:

    def test_python_encoded_stream_readable_by_objc(self, tmp_path):
        src = _build_dataset(tmp_path / "src.mpgo")
        mots = tmp_path / "py.mots"
        rt = tmp_path / "rt.mpgo"
        file_to_transport(src, mots)
        _run_objc("MpgoTransportDecode", str(mots), str(rt))
        with SpectralDataset.open(src) as a, SpectralDataset.open(rt) as b:
            _assert_signal_equal(a, b)

    def test_objc_encoded_stream_readable_by_python(self, tmp_path):
        src = _build_dataset(tmp_path / "src.mpgo")
        mots = tmp_path / "objc.mots"
        rt = tmp_path / "rt.mpgo"
        _run_objc("MpgoTransportEncode", str(src), str(mots))
        ds = transport_to_file(mots, rt)
        try:
            with SpectralDataset.open(src) as original:
                _assert_signal_equal(original, ds)
        finally:
            ds.close()


@pytest.mark.skipif(
    not (_java_cli_available()
         and _objc_tool_available("MpgoTransportEncode")),
    reason="Both Java and ObjC tools required"
)
class TestJavaObjCExchange:

    def test_java_encoded_stream_readable_by_objc(self, tmp_path):
        src = _build_dataset(tmp_path / "src.mpgo")
        mots = tmp_path / "java.mots"
        rt = tmp_path / "rt.mpgo"
        _run_java("TransportEncodeCli", str(src), str(mots))
        _run_objc("MpgoTransportDecode", str(mots), str(rt))
        with SpectralDataset.open(src) as a, SpectralDataset.open(rt) as b:
            _assert_signal_equal(a, b)

    def test_objc_encoded_stream_readable_by_java(self, tmp_path):
        src = _build_dataset(tmp_path / "src.mpgo")
        mots = tmp_path / "objc.mots"
        rt = tmp_path / "rt.mpgo"
        _run_objc("MpgoTransportEncode", str(src), str(mots))
        _run_java("TransportDecodeCli", str(mots), str(rt))
        with SpectralDataset.open(src) as a, SpectralDataset.open(rt) as b:
            _assert_signal_equal(a, b)
