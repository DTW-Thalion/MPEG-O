"""Phase 2c-T: bulk-mode cross-language conformance + byte-identity.

Mirrors the M89 3x3 (writer × reader) matrix but with bulk mode
enabled on the writer. Asserts a stronger contract than the per-AU
test:

1. The mate_info / read_names / refdiff_v2 v2 codec blobs in the
   round-tripped ``.tio`` are byte-identical to the source
   ``.tio``'s blobs (the bulk-mode contract — see
   ``docs/transport-spec.md`` §6.4).
2. The round-tripped run still passes the standard semantic
   assertions (chromosomes, positions, mapq, flags, sequences,
   qualities round-trip correctly).

Skip rules match :mod:`test_m89_cross_language`: ObjC/Java cells
skip when the ObjC binaries / Java classpath are unavailable.
"""
from __future__ import annotations

import hashlib
import os
import subprocess
import sys
from pathlib import Path

import h5py
import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).parent))
from test_cross_language_smoke import (  # type: ignore[import-not-found]
    _resolve_objc_verify,
    _resolve_java_verify,
    _REPO_ROOT,
)
from test_m89_cross_language import (  # type: ignore[import-not-found]
    _resolve_objc_tool,
    _resolve_java_tool,
)

from ttio import SpectralDataset
from ttio.written_genomic_run import WrittenGenomicRun


# Richer fixture than the m89 baseline: 6 reads with varied
# read_names (different widths + punctuation) and non-trivial
# mate_chromosomes so the bulk-mode mate-blob carriage is
# meaningfully exercised.
_FIXTURE_TITLE = "Phase 2c-T bulk-mode cross-lang fixture"
_FIXTURE_ISA = "ISA-2C-T-BULK"
_FIXTURE_N = 6
_FIXTURE_CHROMOSOMES = ["chr1"] * _FIXTURE_N
_FIXTURE_POSITIONS = [100, 200, 300, 400, 500, 600]
_FIXTURE_MAPQS = [60, 55, 40, 30, 20, 10]
_FIXTURE_FLAGS = [0x0003] * _FIXTURE_N
_FIXTURE_READ_NAMES = [
    "read_001",
    "read.002.lane.1",
    "x:001:002",
    "long_read_name_with_extras",
    "y",
    "ABC123XYZ_456",
]
_FIXTURE_MATE_CHROMS = ["=", "chr2", "chr1", "chr3", "=", "chr2"]
_FIXTURE_MATE_POSITIONS = [101, 5000, 250, 9000, 502, 6000]
_FIXTURE_TEMPLATE_LENGTHS = [100, 0, 50, 0, -50, 200]
_FIXTURE_SEQUENCE = b"ACGTACGT"  # 8 bases per read
_FIXTURE_QUALITY = 30


def _native_lib_available() -> bool:
    """Phase 2c-T requires libttio_rans for v2 codec encode at write
    time. Skip the entire test module when missing — the source
    fixture cannot be created."""
    rans = os.environ.get("TTIO_RANS_LIB_PATH", "")
    if rans and os.path.isfile(rans):
        return True
    candidate = _REPO_ROOT / "native" / "_build" / "libttio_rans.so"
    if candidate.is_file():
        os.environ.setdefault("TTIO_RANS_LIB_PATH", str(candidate))
        return True
    return False


pytestmark = pytest.mark.skipif(
    not _native_lib_available(),
    reason="Phase 2c-T requires libttio_rans (set TTIO_RANS_LIB_PATH "
           "or build native/_build/libttio_rans.so)",
)


def _write_python_source(path: Path) -> Path:
    n = _FIXTURE_N
    sequences = np.frombuffer(
        _FIXTURE_SEQUENCE * n, dtype=np.uint8,
    )
    qualities = np.frombuffer(
        bytes([_FIXTURE_QUALITY] * (n * len(_FIXTURE_SEQUENCE))),
        dtype=np.uint8,
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
        offsets=np.arange(n, dtype=np.uint64) * len(_FIXTURE_SEQUENCE),
        lengths=np.full(n, len(_FIXTURE_SEQUENCE), dtype=np.uint32),
        cigars=[f"{len(_FIXTURE_SEQUENCE)}M"] * n,
        read_names=list(_FIXTURE_READ_NAMES),
        mate_chromosomes=list(_FIXTURE_MATE_CHROMS),
        mate_positions=np.array(_FIXTURE_MATE_POSITIONS, dtype=np.int64),
        template_lengths=np.array(
            _FIXTURE_TEMPLATE_LENGTHS, dtype=np.int32,
        ),
        chromosomes=list(_FIXTURE_CHROMOSOMES),
        # blocks_v1 read support in Java and ObjC lands with their
        # streaming specs; until then the cross-language genomic
        # fixtures use the v1.8 whole-channel layout.
        opt_legacy_whole_channel=True,
    )
    SpectralDataset.write_minimal(
        path,
        title=_FIXTURE_TITLE,
        isa_investigation_id=_FIXTURE_ISA,
        runs={},
        genomic_runs={"genomic_0001": run},
    )
    return path


def _read_blobs(tio_path: Path) -> dict[str, bytes | None]:
    """Pull the verbatim v2 blob bytes out of a .tio for byte-identity
    comparison. Missing blobs return None so the assertions can
    distinguish 'absent' from 'present-but-empty'."""
    out: dict[str, bytes | None] = {
        "mate_info": None,
        "read_names": None,
        "ref_diff": None,
    }
    with h5py.File(tio_path, "r") as f:
        sc = "/study/genomic_runs/genomic_0001/signal_channels"
        if f"{sc}/mate_info/inline_v2" in f:
            out["mate_info"] = bytes(f[f"{sc}/mate_info/inline_v2"][:].tobytes())
        if f"{sc}/read_names" in f:
            ds = f[f"{sc}/read_names"]
            comp = int(ds.attrs.get("compression", 0)) if "compression" in ds.attrs else 0
            if comp == 15:
                out["read_names"] = bytes(ds[:].tobytes())
        if f"{sc}/sequences/refdiff_v2" in f:
            out["ref_diff"] = bytes(f[f"{sc}/sequences/refdiff_v2"][:].tobytes())
    return out


# ---------------------------------------------------------- encoders / decoders

def _encode_python(src: Path, dst: Path) -> None:
    proc = subprocess.run(
        [sys.executable, "-m", "ttio.tools.transport_encode_cli",
         "--bulk", str(src), str(dst)],
        capture_output=True, text=True, timeout=60,
    )
    if proc.returncode != 0:
        pytest.fail(
            f"python --bulk encode exit {proc.returncode}: "
            f"{proc.stderr.strip()}"
        )


def _encode_objc(src: Path, dst: Path) -> None:
    objc = _resolve_objc_tool("TtioTransportEncode")
    if objc is None:
        pytest.skip("ObjC TtioTransportEncode binary not built")
    binary, env = objc
    proc = subprocess.run(
        [str(binary), "--bulk", str(src), str(dst)],
        capture_output=True, text=True, env=env, timeout=60,
    )
    if proc.returncode != 0:
        pytest.fail(
            f"ObjC --bulk encode exit {proc.returncode}: "
            f"{proc.stderr.strip()}"
        )


def _encode_java(src: Path, dst: Path) -> None:
    java = _resolve_java_tool("global.thalion.ttio.tools.TransportEncodeCli")
    if java is None:
        pytest.skip("Java classpath not available")
    argv, env = java
    proc = subprocess.run(
        argv + ["--bulk", str(src), str(dst)],
        capture_output=True, text=True, env=env, timeout=120,
    )
    if proc.returncode != 0:
        pytest.fail(
            f"Java --bulk encode exit {proc.returncode}: "
            f"{proc.stderr.strip()}"
        )


def _decode_python(src_tis: Path, dst_tio: Path) -> None:
    proc = subprocess.run(
        [sys.executable, "-m", "ttio.tools.transport_decode_cli",
         str(src_tis), str(dst_tio)],
        capture_output=True, text=True, timeout=60,
    )
    if proc.returncode != 0:
        pytest.fail(
            f"python decode exit {proc.returncode}: {proc.stderr.strip()}"
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
            f"ObjC decode exit {proc.returncode}: {proc.stderr.strip()}"
        )


def _decode_java(src_tis: Path, dst_tio: Path) -> None:
    java = _resolve_java_tool("global.thalion.ttio.tools.TransportDecodeCli")
    if java is None:
        pytest.skip("Java classpath not available")
    argv, env = java
    proc = subprocess.run(
        argv + [str(src_tis), str(dst_tio)],
        capture_output=True, text=True, env=env, timeout=120,
    )
    if proc.returncode != 0:
        pytest.fail(
            f"Java decode exit {proc.returncode}: {proc.stderr.strip()}"
        )


_ENCODERS = {"python": _encode_python, "objc": _encode_objc, "java": _encode_java}
_DECODERS = {"python": _decode_python, "objc": _decode_objc, "java": _decode_java}
_MATRIX = [(w, r) for w in _ENCODERS for r in _DECODERS]


# ---------------------------------------------------------- verification

def _sha(blob: bytes | None) -> str:
    if blob is None:
        return "absent"
    return hashlib.sha256(blob).hexdigest()[:16]


def _verify_round_trip(rt_tio: Path, src_tio: Path) -> None:
    """Phase 2c-T contract:

    1. Semantic round-trip — chromosomes, positions, mapping_qualities,
       flags, sequences, qualities preserved.
    2. Byte-identity — mate_info/inline_v2 and read_names blobs in
       the round-tripped file are byte-equal to the source's blobs.
    """
    with SpectralDataset.open(rt_tio) as ds:
        assert ds.title == _FIXTURE_TITLE
        assert ds.isa_investigation_id == _FIXTURE_ISA
        gr = ds.genomic_runs["genomic_0001"]
        assert len(gr) == _FIXTURE_N
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
        # Sequence + quality bytes round-trip per-read.
        for i in range(_FIXTURE_N):
            r = gr[i]
            assert r.sequence == _FIXTURE_SEQUENCE.decode("ascii")
            assert r.qualities == bytes(
                [_FIXTURE_QUALITY] * len(_FIXTURE_SEQUENCE)
            )

    # The byte-identity contract — bulk mode's whole point.
    src_blobs = _read_blobs(src_tio)
    rt_blobs = _read_blobs(rt_tio)
    for name in ("mate_info", "read_names"):
        assert src_blobs[name] is not None, (
            f"source missing expected {name} blob"
        )
        assert rt_blobs[name] is not None, (
            f"round-trip dropped {name} blob (sha src={_sha(src_blobs[name])})"
        )
        assert src_blobs[name] == rt_blobs[name], (
            f"{name} blob bytes differ across bulk-mode transport: "
            f"source sha={_sha(src_blobs[name])}, "
            f"round-trip sha={_sha(rt_blobs[name])}"
        )
    # ref_diff is optional (small fixture has no reference embedded).
    if src_blobs["ref_diff"] is not None:
        assert src_blobs["ref_diff"] == rt_blobs["ref_diff"]


# ---------------------------------------------------------- 3x3 matrix

@pytest.mark.parametrize(
    "writer,reader", _MATRIX,
    ids=[f"{w}-encode_{r}-decode" for w, r in _MATRIX],
)
def test_phase_2c_t_bulk_mode_3x3(
    writer: str, reader: str, tmp_path: Path,
) -> None:
    """Each (writer, reader) bulk-mode cell preserves blob byte-identity."""
    source_tio = _write_python_source(tmp_path / "source.tio")
    cell_tis = tmp_path / f"{writer}-{reader}.bulk.tis"
    cell_tio = tmp_path / f"{writer}-{reader}.bulk.tio"
    _ENCODERS[writer](source_tio, cell_tis)
    assert cell_tis.exists() and cell_tis.stat().st_size > 0
    _DECODERS[reader](cell_tis, cell_tio)
    assert cell_tio.exists()
    _verify_round_trip(cell_tio, source_tio)
