"""M99: cross-language per-AU exchange over the blocks_v1 layout.

Python stream-writes a multi-block blocks_v1 genomic container, each
SDK's PerAU CLI encrypts it, each SDK's CLI decrypts a copy in place,
and Python verifies the restore is byte-identical (channel blobs and
block index) with the per-AU flags stripped. Two fixtures: a
multi-chromosome run with cross-chromosome mates, and an aligned run
whose sequences code through REF_DIFF_V2 against an embedded
reference. Cells whose SDK binary is absent skip, matching the M89
convention.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

pytest.importorskip("h5py")
import h5py

sys.path.insert(0, str(Path(__file__).parent))
from test_m89_cross_language import (  # type: ignore[import-not-found]
    _resolve_java_tool,
    _resolve_objc_tool,
)

from ttio import SpectralDataset
from ttio.genomic._blocks import slice_run
from ttio.genomic.stream_writer import GenomicStreamWriter
from ttio.written_genomic_run import WrittenGenomicRun

_PERAU_OBJC_TOOL = "TtioPerAU"
_PERAU_JAVA_CLASS = "global.thalion.ttio.tools.PerAUCli"


def _make_plain_run():
    rng = np.random.default_rng(29)
    n = 700
    lengths = rng.integers(60, 180, n).astype(np.uint32)
    lengths[100] = 0
    lengths[401] = 0
    offsets = np.zeros(n, dtype=np.uint64)
    offsets[1:] = np.cumsum(lengths[:-1])
    total = int(lengths.sum())
    half = n // 2
    return WrittenGenomicRun(
        acquisition_mode=7, reference_uri="", platform="ILLUMINA",
        sample_name="M99X",
        positions=np.arange(n, dtype=np.int64) * 40,
        mapping_qualities=np.full(n, 60, dtype=np.uint8),
        flags=np.full(n, 0x1, dtype=np.uint32),
        sequences=rng.choice(
            np.frombuffer(b"ACGTN", dtype=np.uint8), total,
            p=[0.24, 0.26, 0.25, 0.24, 0.01]),
        qualities=rng.integers(33, 73, total).astype(np.uint8),
        offsets=offsets, lengths=lengths,
        cigars=[(f"{int(l)}M" if l else "*") for l in lengths],
        read_names=[f"x{i:05d}" for i in range(n)],
        mate_chromosomes=(["chr2"] * half) + (["chr1"] * (n - half)),
        mate_positions=rng.integers(0, 10_000, n).astype(np.int64),
        template_lengths=rng.integers(-500, 500, n).astype(np.int32),
        chromosomes=(["chr1"] * half) + (["chr2"] * (n - half)),
    )


def _make_ref_diff_run():
    rng = np.random.default_rng(31)
    n, L = 240, 120
    ref = rng.choice(np.frombuffer(b"ACGT", dtype=np.uint8), 60_000)
    seq = np.zeros(n * L, dtype=np.uint8)
    for i in range(n):
        pos = i * 150
        seq[i * L:(i + 1) * L] = ref[pos:pos + L]
        seq[i * L + 13] = ord("A")
        seq[i * L + 77] = ord("T")
    return WrittenGenomicRun(
        acquisition_mode=7, reference_uri="m99xref",
        platform="ILLUMINA", sample_name="M99X",
        positions=np.arange(n, dtype=np.int64) * 150 + 1,
        mapping_qualities=np.full(n, 60, dtype=np.uint8),
        flags=np.zeros(n, dtype=np.uint32),
        sequences=seq,
        qualities=rng.integers(33, 73, n * L).astype(np.uint8),
        offsets=(np.arange(n, dtype=np.uint64) * L),
        lengths=np.full(n, L, dtype=np.uint32),
        cigars=[f"{L}M"] * n,
        read_names=[f"rd{i}" for i in range(n)],
        mate_chromosomes=[""] * n,
        mate_positions=np.full(n, -1, dtype=np.int64),
        template_lengths=np.zeros(n, dtype=np.int32),
        chromosomes=["chr1"] * n,
        reference_chrom_seqs={"chr1": bytes(ref.tobytes())},
        embed_reference=True,
    )


_FIXTURES = {"plain": _make_plain_run, "refdiff": _make_ref_diff_run}


def _write_blocks_file(path: Path, run, block_reads: int) -> None:
    SpectralDataset.write_minimal(str(path), title="m99x",
                                  isa_investigation_id="i", runs={})
    ds = SpectralDataset.open(str(path), writable=True)
    n = len(run.lengths)
    w = GenomicStreamWriter(ds.study_group, "run",
                            acquisition_mode=run.acquisition_mode,
                            reference_uri=run.reference_uri,
                            platform=run.platform,
                            sample_name=run.sample_name,
                            reference_chrom_seqs=run.reference_chrom_seqs,
                            embed_reference=(
                                run.reference_chrom_seqs is not None),
                            block_reads=block_reads)
    with ds, w:
        for s in range(0, n, 100):
            w.append_batch(slice_run(run, s, min(s + 100, n)))


def _blob_state(path: Path):
    with h5py.File(path, "r") as f:
        rg = f["study/genomic_runs/run"]
        return (
            rg["blocks/index"][...].tobytes(),
            bytes(rg["signal_channels/sequences/data"][...]),
            bytes(rg["signal_channels/qualities"][...]),
        )


def _features(path: Path) -> list[str]:
    with h5py.File(path, "r") as f:
        raw = f.attrs["ttio_features"]
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8")
    elif not isinstance(raw, str):
        raw = bytes(raw).decode("utf-8")
    return json.loads(raw)


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
        capture_output=True, env=env, timeout=600,
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
        capture_output=True, env=env, timeout=600,
    )
    assert proc.returncode == 0, (
        f"{_PERAU_JAVA_CLASS} {args} failed rc={proc.returncode}: "
        f"{proc.stderr.decode(errors='replace')[:500]}"
    )


_PERAU_CLIS = {"python": _py_perau, "objc": _objc_perau, "java": _java_perau}
_MATRIX = [(a, b) for a in _PERAU_CLIS for b in _PERAU_CLIS]


@pytest.mark.parametrize("fixture", list(_FIXTURES))
@pytest.mark.parametrize(
    "encryptor,decryptor", _MATRIX,
    ids=[f"{a}-encrypt_{b}-decrypt" for a, b in _MATRIX])
def test_m99_blocks_v1_exchange_byte_identical(encryptor, decryptor,
                                               fixture, tmp_path):
    run = _FIXTURES[fixture]()
    plain = tmp_path / "plain.tio"
    _write_blocks_file(plain, run, block_reads=150)
    before = _blob_state(plain)

    key = tmp_path / "key.bin"
    key.write_bytes(bytes(range(32)))

    enc = tmp_path / "enc.tio"
    _PERAU_CLIS[encryptor](["encrypt", str(plain), str(enc), str(key)])
    assert "opt_per_au_encryption" in _features(enc)
    with h5py.File(enc, "r") as f:
        sig = f["study/genomic_runs/run/signal_channels"]
        assert "sequences" not in sig and "qualities" not in sig
        assert (len(sig["sequences_segments"]) == len(run.lengths)
                and len(sig["qualities_segments"]) == len(run.lengths)), (
            "per-AU walker must emit one AU per read")

    work = tmp_path / f"{encryptor}_{decryptor}.tio"
    shutil.copyfile(enc, work)
    _PERAU_CLIS[decryptor](["decrypt-in-place", str(work), str(key)])

    assert "opt_per_au_encryption" not in _features(work)
    after = _blob_state(work)
    assert after[0] == before[0], "block index byte-identical"
    assert after[1] == before[1], "sequences blob byte-identical"
    assert after[2] == before[2], "qualities blob byte-identical"

    ds = SpectralDataset.open(str(work))
    gr = ds.genomic_runs["run"]
    n = len(run.lengths)
    for i in (0, n // 2, n - 1):
        rd = gr[i]
        lo = int(np.asarray(run.offsets)[i])
        ln = int(np.asarray(run.lengths)[i])
        assert rd.sequence.encode("ascii") == bytes(
            np.asarray(run.sequences[lo:lo + ln], dtype=np.uint8)
            .tobytes())
        assert rd.read_name == run.read_names[i]