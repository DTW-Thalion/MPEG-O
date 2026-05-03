"""M93 compression-gate integration test.

With M94.Z (FQZCOMP_NX16_Z, CRAM-mimic) and M95 (DELTA_RANS_ORDER0 +
structural) shipped, this test serves as the v1.2.0 acceptance gate:
TTI-O lossless within 1.15× of CRAM 3.1 on the chr22 mapped-only
fixture.

For M93 alone, the gate is relaxed to **≤2.5×** CRAM 3.1 — the M93
contribution closes ~10–15% of the gap on this dataset (45 MB BASE_PACK
sequences → 5 MB REF_DIFF + ~50 MB embedded reference). The bigger
wins come from M94 (qualities ~110 MB → ~55 MB) and M95 (integer
channels ~17 MB → ~3 MB + structural HDF5 overhead reduction).

The test is **skipped** when the chr22 mapped-only fixture is not on
disk (e.g. fresh checkout without the DVC pull). Run with::

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

# M93 acceptance gate (relaxed). M94 + M95 will tighten this to 1.15×.
M93_RATIO_CEILING = 2.5

# v1.2.0 final acceptance gate — only enforce when M94 + M95 marker files exist.
V1_2_0_RATIO_CEILING = 1.15
V1_2_0_MARKER = REPO_ROOT / "python" / "src" / "ttio" / "codecs" / "fqzcomp_nx16_z.py"


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


def test_m93_compression_within_ratio(tmp_path):
    cram_bytes = _samtools_cram_size(CHR22_BAM, CHR22_REF, tmp_path)
    ttio_bytes = _ttio_size(CHR22_BAM, CHR22_REF, tmp_path)
    ratio = ttio_bytes / cram_bytes

    print(
        f"\n[m93 gate] chr22 mapped-only: CRAM 3.1 = {cram_bytes / 1e6:.2f} MB, "
        f"TTI-O = {ttio_bytes / 1e6:.2f} MB → ratio {ratio:.3f}× "
        f"(M93 ceiling {M93_RATIO_CEILING}×; v1.2.0 ceiling {V1_2_0_RATIO_CEILING}×)"
    )

    if V1_2_0_MARKER.exists():
        # M94 has shipped — enforce the v1.2.0 final gate.
        ceiling = V1_2_0_RATIO_CEILING
        gate_label = "v1.2.0 final"
    else:
        # M93 only — enforce the relaxed gate.
        ceiling = M93_RATIO_CEILING
        gate_label = "M93 (M94/M95 not yet shipped)"

    assert ratio <= ceiling, (
        f"TTI-O / CRAM ratio {ratio:.3f}× exceeds {gate_label} ceiling "
        f"{ceiling:.2f}×. Pre-M93 baseline was ~2.5×; if you've recently "
        f"changed the codec stack and the ratio went UP, investigate before "
        f"committing."
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
