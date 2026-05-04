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
    from tools.benchmarks.formats import ttio_compress
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


# ---------------------------------------------------------------------------
# Task 27: V2 wire format smoke test
# ---------------------------------------------------------------------------

def _native_lib_available() -> bool:
    """Return True if libttio_rans.so is loadable (TTIO_RANS_LIB_PATH set)."""
    import os as _os
    lib_path = _os.environ.get("TTIO_RANS_LIB_PATH", "")
    if not lib_path:
        return False
    from pathlib import Path as _Path
    return _Path(lib_path).is_file()


@pytest.mark.skipif(
    not _native_lib_available(),
    reason="TTIO_RANS_LIB_PATH not set or file not found — V2 native lib required",
)
def test_ttio_compress_v2_wire_format(tmp_path):
    """ttio_compress with TTIO_M94Z_USE_NATIVE=1 writes V2 qualities stream.

    Verifies Task 27: the FQZCOMP_NX16_Z channel carries magic=M94Z and
    version byte=2 when the env var is set.
    """
    import h5py
    from tools.benchmarks.formats import ttio_compress

    out = tmp_path / "v2_smoke.tio"
    # L2.X V4 (Task 12+): V4 is the default when libttio_rans is loaded,
    # so we must explicitly pin the codec to V2 via TTIO_M94Z_VERSION=2
    # to exercise the V2 wire format. TTIO_M94Z_USE_NATIVE=1 is retained
    # for parity with the original Task 27 dispatch gate.
    with _SetEnv("TTIO_M94Z_VERSION", "2"), _SetEnv("TTIO_M94Z_USE_NATIVE", "1"):
        result = ttio_compress(CHR22_BAM, CHR22_REF, out)

    assert result.output_size_bytes > 0
    assert out.stat().st_size == result.output_size_bytes

    # Parse the HDF5 and verify the qualities channel is V2.
    with h5py.File(out, "r") as f:
        qual_ds = f["study/genomic_runs/run_0001/signal_channels/qualities"]
        assert qual_ds.attrs.get("compression") == 12, (
            "codec id must be FQZCOMP_NX16_Z (12)"
        )
        raw = qual_ds[:]
        assert bytes(raw[:4]) == b"M94Z", (
            f"expected M94Z magic, got {bytes(raw[:4])!r}"
        )
        assert raw[4] == 2, f"expected version byte 2 (V2), got {raw[4]}"

    print(
        f"\n[Task 27 smoke] V2 qualities stream confirmed: "
        f"magic=M94Z, version=2; file size {result.output_size_bytes:,} bytes"
    )


class _SetEnv:
    """Context manager: temporarily override an environment variable."""

    def __init__(self, key: str, value: str) -> None:
        self._key = key
        self._value = value
        self._old: str | None = None

    def __enter__(self) -> "_SetEnv":
        import os
        self._old = os.environ.get(self._key)
        os.environ[self._key] = self._value
        return self

    def __exit__(self, *_: object) -> None:
        import os
        if self._old is None:
            os.environ.pop(self._key, None)
        else:
            os.environ[self._key] = self._old
