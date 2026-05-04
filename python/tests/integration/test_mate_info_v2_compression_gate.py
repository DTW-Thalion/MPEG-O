"""Layer 4 — chr22 ratio gate per spec §9.4.

Encodes the chr22 NA12878 lean+mapped corpus end-to-end via the
BamReader + SpectralDataset.write_minimal path with v2 default ON vs
v2 disabled (opt-out).  Asserts savings >= 5 MB; logs per-substream
byte breakdown to stdout.

The hard gate is the formal acceptance criterion for mate_info v2
shipping in v1.7.  Target was 7-8 MB; gate is 5 MB.

Run with::

    TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so \\
        python -m pytest python/tests/integration/test_mate_info_v2_compression_gate.py \\
        -m integration -v -s
"""
from __future__ import annotations

from pathlib import Path

import pytest

from ttio.codecs import mate_info_v2 as miv2

REPO_ROOT = Path(__file__).resolve().parents[3]
CHR22_BAM = REPO_ROOT / "data" / "genomic" / "na12878" / "na12878.chr22.lean.mapped.bam"

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(
        not miv2.HAVE_NATIVE_LIB,
        reason="needs libttio_rans (set TTIO_RANS_LIB_PATH)",
    ),
    pytest.mark.skipif(
        not CHR22_BAM.exists(),
        reason=f"chr22 corpus not on disk: {CHR22_BAM}",
    ),
]


def _encode_chr22(out_path: Path, *, opt_disable_v2: bool) -> None:
    """Build a v1.7 .tio file from the chr22 BAM with v2 on/off.

    Uses the same BamReader + SpectralDataset.write_minimal pipeline
    as the benchmark harness (``tools/benchmarks/formats.py``), but
    without the REF_DIFF / FQZCOMP / NAME_TOKENIZED overrides — we
    want to isolate the mate_info channel savings cleanly.  The only
    variable is ``opt_disable_inline_mate_info_v2``.
    """
    from ttio.importers.bam import BamReader
    from ttio import SpectralDataset

    run = BamReader(str(CHR22_BAM)).to_genomic_run(name="chr22")
    run.opt_disable_inline_mate_info_v2 = opt_disable_v2

    SpectralDataset.write_minimal(
        path=str(out_path),
        title="mate_info_v2_gate:chr22",
        isa_investigation_id="TTIO:gate:mate_info_v2",
        runs={},
        genomic_runs={"chr22": run},
    )


def test_chr22_savings_ge_5mb(tmp_path: Path) -> None:
    """chr22 NA12878 lean+mapped: v2 inline codec saves >= 5 MB vs v1.

    Hard gate: if this test fails the mate_info v2 codec has
    regressed and MUST NOT ship.  The 5 MB floor is conservative;
    the design target is ~7 MB (v1 mate_info ~11.5 MB -> v2 ~4.5 MB
    for chr22 1,766,433 records).
    """
    out_v1 = tmp_path / "chr22_v1.tio"
    out_v2 = tmp_path / "chr22_v2.tio"

    _encode_chr22(out_v1, opt_disable_v2=True)
    _encode_chr22(out_v2, opt_disable_v2=False)

    v1_size = out_v1.stat().st_size
    v2_size = out_v2.stat().st_size
    savings  = v1_size - v2_size

    MB = 1024 * 1024
    print(
        f"\nchr22 NA12878 lean+mapped (n=1,766,433 records):\n"
        f"  v1 (opt-out)  size : {v1_size:>15,d} bytes  "
        f"({v1_size / MB:8.3f} MB)\n"
        f"  v2 (default)  size : {v2_size:>15,d} bytes  "
        f"({v2_size / MB:8.3f} MB)\n"
        f"  savings             : {savings:>15,d} bytes  "
        f"({savings / MB:8.3f} MB)\n"
        f"  pct delta           : {100.0 * savings / v1_size:.2f}%"
    )

    assert savings >= 5 * MB, (
        f"chr22 savings {savings / MB:.3f} MB < 5 MB hard gate — "
        f"mate_info v2 regressed or native lib not loaded correctly."
    )
