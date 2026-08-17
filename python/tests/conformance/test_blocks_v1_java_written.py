"""A blocks_v1 file written by Java opens in Python and decodes to the
source BAM (format-spec 10.12 cross-language contract, Java writer side)."""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

from _digests import genomic_run_sam11_md5, sam11_md5
from ttio.spectral_dataset import SpectralDataset
from tests.validation.test_cross_language_smoke import _resolve_java_verify

HERE = Path(__file__).resolve().parent
BAM = HERE.parent / "fixtures/genomic/m87_test.bam"


def _write_java_blocks(tmp_path: Path, block_reads: int) -> Path:
    java = _resolve_java_verify()
    if java is None:
        pytest.skip("Java classpath not available")
    argv_prefix, env = java
    argv = argv_prefix[:-1] + ["global.thalion.ttio.tools.TtioWriteGenomicFixture"]
    out = tmp_path / f"java_blocks_{block_reads}.tio"
    proc = subprocess.run(argv + [str(out), "--blocks", str(BAM), str(block_reads)],
                          capture_output=True, text=True, env=env, timeout=120)
    if proc.returncode != 0:
        pytest.fail(f"TtioWriteGenomicFixture --blocks exit {proc.returncode}: {proc.stderr.strip()}")
    return out


@pytest.mark.parametrize("block_reads", [3, 1000])
def test_python_reads_java_blocks_v1(tmp_path, block_reads):
    out = _write_java_blocks(tmp_path, block_reads)
    with SpectralDataset.open(str(out)) as ds:
        g = ds.genomic_runs["genomic_0001"]
        assert g.layout == "blocks_v1"
        assert len(g) == 10
        assert g.block_count >= (3 if block_reads == 3 else 1)
        rows = g.group.open_group("blocks").open_dataset("index").read_rows()
        assert len(rows) == g.block_count
        assert sum(int(r["n_reads"]) for r in rows) == 10
        assert [r.read_name for r in g.iter_reads()] == [g[i].read_name for i in range(10)]
        if shutil.which("samtools"):
            assert genomic_run_sam11_md5(g) == sam11_md5(BAM)
