"""A blocks_v1 file written by Objective-C opens in Python and decodes to
the source BAM (format-spec 10.12 cross-language contract, ObjC writer
side)."""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from _digests import genomic_run_sam11_md5, sam11_md5
from ttio.spectral_dataset import SpectralDataset

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "validation"))
from test_m82_3x3_matrix import _resolve_objc_writer  # noqa: E402
BAM = HERE.parent / "fixtures/genomic/m87_test.bam"


def _write_objc_blocks(tmp_path: Path, block_reads: int) -> Path:
    if not shutil.which("samtools"):
        pytest.skip("samtools not on PATH (the ObjC BAM reader needs it)")
    objc = _resolve_objc_writer()
    if objc is None:
        pytest.skip("ObjC TtioWriteGenomicFixture not built")
    binary, env = objc
    out = tmp_path / f"objc_blocks_{block_reads}.tio"
    proc = subprocess.run([str(binary), str(out), "--blocks", str(BAM), str(block_reads)],
                          capture_output=True, text=True, env=env, timeout=120)
    if proc.returncode != 0:
        pytest.fail(f"TtioWriteGenomicFixture --blocks exit {proc.returncode}: {proc.stderr.strip()}")
    return out


@pytest.mark.parametrize("block_reads", [3, 1000])
def test_python_reads_objc_blocks_v1(tmp_path, block_reads):
    out = _write_objc_blocks(tmp_path, block_reads)
    with SpectralDataset.open(str(out)) as ds:
        g = ds.genomic_runs["genomic_0001"]
        assert g.layout == "blocks_v1"
        assert len(g) == 10
        assert g.block_count >= (3 if block_reads == 3 else 1)
        rows = g.group.open_group("blocks").open_dataset("index").read_rows()
        assert len(rows) == g.block_count
        assert sum(int(r["n_reads"]) for r in rows) == 10
        assert [r.read_name for r in g.iter_reads()] == [g[i].read_name for i in range(10)]
        assert genomic_run_sam11_md5(g) == sam11_md5(BAM)
