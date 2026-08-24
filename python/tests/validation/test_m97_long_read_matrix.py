"""M97: HiFi- and ONT-UL-shaped fixtures through the 3x3 transport matrix.

The M89.6 matrix proves the wire format cross-pair on a 3-read
short-read fixture. Long reads change the shapes that matter — per-read
base counts in the hundreds of thousands, block payloads dominated by
a few reads — so this module runs the same 9 (writer, reader) cells
over two deterministic long-read fixtures:

* ``hifi``   — 300 reads, 1,000-2,000 bases each (~450 kb)
* ``ont_ul`` — 8 reads, 80,000-160,000 bases each (~1 Mb)

Encoders/decoders and skip rules are reused from
``test_m89_cross_language``.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).parent))
from test_m89_cross_language import (  # type: ignore[import-not-found]
    _ENCODERS,
    _DECODERS,
    _MATRIX,
)

from ttio import SpectralDataset
from ttio.written_genomic_run import WrittenGenomicRun

_SHAPES = {
    # name -> (n_reads, min_len, max_len, platform, read_role)
    "hifi":   (300, 1_000, 2_000, "PacBio HiFi", "hifi"),
    "ont_ul": (8, 80_000, 160_000, "ONT", "ont_ul"),
}

_BASES = np.frombuffer(b"ACGT", dtype=np.uint8)


def _build_run(shape: str) -> WrittenGenomicRun:
    """Deterministic unaligned long-read run for ``shape``."""
    n_reads, lo, hi, platform, role = _SHAPES[shape]
    rng = np.random.default_rng(97)
    lengths = rng.integers(lo, hi + 1, size=n_reads).astype(np.uint32)
    total = int(lengths.sum())
    sequences = _BASES[rng.integers(0, 4, size=total)]
    qualities = rng.integers(2, 41, size=total).astype(np.uint8)
    offsets = np.zeros(n_reads, dtype=np.uint64)
    np.cumsum(lengths[:-1], out=offsets[1:])
    return WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="",
        platform=platform,
        sample_name="HG002",
        positions=np.full(n_reads, -1, dtype=np.int64),
        mapping_qualities=np.zeros(n_reads, dtype=np.uint8),
        flags=np.full(n_reads, 4, dtype=np.uint32),  # unmapped
        sequences=sequences,
        qualities=qualities,
        offsets=offsets,
        lengths=lengths,
        cigars=["*"] * n_reads,
        read_names=[f"{shape}_{i:05d}" for i in range(n_reads)],
        mate_chromosomes=[""] * n_reads,
        mate_positions=np.full(n_reads, -1, dtype=np.int64),
        template_lengths=np.zeros(n_reads, dtype=np.int32),
        chromosomes=["*"] * n_reads,
        read_role=role,
    )


def _write_source(path: Path, shape: str) -> Path:
    SpectralDataset.write_minimal(
        path,
        title=f"M97 {shape} matrix fixture",
        isa_investigation_id="ISA-M97-XLANG",
        runs={},
        genomic_runs={"genomic_0001": _build_run(shape)},
    )
    return path


def _verify_round_trip(rt_tio: Path, shape: str) -> None:
    """Content check against a regenerated copy of the fixture: read
    counts, per-read lengths, the @read_role attribute, and the
    byte-exact sequence + quality payload of the first, middle, and
    last reads."""
    expect = _build_run(shape)
    n = len(expect.lengths)
    with SpectralDataset.open(rt_tio) as ds:
        gr = ds.genomic_runs["genomic_0001"]
        assert len(gr) == n
        # M97: @read_role rides the .tis run-metadata JSON, so every
        # (writer, reader) cell must deliver it into the container.
        assert gr.read_role == expect.read_role, (
            f"{shape}: read_role {gr.read_role!r} != "
            f"{expect.read_role!r}")
        np.testing.assert_array_equal(
            gr.index.lengths, expect.lengths)
        for i in (0, n // 2, n - 1):
            start = int(expect.offsets[i])
            length = int(expect.lengths[i])
            r = gr[i]
            assert r.sequence.encode("ascii") == \
                expect.sequences[start:start + length].tobytes(), (
                f"{shape}: read {i} sequence bytes diverge")
            assert r.qualities == \
                expect.qualities[start:start + length].tobytes(), (
                f"{shape}: read {i} quality bytes diverge")


@pytest.mark.parametrize("shape", list(_SHAPES), ids=list(_SHAPES))
@pytest.mark.parametrize(
    "writer,reader", _MATRIX,
    ids=[f"{w}-encode_{r}-decode" for w, r in _MATRIX],
)
def test_m97_long_read_3x3_transport(
    writer: str, reader: str, shape: str, tmp_path: Path,
) -> None:
    source_tio = _write_source(tmp_path / "source.tio", shape)
    cell_tis = tmp_path / f"{writer}-{reader}.tis"
    cell_tio = tmp_path / f"{writer}-{reader}.tio"
    _ENCODERS[writer](source_tio, cell_tis)
    assert cell_tis.exists() and cell_tis.stat().st_size > 0
    _DECODERS[reader](cell_tis, cell_tio)
    assert cell_tio.exists()
    _verify_round_trip(cell_tio, shape)


def test_m97_read_role_survives_python_container(tmp_path: Path) -> None:
    """@read_role lands on the source container before any transport."""
    source = _write_source(tmp_path / "source.tio", "ont_ul")
    with SpectralDataset.open(source) as ds:
        assert ds.genomic_runs["genomic_0001"].read_role == "ont_ul"
