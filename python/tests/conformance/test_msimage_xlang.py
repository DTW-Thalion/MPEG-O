"""Cross-language parity for MSImage.mz_axis (1.2.0).

Python writes a deterministic .tio with a populated mz_axis. Java +
ObjC reader CLIs are invoked as subprocesses; each emits the 64-byte
mz_axis payload to stdout in little-endian float64. The test asserts
byte-equality across all three languages.

Pattern follows test_references_xlang.py (Phase 0 of tio-browser).

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import numpy as np
import pytest

from ttio import MSImage, SpectralDataset


# --- Paths ------------------------------------------------------------------

_REPO = Path(__file__).resolve().parents[3]
_JAVA = _REPO / "java"
_OBJC = _REPO / "objc"

_JAVA_CLASSES = _JAVA / "target" / "classes"
_JAVA_TEST_CLASSES = _JAVA / "target" / "test-classes"
_JAVA_CLASSPATH_TXT = _JAVA / "target" / "classpath.txt"
_JAVA_HDF5_JAR = Path("/usr/share/java/jarhdf5.jar")

_OBJC_BIN = _OBJC / "Tools" / "obj"
_OBJC_LIB = _OBJC / "Source" / "obj"


# --- Canonical fixture -------------------------------------------------------

W, H, SP = 4, 3, 8
MZ_AXIS = np.linspace(100.0, 800.0, SP)   # 100, 200, ..., 800
INTENSITY = np.arange(H * W * SP, dtype=np.float64).reshape(H, W, SP) * 0.1


# --- Skip helpers ------------------------------------------------------------

def _java_runtime_available() -> bool:
    if not _JAVA_CLASSES.is_dir() or not _JAVA_TEST_CLASSES.is_dir():
        return False
    if not _JAVA_CLASSPATH_TXT.is_file():
        return False
    if not _JAVA_HDF5_JAR.is_file():
        return False
    if shutil.which("java") is None:
        return False
    return (_JAVA_TEST_CLASSES
            / "global/thalion/ttio/conformance/MsImageXLangReader.class").is_file()


def _objc_runtime_available() -> bool:
    return ((_OBJC_BIN / "TtioMsImageXLangReader").is_file()
            and _OBJC_LIB.is_dir())


def _java_classpath() -> str:
    return ":".join((
        str(_JAVA_CLASSES),
        str(_JAVA_TEST_CLASSES),
        _JAVA_CLASSPATH_TXT.read_text().strip(),
        str(_JAVA_HDF5_JAR),
    ))


def _objc_env() -> dict:
    env = os.environ.copy()
    extra = [str(_OBJC_LIB), "/usr/local/lib"]
    cur = env.get("LD_LIBRARY_PATH", "")
    if cur:
        extra.append(cur)
    env["LD_LIBRARY_PATH"] = ":".join(extra)
    return env


# --- Test -------------------------------------------------------------------

def test_mz_axis_byte_equal_xlang(tmp_path: Path) -> None:
    """Python writes; Java + ObjC read; mz_axis bytes match Python ground truth."""
    out = tmp_path / "xlang.tio"
    img = MSImage(
        width=W, height=H, spectral_points=SP,
        intensity=INTENSITY, mz_axis=MZ_AXIS,
        pixel_size_x=10.0, pixel_size_y=10.0, scan_pattern="raster",
    )
    SpectralDataset.write_minimal(
        out, title="xlang", isa_investigation_id="", runs={}, image=img,
    )

    # Python ground-truth bytes
    expected = np.ascontiguousarray(MZ_AXIS, dtype="<f8").tobytes()
    assert len(expected) == SP * 8

    # Java reader
    if _java_runtime_available():
        java_proc = subprocess.run(
            ["java", "-cp", _java_classpath(),
             "global.thalion.ttio.conformance.MsImageXLangReader", str(out)],
            check=True, capture_output=True, timeout=60,
        )
        assert java_proc.stdout == expected, (
            f"Java mz_axis bytes differ: got {len(java_proc.stdout)} bytes")
    else:
        pytest.skip("Java conformance reader not built")

    # ObjC reader
    if _objc_runtime_available():
        objc_proc = subprocess.run(
            [str(_OBJC_BIN / "TtioMsImageXLangReader"), str(out)],
            check=True, capture_output=True, timeout=60, env=_objc_env(),
        )
        assert objc_proc.stdout == expected, (
            f"ObjC mz_axis bytes differ: got {len(objc_proc.stdout)} bytes")
    else:
        pytest.skip("ObjC conformance reader not built")
