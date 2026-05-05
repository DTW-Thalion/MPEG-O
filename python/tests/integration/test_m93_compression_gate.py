"""End-to-end TTI-O / CRAM 3.1 compression-ratio acceptance gate.

History: this file started life as the M93 REF_DIFF v1 gate (≤2.5×
CRAM), tightened to the v1.2.0 1.15× target after M94.Z + M95 shipped,
and after #11 (mate_info v2 / REF_DIFF v2 / NAME_TOKENIZED v2) plus
#10 (offsets-cumsum) the v1.10 default stack actually produces TTI-O
files **slightly smaller than CRAM 3.1** on chr22 (~0.996×). The 1.15×
ceiling is now far above measured behavior; the test serves as a
regression bound — TTI-O must stay within 1.10× of CRAM going forward,
which is generous against measurement noise (run-to-run jitter, BAM
re-pack overhead) but catches any major codec regression.

Skipped when the chr22 mapped-only fixture is not on disk. Run with::

    pytest python/tests/integration/test_m93_compression_gate.py -v
"""
from __future__ import annotations

import json
import subprocess
import time
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
CHR22_BAM = REPO_ROOT / "data" / "genomic" / "na12878" / "na12878.chr22.lean.mapped.bam"
CHR22_REF = REPO_ROOT / "data" / "genomic" / "reference" / "hs37.chr22.fa"

# Regression ceiling for the v1.10 codec stack. Measured at v1.10
# default (REF_DIFF_V2 + FQZCOMP_NX16_Z V4 + NAME_TOKENIZED_V2 +
# MATE_INLINE_V2 + #10 offsets-cumsum) is ~0.996× CRAM 3.1 on chr22
# NA12878 lean+mapped. 1.10× is generous head-room for measurement
# noise; tighten if a future release demonstrates lower variance.
RATIO_CEILING = 1.10


pytestmark = pytest.mark.skipif(
    not CHR22_BAM.exists(),
    reason=f"chr22 mapped-only fixture missing at {CHR22_BAM}",
)


def _samtools_cram_size(bam: Path, ref: Path, work_dir: Path) -> int:
    """Return the size of a CRAM 3.1 encoding of ``bam`` against ``ref``."""
    out = work_dir / "cram_for_gate.cram"
    subprocess.run(
        [
            "samtools", "view", "-C",
            "-T", str(ref),
            "--output-fmt-option", "version=3.1",
            "-o", str(out),
            str(bam),
        ],
        check=True,
        capture_output=True,
    )
    return out.stat().st_size


def _ttio_size(bam: Path, ref: Path, work_dir: Path) -> int:
    """Encode ``bam`` to TTI-O via the benchmark harness pipeline and return size."""
    # The benchmark harness lives under <repo>/tools/, not the
    # python package — add the repo root to sys.path so the bare
    # ``tools.benchmarks.formats`` import resolves regardless of
    # the pytest invocation directory.
    import sys
    if str(REPO_ROOT) not in sys.path:
        sys.path.insert(0, str(REPO_ROOT))
    try:
        from tools.benchmarks.formats import ttio_compress
    except ImportError:
        pytest.skip(
            "benchmark harness not importable from "
            f"{REPO_ROOT}/tools/benchmarks — chr22 gate test requires the "
            "repo-root tools/ tree on sys.path"
        )
    out = work_dir / "ttio_for_gate.tio"
    result = ttio_compress(bam, ref, out)
    assert result.output_size_bytes == out.stat().st_size
    return result.output_size_bytes


def test_chr22_compression_ratio(tmp_path):
    cram_bytes = _samtools_cram_size(CHR22_BAM, CHR22_REF, tmp_path)
    ttio_bytes = _ttio_size(CHR22_BAM, CHR22_REF, tmp_path)
    ratio = ttio_bytes / cram_bytes

    print(
        f"\n[chr22 ratio gate] mapped-only: "
        f"CRAM 3.1 = {cram_bytes / 1e6:.2f} MB, "
        f"TTI-O = {ttio_bytes / 1e6:.2f} MB → ratio {ratio:.3f}× "
        f"(ceiling {RATIO_CEILING}×; expected ~0.996× at v1.10 default)"
    )

    assert ratio <= RATIO_CEILING, (
        f"TTI-O / CRAM ratio {ratio:.3f}× exceeds {RATIO_CEILING:.2f}× "
        f"ceiling. v1.10 default measured ~0.996×; if you've recently "
        f"changed the codec stack and the ratio went UP, investigate "
        f"before committing."
    )


# v1.0 reset (Phase 2c): the V2 wire-format smoke test was removed
# because the V2 (and V1, V3) FQZCOMP_NX16_Z encoder paths are gone.
# V4 is now the only path; the chr22_compression_ratio gate above
# already exercises it end-to-end.
