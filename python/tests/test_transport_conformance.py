"""v0.10 M70: bidirectional conversion conformance.

Two layers of testing:

1. **In-language round-trip** — .tio → .tis → .tio with signal
   values preserved to float64 epsilon. Same for multi-run,
   multi-spectrum, and empty-run edge cases.

2. **Cross-language exchange** — Python spawns Java and ObjC
   encode/decode CLIs and verifies that a stream produced in one
   language is decodable in the other two.

Cross-language tests skip automatically when the Java classpath or
ObjC binary cannot be located (e.g. running outside the TTI-O
repo layout).
"""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import numpy as np
import pytest

from ttio.enums import AcquisitionMode, Polarity
from ttio.spectral_dataset import SpectralDataset, WrittenRun
from ttio.transport.codec import file_to_transport, transport_to_file


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
            spectrum_class="TTIOMassSpectrum",
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
        src = _build_dataset(tmp_path / "src.tio")
        mots = tmp_path / "stream.tis"
        rt = tmp_path / "rt.tio"
        file_to_transport(src, mots)
        ds = transport_to_file(mots, rt)
        try:
            with SpectralDataset.open(src) as original:
                _assert_signal_equal(original, ds)
        finally:
            ds.close()

    def test_multi_run_roundtrip(self, tmp_path):
        src = _build_dataset(tmp_path / "src.tio", n_runs=3)
        mots = tmp_path / "stream.tis"
        rt = tmp_path / "rt.tio"
        file_to_transport(src, mots)
        ds = transport_to_file(mots, rt)
        try:
            with SpectralDataset.open(src) as original:
                _assert_signal_equal(original, ds)
        finally:
            ds.close()

    def test_larger_spectra(self, tmp_path):
        src = _build_dataset(
            tmp_path / "src.tio", n_spectra=20, points_per_spectrum=128
        )
        mots = tmp_path / "stream.tis"
        rt = tmp_path / "rt.tio"
        file_to_transport(src, mots)
        ds = transport_to_file(mots, rt)
        try:
            with SpectralDataset.open(src) as original:
                _assert_signal_equal(original, ds)
        finally:
            ds.close()

    def test_with_checksum_roundtrip(self, tmp_path):
        src = _build_dataset(tmp_path / "src.tio")
        mots = tmp_path / "stream.tis"
        rt = tmp_path / "rt.tio"
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
    return target.is_dir() and (target / "global" / "thalion" / "ttio"
                                  / "tools" / "TransportEncodeCli.class").is_file()


def _objc_tool_available(name: str) -> bool:
    return (REPO_ROOT / "objc" / "Tools" / "obj" / name).is_file()


# Java 21 preview-API + FFM flags. The library uses FFM for HDF5 1.14
# VL_BYTES handling; classes compiled with --enable-preview cannot be
# loaded without the same flag at runtime. The java.library.path entry
# is platform-dependent: Linux source-builds land at /usr/local/lib;
# Windows mingw-ucrt64 builds land under $HDF5_HOME/bin. The default
# below covers the Linux CI path; non-Linux environments must set
# TTIO_HDF5_NATIVE so the test loads the right libhdf5_java/{so,dll}.
_HDF5_NATIVE_DEFAULT = "/usr/local/lib"
_HDF5_JAR_DEFAULT = "/usr/local/lib/jarhdf5.jar"


def _hdf5_native_dir() -> str:
    return os.environ.get("TTIO_HDF5_NATIVE", _HDF5_NATIVE_DEFAULT)


def _hdf5_jar_path() -> str:
    return os.environ.get("TTIO_HDF5_JAR", _HDF5_JAR_DEFAULT)


def _java_flags() -> list[str]:
    return [
        "--enable-preview",
        "--enable-native-access=ALL-UNNAMED",
        f"-Djava.library.path={_hdf5_native_dir()}",
    ]


def _build_java_classpath() -> str:
    """Compose the runtime classpath for the Java CLIs.

    Prefers a cached ``target/runtime-classpath.txt`` produced by
    ``mvn dependency:build-classpath`` — that is the project's exact
    transitive dep set, with no risk of pulling in stray jars from a
    shared local Maven cache. Falls back to a deliberately narrow
    glob of the jars actually declared in ``java/pom.xml`` if the
    cache file is absent (e.g. fresh checkout where ``mvn`` has not
    run yet on this machine).
    """
    classes = REPO_ROOT / "java" / "target" / "classes"
    cp_file = REPO_ROOT / "java" / "target" / "runtime-classpath.txt"
    if cp_file.is_file():
        # Maven's resolved classpath already uses os.pathsep on the
        # generating platform — re-emit as a single string with our
        # ``classes`` dir and the HDF5 jar prepended.
        resolved = cp_file.read_text().strip()
        return os.pathsep.join([str(classes), _hdf5_jar_path(), resolved])
    # Conservative fallback: glob only jars whose exact artifact name
    # is in ``java/pom.xml``. Earlier versions of this helper used
    # ``*slf4j*.jar`` which over-pulled ``log4j-slf4j-impl`` from
    # transitive caches and caused ``NoClassDefFoundError: org/apache
    # /log4j/Level`` at HDF5 init time. Keep this list in sync with
    # the runtime-scope deps in ``java/pom.xml``.
    m2 = Path.home() / ".m2" / "repository"
    name_patterns = (
        "Java-WebSocket-*.jar",
        "slf4j-api-2.*.jar",
        "slf4j-simple-2.*.jar",
        "sqlite-jdbc-*.jar",
        "bcprov-jdk18on-*.jar",
        "htsjdk-*.jar",
    )
    jars: list[str] = []
    for pat in name_patterns:
        jars.extend(sorted(str(p) for p in m2.rglob(pat)))
    return os.pathsep.join([str(classes), _hdf5_jar_path(), *jars])


def _run_java(cli: str, *args: str) -> None:
    cp = _build_java_classpath()
    subprocess.run(
        ["java", *_java_flags(), "-cp", cp,
         f"global.thalion.ttio.tools.{cli}", *args],
        check=True, capture_output=True,
    )


def _run_objc(tool: str, *args: str) -> None:
    src_obj = REPO_ROOT / "objc" / "Source" / "obj"
    tool_path = REPO_ROOT / "objc" / "Tools" / "obj" / tool
    env = os.environ.copy()
    env["LD_LIBRARY_PATH"] = (
        f"{src_obj}{os.pathsep}{_hdf5_native_dir()}"
        f"{os.pathsep}{env.get('LD_LIBRARY_PATH', '')}"
    )
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
        src = _build_dataset(tmp_path / "src.tio")
        mots = tmp_path / "py.tis"
        rt = tmp_path / "rt.tio"
        file_to_transport(src, mots)
        _run_java("TransportDecodeCli", str(mots), str(rt))
        with SpectralDataset.open(src) as a, SpectralDataset.open(rt) as b:
            _assert_signal_equal(a, b)

    def test_java_encoded_stream_readable_by_python(self, tmp_path):
        src = _build_dataset(tmp_path / "src.tio")
        mots = tmp_path / "java.tis"
        rt = tmp_path / "rt.tio"
        _run_java("TransportEncodeCli", str(src), str(mots))
        ds = transport_to_file(mots, rt)
        try:
            with SpectralDataset.open(src) as original:
                _assert_signal_equal(original, ds)
        finally:
            ds.close()


@pytest.mark.skipif(
    not _objc_tool_available("TtioTransportEncode"),
    reason="ObjC tools not built (run `./build.sh` first)"
)
class TestPythonObjCExchange:

    def test_python_encoded_stream_readable_by_objc(self, tmp_path):
        src = _build_dataset(tmp_path / "src.tio")
        mots = tmp_path / "py.tis"
        rt = tmp_path / "rt.tio"
        file_to_transport(src, mots)
        _run_objc("TtioTransportDecode", str(mots), str(rt))
        with SpectralDataset.open(src) as a, SpectralDataset.open(rt) as b:
            _assert_signal_equal(a, b)

    def test_objc_encoded_stream_readable_by_python(self, tmp_path):
        src = _build_dataset(tmp_path / "src.tio")
        mots = tmp_path / "objc.tis"
        rt = tmp_path / "rt.tio"
        _run_objc("TtioTransportEncode", str(src), str(mots))
        ds = transport_to_file(mots, rt)
        try:
            with SpectralDataset.open(src) as original:
                _assert_signal_equal(original, ds)
        finally:
            ds.close()


@pytest.mark.skipif(
    not (_java_cli_available()
         and _objc_tool_available("TtioTransportEncode")),
    reason="Both Java and ObjC tools required"
)
class TestJavaObjCExchange:

    def test_java_encoded_stream_readable_by_objc(self, tmp_path):
        src = _build_dataset(tmp_path / "src.tio")
        mots = tmp_path / "java.tis"
        rt = tmp_path / "rt.tio"
        _run_java("TransportEncodeCli", str(src), str(mots))
        _run_objc("TtioTransportDecode", str(mots), str(rt))
        with SpectralDataset.open(src) as a, SpectralDataset.open(rt) as b:
            _assert_signal_equal(a, b)

    def test_objc_encoded_stream_readable_by_java(self, tmp_path):
        src = _build_dataset(tmp_path / "src.tio")
        mots = tmp_path / "objc.tis"
        rt = tmp_path / "rt.tio"
        _run_objc("TtioTransportEncode", str(src), str(mots))
        _run_java("TransportDecodeCli", str(mots), str(rt))
        with SpectralDataset.open(src) as a, SpectralDataset.open(rt) as b:
            _assert_signal_equal(a, b)
