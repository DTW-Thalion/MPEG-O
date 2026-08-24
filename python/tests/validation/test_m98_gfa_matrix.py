"""M98: GFA container conformance across the 3 SDKs.

Two fixtures — the synthetic full-surface GFA and a real hifiasm
raw-unitig graph (``fx.bp.r_utg.gfa``, HG002 chr1 window, committed
gzipped per binding decision 48) — run through:

* **dump equality**: each SDK's ``GfaDump`` CLI parses the GFA and
  emits canonical JSON (``sort_keys=True, indent=2`` shape); the ObjC
  and Java outputs must be byte-identical to Python's.
* **3x3 container matrix**: each SDK writes a ``.tio`` holding the
  graph (``--write-tio``), each SDK re-emits GFA bytes from each
  container (``--emit-gfa``), and the result must equal the fixture
  byte-for-byte.

CLI parity: ``python -m ttio.importers.gfa_dump`` / ObjC
``TtioGfaDump`` / Java ``global.thalion.ttio.importers.GfaDump``, all
taking ``<input> [--graph NAME] [--write-tio OUT] [--emit-gfa OUT]``.

Cells whose SDK binary is not built are skipped, mirroring the M89
matrix; the pure-Python cells always run.
"""
from __future__ import annotations

import gzip
import json
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))
from test_m89_cross_language import (  # type: ignore[import-not-found]
    _resolve_java_tool,
    _resolve_objc_tool,
)

_FIXDIR = Path(__file__).parent.parent / "fixtures" / "assembly"
_FIXTURES = ["synthetic_full_surface.gfa", "fx_bp_r_utg.gfa.gz"]

_JAVA_CLASS = "global.thalion.ttio.importers.GfaDump"
_OBJC_TOOL = "TtioGfaDump"


def _fixture_bytes(name: str) -> bytes:
    data = (_FIXDIR / name).read_bytes()
    if name.endswith(".gz"):
        data = gzip.decompress(data)
    return data


def _materialise(tmp_path: Path, name: str) -> Path:
    """Decompressed fixture copy the external CLIs can read."""
    out = tmp_path / name.removesuffix(".gz")
    out.write_bytes(_fixture_bytes(name))
    return out


def _run_objc(args: list[str]) -> bytes:
    tool = _resolve_objc_tool(_OBJC_TOOL)
    if tool is None:
        pytest.skip(f"ObjC {_OBJC_TOOL} binary not built")
    binary, env = tool
    proc = subprocess.run(
        [str(binary), *args],
        capture_output=True, env=env, timeout=120,
    )
    assert proc.returncode == 0, (
        f"{_OBJC_TOOL} {args} failed rc={proc.returncode}: "
        f"{proc.stderr.decode(errors='replace')[:500]}"
    )
    return proc.stdout


def _run_java(args: list[str]) -> bytes:
    tool = _resolve_java_tool(_JAVA_CLASS)
    if tool is None:
        pytest.skip("Java classpath not available")
    argv, env = tool
    proc = subprocess.run(
        [*argv, *args],
        capture_output=True, env=env, timeout=240,
    )
    assert proc.returncode == 0, (
        f"{_JAVA_CLASS} {args} failed rc={proc.returncode}: "
        f"{proc.stderr.decode(errors='replace')[:500]}"
    )
    return proc.stdout


# --------------------------------------------------------------------------- #
# Canonical-JSON dump equality.
# --------------------------------------------------------------------------- #


def _python_dump_bytes(gfa_path: Path) -> bytes:
    from ttio.importers.gfa_dump import dump

    payload = dump(str(gfa_path))
    return (json.dumps(payload, sort_keys=True, indent=2) + "\n").encode()


@pytest.mark.parametrize("fixture", _FIXTURES)
@pytest.mark.parametrize("lang", ["objc", "java"])
def test_m98_dump_json_matches_python(fixture, lang, tmp_path):
    gfa = _materialise(tmp_path, fixture)
    expected = _python_dump_bytes(gfa)
    runner = _run_objc if lang == "objc" else _run_java
    got = runner([str(gfa)])
    assert got == expected, (
        f"{lang} GfaDump JSON differs from Python for {fixture} "
        f"(lengths {len(got)} vs {len(expected)})"
    )


# --------------------------------------------------------------------------- #
# 3x3 container matrix: writer x emitter, byte-exact re-emission.
# --------------------------------------------------------------------------- #


def _py_write(gfa_path: Path, tio_path: Path) -> None:
    from ttio.importers.gfa_dump import main

    assert main([str(gfa_path), "--write-tio", str(tio_path)]) == 0


def _py_emit(tio_path: Path, out_path: Path) -> None:
    from ttio.importers.gfa_dump import main

    assert main([str(tio_path), "--emit-gfa", str(out_path)]) == 0


def _objc_write(gfa_path: Path, tio_path: Path) -> None:
    _run_objc([str(gfa_path), "--write-tio", str(tio_path)])


def _objc_emit(tio_path: Path, out_path: Path) -> None:
    _run_objc([str(tio_path), "--emit-gfa", str(out_path)])


def _java_write(gfa_path: Path, tio_path: Path) -> None:
    _run_java([str(gfa_path), "--write-tio", str(tio_path)])


def _java_emit(tio_path: Path, out_path: Path) -> None:
    _run_java([str(tio_path), "--emit-gfa", str(out_path)])


_WRITERS = {"python": _py_write, "objc": _objc_write, "java": _java_write}
_EMITTERS = {"python": _py_emit, "objc": _objc_emit, "java": _java_emit}
_MATRIX = [(w, e) for w in _WRITERS for e in _EMITTERS]


@pytest.mark.parametrize("fixture", _FIXTURES)
@pytest.mark.parametrize(
    "writer,emitter", _MATRIX,
    ids=[f"{w}-write_{e}-emit" for w, e in _MATRIX])
def test_m98_container_matrix_byte_exact(writer, emitter, fixture, tmp_path):
    gfa = _materialise(tmp_path, fixture)
    src = _fixture_bytes(fixture)

    tio = tmp_path / f"{writer}.tio"
    _WRITERS[writer](gfa, tio)
    assert tio.exists(), f"{writer} --write-tio produced no file"

    out = tmp_path / f"{writer}_{emitter}.gfa"
    _EMITTERS[emitter](tio, out)
    assert out.exists(), f"{emitter} --emit-gfa produced no file"

    got = out.read_bytes()
    assert got == src, (
        f"cell ({writer} -> {emitter}) re-emission differs for "
        f"{fixture}: {len(got)} vs {len(src)} bytes"
    )
