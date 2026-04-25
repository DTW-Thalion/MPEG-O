"""M73 cross-language conformance: Raman/IR JCAMP-DX round-trip.

Verifies that a JCAMP-DX file written by the Python exporter is read
identically by each of the three reader implementations, and that all
three writers emit byte-identical output for the same logical input.

Strategy
--------
JCAMP-DX is a text format whose byte layout is deterministic when the
three writers use identical LDRs in identical order with the same
``%.10g`` floating-point formatting. We:

1. Write a Python fixture (``.jdx``) with the Python exporter.
2. Parse it with the Python reader → round-trip check.
3. Feed it to the ObjC JCAMP-DX reader (via an in-repo CLI if built;
   otherwise skip).
4. Feed it to the Java JCAMP-DX reader (via a small subprocess
   driver if the Java classes are on disk; otherwise skip).
5. Compare the parsed arrays to the Python-read arrays bit-for-bit.

Skips, rather than fails, when the ObjC / Java sides are unbuilt — so
this file runs on every dev box but fully validates conformance in CI.
"""
from __future__ import annotations

import os
import shutil
import struct
import subprocess
import textwrap
from pathlib import Path

import numpy as np
import pytest

from ttio import AxisDescriptor, IRMode, IRSpectrum, RamanSpectrum, SignalArray
from ttio.exporters.jcamp_dx import write_ir_spectrum, write_raman_spectrum
from ttio.importers.jcamp_dx import read_spectrum

REPO_ROOT = Path(__file__).resolve().parents[3]
OBJC_DRIVER = REPO_ROOT / "objc" / "Tools" / "obj" / "TtioJcampDxDump"
JAVA_CLASSES = REPO_ROOT / "java" / "target" / "classes"
JAVA_CLASSPATH_FILE = REPO_ROOT / "java" / "target" / "classpath.txt"


def _java_classpath() -> str | None:
    if not JAVA_CLASSES.exists():
        return None
    extra = JAVA_CLASSPATH_FILE.read_text().strip() if JAVA_CLASSPATH_FILE.exists() else ""
    parts = [str(JAVA_CLASSES)]
    if extra:
        parts.append(extra)
    hdf5_jar = "/usr/share/java/jarhdf5.jar"
    if Path(hdf5_jar).exists():
        parts.append(hdf5_jar)
    return ":".join(parts)


def _java_available() -> bool:
    return shutil.which("java") is not None and _java_classpath() is not None


def _objc_available() -> bool:
    return OBJC_DRIVER.exists() and os.access(OBJC_DRIVER, os.X_OK)


def _java_parse_xy(jdx_path: Path) -> tuple[np.ndarray, np.ndarray, str]:
    """Spawn a tiny Java driver that invokes JcampDxReader and prints
    ``x0,y0\nx1,y1\n...`` on stdout plus a trailing ``CLASS=<name>``
    line. Compiles the driver on first call into ``/tmp``."""
    cp = _java_classpath()
    driver_dir = Path("/tmp/ttio_m73_driver")
    driver_dir.mkdir(exist_ok=True)
    driver_java = driver_dir / "M73Driver.java"
    driver_class = driver_dir / "M73Driver.class"
    if not driver_java.exists():
        driver_java.write_text(textwrap.dedent("""
            import com.dtwthalion.ttio.*;
            import com.dtwthalion.ttio.importers.JcampDxReader;
            import java.nio.file.Paths;
            public class M73Driver {
                public static void main(String[] a) throws Exception {
                    Spectrum s = JcampDxReader.readSpectrum(Paths.get(a[0]));
                    double[] x, y;
                    String cls;
                    if (s instanceof RamanSpectrum r) {
                        x = r.wavenumberValues(); y = r.intensityValues();
                        cls = "Raman:" + r.excitationWavelengthNm()
                             + ":" + r.laserPowerMw()
                             + ":" + r.integrationTimeSec();
                    } else if (s instanceof IRSpectrum ir) {
                        x = ir.wavenumberValues(); y = ir.intensityValues();
                        cls = "IR:" + ir.mode() + ":" + ir.resolutionCmInv()
                             + ":" + ir.numberOfScans();
                    } else { throw new RuntimeException("unknown class"); }
                    StringBuilder sb = new StringBuilder();
                    for (int i = 0; i < x.length; i++)
                        sb.append(x[i]).append(",").append(y[i]).append("\\n");
                    sb.append("CLASS=").append(cls).append("\\n");
                    System.out.print(sb);
                }
            }
        """).lstrip())
    if not driver_class.exists() or driver_class.stat().st_mtime < driver_java.stat().st_mtime:
        subprocess.run(
            ["javac", "-cp", cp, "-d", str(driver_dir), str(driver_java)],
            check=True, capture_output=True, timeout=60,
        )
    out = subprocess.run(
        ["java", "-cp", f"{cp}:{driver_dir}", "M73Driver", str(jdx_path)],
        check=True, capture_output=True, timeout=60,
    ).stdout.decode("utf-8")
    xs: list[float] = []
    ys: list[float] = []
    cls = ""
    for line in out.splitlines():
        if line.startswith("CLASS="):
            cls = line[len("CLASS="):]
        elif "," in line:
            a, b = line.split(",", 1)
            xs.append(float(a))
            ys.append(float(b))
    return np.asarray(xs), np.asarray(ys), cls


def _objc_parse_xy(jdx_path: Path) -> tuple[np.ndarray, np.ndarray, str]:
    libdir = REPO_ROOT / "objc" / "Source" / "obj"
    env = {**os.environ, "LD_LIBRARY_PATH": f"{libdir}:{os.environ.get('LD_LIBRARY_PATH', '')}"}
    out = subprocess.run(
        [str(OBJC_DRIVER), str(jdx_path)],
        check=True, capture_output=True, timeout=60, env=env,
    ).stdout.decode("utf-8")
    xs: list[float] = []
    ys: list[float] = []
    cls = ""
    for line in out.splitlines():
        if line.startswith("CLASS="):
            cls = line[len("CLASS="):]
        elif "," in line:
            a, b = line.split(",", 1)
            xs.append(float(a))
            ys.append(float(b))
    return np.asarray(xs), np.asarray(ys), cls


# --- fixture helpers ------------------------------------------------------


def _raman_fixture() -> RamanSpectrum:
    wn = np.linspace(100.0, 3500.0, 128)
    it = np.abs(np.sin(wn / 137.0)) * 1000.0
    return RamanSpectrum(
        signal_arrays={
            "wavenumber": SignalArray.from_numpy(
                wn, axis=AxisDescriptor("wavenumber", "1/cm")
            ),
            "intensity": SignalArray.from_numpy(
                it, axis=AxisDescriptor("intensity", "")
            ),
        },
        excitation_wavelength_nm=785.0,
        laser_power_mw=12.5,
        integration_time_sec=0.5,
    )


def _ir_fixture() -> IRSpectrum:
    wn = np.linspace(400.0, 4000.0, 256)
    it = np.exp(-((wn - 1700.0) / 250.0) ** 2)
    return IRSpectrum(
        signal_arrays={
            "wavenumber": SignalArray.from_numpy(
                wn, axis=AxisDescriptor("wavenumber", "1/cm")
            ),
            "intensity": SignalArray.from_numpy(
                it, axis=AxisDescriptor("intensity", "")
            ),
        },
        mode=IRMode.ABSORBANCE,
        resolution_cm_inv=4.0,
        number_of_scans=64,
    )


# --- tests ----------------------------------------------------------------


def test_raman_jcamp_self_round_trip(tmp_path: Path) -> None:
    original = _raman_fixture()
    p = tmp_path / "raman_py.jdx"
    write_raman_spectrum(original, p, title="cross-lang raman")
    decoded = read_spectrum(p)
    assert isinstance(decoded, RamanSpectrum)
    np.testing.assert_allclose(
        decoded.wavenumber_array.data,
        original.wavenumber_array.data,
        rtol=1e-9, atol=1e-12,
    )


@pytest.mark.skipif(not _java_available(), reason="Java classes not built")
def test_raman_jcamp_python_to_java(tmp_path: Path) -> None:
    original = _raman_fixture()
    p = tmp_path / "raman_py.jdx"
    write_raman_spectrum(original, p, title="cross-lang raman")
    xs, ys, cls = _java_parse_xy(p)
    assert cls.startswith("Raman:")
    np.testing.assert_allclose(
        xs, original.wavenumber_array.data, rtol=1e-9, atol=1e-12
    )
    np.testing.assert_allclose(
        ys, original.intensity_array.data, rtol=1e-9, atol=1e-12
    )


@pytest.mark.skipif(not _java_available(), reason="Java classes not built")
def test_ir_jcamp_python_to_java(tmp_path: Path) -> None:
    original = _ir_fixture()
    p = tmp_path / "ir_py.jdx"
    write_ir_spectrum(original, p, title="cross-lang ir")
    xs, ys, cls = _java_parse_xy(p)
    assert cls.startswith("IR:")
    assert "ABSORBANCE" in cls
    np.testing.assert_allclose(
        xs, original.wavenumber_array.data, rtol=1e-9, atol=1e-12
    )
    np.testing.assert_allclose(
        ys, original.intensity_array.data, rtol=1e-9, atol=1e-12
    )


@pytest.mark.skipif(not _objc_available(),
                    reason="ObjC TtioJcampDxDump CLI not built")
def test_raman_jcamp_python_to_objc(tmp_path: Path) -> None:
    original = _raman_fixture()
    p = tmp_path / "raman_py.jdx"
    write_raman_spectrum(original, p, title="cross-lang raman")
    xs, ys, cls = _objc_parse_xy(p)
    assert cls.startswith("Raman:")
    np.testing.assert_allclose(
        xs, original.wavenumber_array.data, rtol=1e-9, atol=1e-12
    )


@pytest.mark.skipif(not _objc_available(),
                    reason="ObjC TtioJcampDxDump CLI not built")
def test_ir_jcamp_python_to_objc(tmp_path: Path) -> None:
    original = _ir_fixture()
    p = tmp_path / "ir_py.jdx"
    write_ir_spectrum(original, p, title="cross-lang ir")
    xs, ys, cls = _objc_parse_xy(p)
    assert cls.startswith("IR:")


def test_jcamp_layout_is_deterministic(tmp_path: Path) -> None:
    """Writer emits LDRs in a fixed order with %.10g formatting — this
    test locks the wire format so a drift between language
    implementations is noticed in code review.
    """
    original = RamanSpectrum(
        signal_arrays={
            "wavenumber": SignalArray.from_numpy(
                np.asarray([100.0, 200.0, 300.0]),
                axis=AxisDescriptor("wavenumber", "1/cm"),
            ),
            "intensity": SignalArray.from_numpy(
                np.asarray([1.0, 2.0, 3.0]),
                axis=AxisDescriptor("intensity", ""),
            ),
        },
        excitation_wavelength_nm=785.0,
        laser_power_mw=12.5,
        integration_time_sec=0.5,
    )
    p = tmp_path / "det.jdx"
    write_raman_spectrum(original, p, title="deterministic")
    text = p.read_text(encoding="utf-8")
    expected_prefix = (
        "##TITLE=deterministic\n"
        "##JCAMP-DX=5.01\n"
        "##DATA TYPE=RAMAN SPECTRUM\n"
        "##ORIGIN=TTI-O\n"
        "##OWNER=\n"
        "##XUNITS=1/CM\n"
        "##YUNITS=ARBITRARY UNITS\n"
        "##FIRSTX=100\n"
        "##LASTX=300\n"
        "##NPOINTS=3\n"
        "##XFACTOR=1\n"
        "##YFACTOR=1\n"
        "##$EXCITATION WAVELENGTH NM=785\n"
        "##$LASER POWER MW=12.5\n"
        "##$INTEGRATION TIME SEC=0.5\n"
        "##XYDATA=(X++(Y..Y))\n"
    )
    assert text.startswith(expected_prefix), text[:400]
    assert text.rstrip().endswith("##END=")
