"""Cross-language nmrML parity conformance.

Drives the Python, Java, and ObjC nmrML readers against the same
synthetic nmrML input and asserts that all three surface the same
four parity fields:

  - numberOfScans            (int)
  - spectrometerFrequencyMHz (double)
  - fidReal                  (list[double])
  - fidImag                  (list[double])

Each language reader is invoked through a tiny "probe" CLI that emits
the four fields as JSON so the byte-equality comparison is reduced to
parsing + structural equality. Doubles are emitted with full IEEE-754
precision in each language (Java {@code Double.toString}, ObjC
{@code %.17g}, Python {@code repr}) so cross-language numeric
equality is bit-exact, not "close enough".

The test SKIPs cleanly when any toolchain is unavailable.
"""
from __future__ import annotations

import base64
import json
import os
import shutil
import struct
import subprocess
from pathlib import Path

import numpy as np
import pytest

from ttio.importers import nmrml as _nmrml_mod


REPO_ROOT = Path(__file__).resolve().parents[3]
JAVA_TARGET = REPO_ROOT / "java" / "target"
OBJC_TOOL_NMRML = REPO_ROOT / "objc" / "Tools" / "obj" / "TtioNmrMLProbe"
OBJC_LIB_DIR = REPO_ROOT / "objc" / "Source" / "obj"

# Java 21 preview-API + FFM flags. The library uses FFM for HDF5 1.14
# VL_BYTES handling; classes compiled with --enable-preview cannot be
# loaded without the same flag at runtime.
# `-Djava.library.path=/usr/local/lib` forces loading the source-built
# HDF5 1.14 libhdf5_java.so; without it Java's default search path picks
# up the lingering apt-installed `libhdf5-jni` 1.10 first and the
# version mismatch triggers UnsatisfiedLinkError on H5 native methods.
_JAVA_FLAGS = [
    "--enable-preview",
    "--enable-native-access=ALL-UNNAMED",
    "-Djava.library.path=/usr/local/lib",
]


def _have_java() -> bool:
    if shutil.which("java") is None:
        return False
    classes = JAVA_TARGET / "classes"
    return classes.exists() and any(classes.rglob("NmrMLProbe.class"))


def _have_objc() -> bool:
    return OBJC_TOOL_NMRML.exists() and os.access(OBJC_TOOL_NMRML, os.X_OK)


def _run_java_probe(in_path: Path) -> dict:
    cmd = [
        "java", *_JAVA_FLAGS, "-cp", str(JAVA_TARGET / "classes"),
        "global.thalion.ttio.tools.NmrMLProbe", str(in_path),
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(
            f"Java NmrMLProbe failed (exit {res.returncode}): "
            f"{res.stderr.strip()}"
        )
    return json.loads(res.stdout.strip())


def _run_objc_probe(in_path: Path) -> dict:
    env = os.environ.copy()
    existing = env.get("LD_LIBRARY_PATH", "")
    env["LD_LIBRARY_PATH"] = (
        str(OBJC_LIB_DIR) + (":" + existing if existing else "")
    )
    cmd = [str(OBJC_TOOL_NMRML), str(in_path)]
    res = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(
            f"ObjC TtioNmrMLProbe failed (exit {res.returncode}): "
            f"{res.stderr.strip()}"
        )
    return json.loads(res.stdout.strip())


def _python_probe(in_path: Path) -> dict:
    res = _nmrml_mod.read(in_path)
    return {
        "numberOfScans": int(res.number_of_scans),
        "spectrometerFrequencyMHz": float(res.spectrometer_frequency_mhz),
        "fidReal": [float(x) for x in res.fid_real],
        "fidImag": [float(x) for x in res.fid_imag],
    }


def _build_synthetic_nmrml(tmp_path: Path) -> Path:
    """Synthesize the same minimal nmrML the Java + ObjC parity tests
    use so all three readers exercise the same parsing path."""
    n = 32
    real = [i * 0.5 for i in range(n)]
    imag = [-i * 0.25 for i in range(n)]
    interleaved = b"".join(
        struct.pack("<dd", real[i], imag[i]) for i in range(n)
    )
    fid_b64 = base64.b64encode(interleaved).decode("ascii")
    xml = (
        '<?xml version="1.0"?>'
        '<nmrML xmlns="http://nmrml.org/schema">'
        '<cvList><cv id="nmrCV" fullName="x" version="1.1.0"/></cvList>'
        '<acquisition><acquisition1D>'
        '<acquisitionParameterSet numberOfScans="16">'
        '<acquisitionNucleus name="1H"/>'
        '<irradiationFrequency value="600000000"/>'
        '</acquisitionParameterSet>'
        f'<fidData compressed="false" byteFormat="complex128"'
        f' encodedLength="{len(fid_b64)}">{fid_b64}</fidData>'
        '</acquisition1D></acquisition></nmrML>'
    )
    out = tmp_path / "synthetic.nmrML"
    out.write_text(xml, encoding="utf-8")
    return out


# ──────────────────────────────────────────────────────────────────────


@pytest.mark.skipif(
    not (_have_java() and _have_objc()),
    reason="needs both Java NmrMLProbe.class and built TtioNmrMLProbe"
)
def test_nmrml_three_way_parity(tmp_path: Path) -> None:
    src = _build_synthetic_nmrml(tmp_path)

    py = _python_probe(src)
    java = _run_java_probe(src)
    objc = _run_objc_probe(src)

    # Integer + float scalar parity is strict.
    assert py["numberOfScans"] == 16
    assert py["numberOfScans"] == java["numberOfScans"] == objc["numberOfScans"]
    assert py["spectrometerFrequencyMHz"] == 600.0
    assert (
        py["spectrometerFrequencyMHz"]
        == java["spectrometerFrequencyMHz"]
        == objc["spectrometerFrequencyMHz"]
    )

    # FID arrays — bit-exact across all three (same input, same parse).
    assert len(py["fidReal"]) == 32
    assert py["fidReal"] == java["fidReal"] == objc["fidReal"], (
        "fidReal not bit-equal across Python / Java / ObjC"
    )
    assert py["fidImag"] == java["fidImag"] == objc["fidImag"], (
        "fidImag not bit-equal across Python / Java / ObjC"
    )

    # Sanity-check the values match the synthetic input (i*0.5, -i*0.25).
    expected_real = [i * 0.5 for i in range(32)]
    expected_imag = [-i * 0.25 for i in range(32)]
    assert py["fidReal"] == expected_real
    assert py["fidImag"] == expected_imag


@pytest.mark.skipif(
    not (_have_java() and _have_objc()),
    reason="needs both Java NmrMLProbe.class and built TtioNmrMLProbe"
)
def test_nmrml_three_way_parity_real_fixture() -> None:
    """Drive the public bmse000325.nmrML fixture (a real metabolite
    sample) through all three readers and assert the same surface
    fields. This catches divergences that wouldn't surface on the
    minimal synthetic input."""
    fixture = (
        REPO_ROOT
        / "java"
        / "src"
        / "test"
        / "resources"
        / "bmse000325.nmrML"
    )
    if not fixture.is_file():
        pytest.skip(f"bmse000325.nmrML not available at {fixture}")

    py = _python_probe(fixture)
    java = _run_java_probe(fixture)
    objc = _run_objc_probe(fixture)

    assert py["numberOfScans"] == java["numberOfScans"] == objc["numberOfScans"]
    assert (
        py["spectrometerFrequencyMHz"]
        == java["spectrometerFrequencyMHz"]
        == objc["spectrometerFrequencyMHz"]
    )
    # bmse000325 stores its FID as a separate file referenced from the
    # nmrML; the readers may surface fid_real/fid_imag as empty arrays.
    # Either way, all three must agree.
    assert py["fidReal"] == java["fidReal"] == objc["fidReal"]
    assert py["fidImag"] == java["fidImag"] == objc["fidImag"]
