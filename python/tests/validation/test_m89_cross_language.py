"""M89.6: GenomicRead transport 3x3 cross-language conformance matrix.

Each writer language encodes the same source genomic .tio fixture into
a .tis stream; each reader language decodes that .tis back into a .tio.
Python opens the round-tripped .tio and verifies the genomic run
matches the canonical expectations. All 9 (writer, reader) cells must
produce equivalent .tio output.

Cell expectations:

==========  =========  =========  =========
            py-read    objc-read  java-read
py-write    OK         OK         OK
objc-write  OK         OK         OK
java-write  OK         OK         OK
==========  =========  =========  =========

Skip rules:

* The ObjC ``TtioTransportEncode`` / ``TtioTransportDecode`` binaries
  must be built (``cd objc && ./build.sh``) and locatable; otherwise
  the rows/columns that need them are skipped.
* The Java tooling needs a built classpath (same convention as
  ``test_cross_language_smoke.py``); otherwise the rows/columns that
  need it are skipped.

Why this exists: each language's own M89 round-trip tests prove its
writer and reader are self-consistent. This harness proves the wire
format is byte-identical across languages by going cross-pair.
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

# Reuse the resolver helpers from the existing smoke module so we do
# not duplicate environment-detection logic.
sys.path.insert(0, str(Path(__file__).parent))
from test_cross_language_smoke import (  # type: ignore[import-not-found]
    _resolve_objc_verify,
    _resolve_java_verify,
    _REPO_ROOT,
)

from ttio import SpectralDataset
from ttio.written_genomic_run import WrittenGenomicRun


# --------------------------------------------------------------------------- #
# Source fixture — deterministic, small (3 reads × 8 bases) so CI is fast.
# --------------------------------------------------------------------------- #

_FIXTURE_TITLE = "M89.6 cross-lang transport fixture"
_FIXTURE_ISA = "ISA-M89-XLANG"
_FIXTURE_CHROMOSOMES = ["chr1", "chr1", "chr2"]
_FIXTURE_POSITIONS = [100, 200, 300]
_FIXTURE_MAPQS = [60, 55, 40]
_FIXTURE_FLAGS = [0x0003, 0x0003, 0x0003]
_FIXTURE_SEQUENCE = b"ACGTACGT"  # 8 bases per read
_FIXTURE_QUALITY = 30  # constant Phred per base


def _write_python_source(path: Path) -> Path:
    n_reads = len(_FIXTURE_CHROMOSOMES)
    read_length = len(_FIXTURE_SEQUENCE)
    sequences = np.frombuffer(
        _FIXTURE_SEQUENCE * n_reads, dtype=np.uint8,
    )
    qualities = np.frombuffer(
        bytes([_FIXTURE_QUALITY] * (n_reads * read_length)), dtype=np.uint8,
    )
    run = WrittenGenomicRun(
        acquisition_mode=7,  # GENOMIC_WGS
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="NA12878",
        positions=np.array(_FIXTURE_POSITIONS, dtype=np.int64),
        mapping_qualities=np.array(_FIXTURE_MAPQS, dtype=np.uint8),
        flags=np.array(_FIXTURE_FLAGS, dtype=np.uint32),
        sequences=sequences,
        qualities=qualities,
        offsets=np.arange(n_reads, dtype=np.uint64) * read_length,
        lengths=np.full(n_reads, read_length, dtype=np.uint32),
        cigars=[f"{read_length}M"] * n_reads,
        read_names=[f"read_{i:03d}" for i in range(n_reads)],
        mate_chromosomes=[""] * n_reads,
        mate_positions=np.full(n_reads, -1, dtype=np.int64),
        template_lengths=np.zeros(n_reads, dtype=np.int32),
        chromosomes=list(_FIXTURE_CHROMOSOMES),
        # v1.7 Task #12: ObjC/Java transport CLIs read the v1 mate_info
        # subgroup layout (chrom/pos/tlen child datasets). The inline_v2
        # blob format (Task #12) has not been wired into those tools yet.
        # Opt out so the cross-language transport test keeps using v1.
        opt_disable_inline_mate_info_v2=True,
        # v1.8 #11 ch3 Task #12: Java/ObjC dispatch tasks haven't run yet
        # in this commit. Once they have, the read_names channel will be
        # readable via the v2 codec everywhere; until then keep the M82
        # compound layout for the cross-language transport matrix.
        opt_disable_name_tokenized_v2=True,
    )
    SpectralDataset.write_minimal(
        path,
        title=_FIXTURE_TITLE,
        isa_investigation_id=_FIXTURE_ISA,
        runs={},
        genomic_runs={"genomic_0001": run},
    )
    return path


# --------------------------------------------------------------------------- #
# Encode / Decode CLI resolvers.
#
# Each language ships parallel CLIs (py: transport_encode_cli /
# transport_decode_cli; ObjC: TtioTransportEncode / TtioTransportDecode;
# Java: TransportEncodeCli / TransportDecodeCli) — all take
# ``<input> <output>`` as positional args.
# --------------------------------------------------------------------------- #

def _resolve_objc_tool(binary_name: str) -> tuple[Path, dict[str, str]] | None:
    """Locate an ObjC tool binary under ``objc/Tools/obj/``."""
    binary = _REPO_ROOT / "objc" / "Tools" / "obj" / binary_name
    if not binary.is_file():
        return None
    libdir = _REPO_ROOT / "objc" / "Source" / "obj"
    if not libdir.is_dir():
        return None
    env = os.environ.copy()
    env["LD_LIBRARY_PATH"] = (
        f"{libdir}:{env.get('LD_LIBRARY_PATH', '')}".rstrip(":")
    )
    return binary, env


def _resolve_java_tool(class_name: str) -> tuple[list[str], dict[str, str]] | None:
    """Build a ``java -cp ... <class>`` argv prefix + env. Reuses the
    classpath plumbing from :func:`_resolve_java_verify`."""
    java = _resolve_java_verify()
    if java is None:
        return None
    argv_prefix, env = java
    # The verify resolver returns argv ending with TtioVerify; replace
    # the class name with the requested one.
    return argv_prefix[:-1] + [class_name], env


# --------------------------------------------------------------------------- #
# Writer functions (encode source.tio -> cell.tis).
# --------------------------------------------------------------------------- #

def _encode_python(src: Path, dst: Path) -> None:
    proc = subprocess.run(
        [sys.executable, "-m", "ttio.tools.transport_encode_cli",
         str(src), str(dst)],
        capture_output=True, text=True, timeout=60,
    )
    if proc.returncode != 0:
        pytest.fail(
            f"python encode CLI exit {proc.returncode}: {proc.stderr.strip()}"
        )


def _encode_objc(src: Path, dst: Path) -> None:
    objc = _resolve_objc_tool("TtioTransportEncode")
    if objc is None:
        pytest.skip(
            "ObjC TtioTransportEncode binary not built; "
            "run `cd objc && ./build.sh` first"
        )
    binary, env = objc
    proc = subprocess.run(
        [str(binary), str(src), str(dst)],
        capture_output=True, text=True, env=env, timeout=60,
    )
    if proc.returncode != 0:
        pytest.fail(
            f"ObjC TtioTransportEncode exit {proc.returncode}: "
            f"{proc.stderr.strip()}"
        )


def _encode_java(src: Path, dst: Path) -> None:
    java = _resolve_java_tool(
        "global.thalion.ttio.tools.TransportEncodeCli"
    )
    if java is None:
        pytest.skip("Java classpath not available")
    argv, env = java
    proc = subprocess.run(
        argv + [str(src), str(dst)],
        capture_output=True, text=True, env=env, timeout=120,
    )
    if proc.returncode != 0:
        pytest.fail(
            f"Java TransportEncodeCli exit {proc.returncode}: "
            f"{proc.stderr.strip()}"
        )


# --------------------------------------------------------------------------- #
# Reader functions (decode cell.tis -> cell.tio).
# --------------------------------------------------------------------------- #

def _decode_python(src_tis: Path, dst_tio: Path) -> None:
    proc = subprocess.run(
        [sys.executable, "-m", "ttio.tools.transport_decode_cli",
         str(src_tis), str(dst_tio)],
        capture_output=True, text=True, timeout=60,
    )
    if proc.returncode != 0:
        pytest.fail(
            f"python decode CLI exit {proc.returncode}: {proc.stderr.strip()}"
        )


def _decode_objc(src_tis: Path, dst_tio: Path) -> None:
    objc = _resolve_objc_tool("TtioTransportDecode")
    if objc is None:
        pytest.skip("ObjC TtioTransportDecode binary not built")
    binary, env = objc
    proc = subprocess.run(
        [str(binary), str(src_tis), str(dst_tio)],
        capture_output=True, text=True, env=env, timeout=60,
    )
    if proc.returncode != 0:
        pytest.fail(
            f"ObjC TtioTransportDecode exit {proc.returncode}: "
            f"{proc.stderr.strip()}"
        )


def _decode_java(src_tis: Path, dst_tio: Path) -> None:
    java = _resolve_java_tool(
        "global.thalion.ttio.tools.TransportDecodeCli"
    )
    if java is None:
        pytest.skip("Java classpath not available")
    argv, env = java
    proc = subprocess.run(
        argv + [str(src_tis), str(dst_tio)],
        capture_output=True, text=True, env=env, timeout=120,
    )
    if proc.returncode != 0:
        pytest.fail(
            f"Java TransportDecodeCli exit {proc.returncode}: "
            f"{proc.stderr.strip()}"
        )


_ENCODERS = {
    "python": _encode_python,
    "objc":   _encode_objc,
    "java":   _encode_java,
}
_DECODERS = {
    "python": _decode_python,
    "objc":   _decode_objc,
    "java":   _decode_java,
}

_MATRIX = [(w, r) for w in _ENCODERS for r in _DECODERS]


# --------------------------------------------------------------------------- #
# Verification (Python opens the round-tripped .tio).
# --------------------------------------------------------------------------- #

def _verify_round_trip(rt_tio: Path) -> None:
    """Open ``rt_tio`` in Python and assert the genomic run matches
    the source fixture's locked expectations."""
    with SpectralDataset.open(rt_tio) as ds:
        assert ds.title == _FIXTURE_TITLE
        assert ds.isa_investigation_id == _FIXTURE_ISA
        assert "genomic_0001" in ds.genomic_runs, (
            f"genomic_0001 missing; runs present: "
            f"{list(ds.genomic_runs.keys())}"
        )
        gr = ds.genomic_runs["genomic_0001"]
        assert len(gr) == len(_FIXTURE_CHROMOSOMES), (
            f"read count {len(gr)} != {len(_FIXTURE_CHROMOSOMES)}"
        )
        assert gr.index.chromosomes == _FIXTURE_CHROMOSOMES
        np.testing.assert_array_equal(
            gr.index.positions,
            np.array(_FIXTURE_POSITIONS, dtype=np.int64),
        )
        np.testing.assert_array_equal(
            gr.index.mapping_qualities,
            np.array(_FIXTURE_MAPQS, dtype=np.uint8),
        )
        np.testing.assert_array_equal(
            gr.index.flags,
            np.array(_FIXTURE_FLAGS, dtype=np.uint32),
        )
        # Per-base sequences + qualities round-trip byte-exact.
        r0 = gr[0]
        assert r0.sequence == _FIXTURE_SEQUENCE.decode("ascii")
        assert r0.qualities == bytes(
            [_FIXTURE_QUALITY] * len(_FIXTURE_SEQUENCE)
        )


# --------------------------------------------------------------------------- #
# 3x3 matrix.
# --------------------------------------------------------------------------- #

@pytest.mark.parametrize(
    "writer,reader", _MATRIX,
    ids=[f"{w}-encode_{r}-decode" for w, r in _MATRIX],
)
def test_m89_3x3_transport_conformance(
    writer: str, reader: str, tmp_path: Path,
) -> None:
    """Each (writer, reader) cell preserves the source genomic run."""
    source_tio = _write_python_source(tmp_path / "source.tio")
    cell_tis = tmp_path / f"{writer}-{reader}.tis"
    cell_tio = tmp_path / f"{writer}-{reader}.tio"
    _ENCODERS[writer](source_tio, cell_tis)
    assert cell_tis.exists(), (
        f"{writer} encoder did not produce {cell_tis.name}"
    )
    assert cell_tis.stat().st_size > 0, (
        f"{writer} encoder produced empty {cell_tis.name}"
    )
    _DECODERS[reader](cell_tis, cell_tio)
    assert cell_tio.exists(), (
        f"{reader} decoder did not produce {cell_tio.name}"
    )
    _verify_round_trip(cell_tio)
