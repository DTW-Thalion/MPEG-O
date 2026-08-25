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
import shutil
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


# --------------------------------------------------------------------------- #
# Encrypted exchange matrix: encryptor x decryptor via the PerAU CLIs.
# --------------------------------------------------------------------------- #

_PERAU_OBJC_TOOL = "TtioPerAU"
_PERAU_JAVA_CLASS = "global.thalion.ttio.tools.PerAUCli"


def _py_perau(args: list[str]) -> None:
    from ttio.tools.per_au_cli import main

    assert main(args) == 0


def _objc_perau(args: list[str]) -> None:
    tool = _resolve_objc_tool(_PERAU_OBJC_TOOL)
    if tool is None:
        pytest.skip(f"ObjC {_PERAU_OBJC_TOOL} binary not built")
    binary, env = tool
    proc = subprocess.run(
        [str(binary), *args],
        capture_output=True, env=env, timeout=240,
    )
    assert proc.returncode == 0, (
        f"{_PERAU_OBJC_TOOL} {args} failed rc={proc.returncode}: "
        f"{proc.stderr.decode(errors='replace')[:500]}"
    )


def _java_perau(args: list[str]) -> None:
    tool = _resolve_java_tool(_PERAU_JAVA_CLASS)
    if tool is None:
        pytest.skip("Java classpath not available")
    argv, env = tool
    proc = subprocess.run(
        [*argv, *args],
        capture_output=True, env=env, timeout=240,
    )
    assert proc.returncode == 0, (
        f"{_PERAU_JAVA_CLASS} {args} failed rc={proc.returncode}: "
        f"{proc.stderr.decode(errors='replace')[:500]}"
    )


_PERAU_CLIS = {"python": _py_perau, "objc": _objc_perau, "java": _java_perau}
_ENC_MATRIX = [(a, b) for a in _PERAU_CLIS for b in _PERAU_CLIS]

_SEG_GROUP = "study/assembly_graphs/graph_0001/segments"


def _features(path: Path) -> list[str]:
    import h5py

    with h5py.File(path, "r") as f:
        raw = f.attrs["ttio_features"]
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8")
    elif not isinstance(raw, str):
        raw = bytes(raw).decode("utf-8")
    return json.loads(raw)


@pytest.mark.parametrize("fixture", _FIXTURES)
@pytest.mark.parametrize(
    "encryptor,decryptor", _ENC_MATRIX,
    ids=[f"{a}-encrypt_{b}-decrypt" for a, b in _ENC_MATRIX])
def test_m98_encrypted_exchange_byte_exact(encryptor, decryptor, fixture,
                                            tmp_path):
    import h5py

    gfa = _materialise(tmp_path, fixture)
    src = _fixture_bytes(fixture)

    plain = tmp_path / "plain.tio"
    _py_write(gfa, plain)

    key = tmp_path / "key.bin"
    key.write_bytes(bytes(range(32)))

    enc = tmp_path / "enc.tio"
    _PERAU_CLIS[encryptor](["encrypt", str(plain), str(enc), str(key)])

    # The encryptor must actually have engaged on the graph channel:
    # flag set, sequences replaced by the per-AU segment layout.
    assert "opt_per_au_encryption" in _features(enc)
    with h5py.File(enc, "r") as f:
        seg = f[_SEG_GROUP]
        assert "sequences_segments" in seg
        assert "sequences" not in seg
        assert len(seg["sequences_segments"]) == len(seg["records"]), (
            "per-AU walker must emit one AU per segment record"
        )

    work = tmp_path / f"{encryptor}_{decryptor}.tio"
    shutil.copyfile(enc, work)
    _PERAU_CLIS[decryptor](["decrypt-in-place", str(work), str(key)])

    # Flag stripped, raw channel restored, segment layout gone.
    assert "opt_per_au_encryption" not in _features(work)
    with h5py.File(work, "r") as f:
        seg = f[_SEG_GROUP]
        assert "sequences" in seg
        assert "sequences_segments" not in seg

    out = tmp_path / f"{encryptor}_{decryptor}.gfa"
    _py_emit(work, out)
    got = out.read_bytes()
    assert got == src, (
        f"encrypted cell ({encryptor} -> {decryptor}) re-emission differs "
        f"for {fixture}: {len(got)} vs {len(src)} bytes"
    )
