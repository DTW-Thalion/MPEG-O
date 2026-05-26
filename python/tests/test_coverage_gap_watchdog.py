"""v0.11 transport-spec Task 2.10 — crude-but-effective watchdog
that fires whenever a writer silently drops a content type from the
all-in-one ``everything.tio`` fixture.

Two complementary checks:

* :func:`test_tis_size_at_least_one_percent_of_tio_on_everything_fixture` —
  the encoded ``.tis`` byte size MUST be at least 1% of the source
  ``.tio`` byte size. If a writer accidentally short-circuits an
  entire accessor (e.g. forgets to emit the IMAGE packet sequence
  for a populated MSImage), this floor catches it immediately.

* :func:`test_everything_fixture_round_trips_every_accessor` — runs
  every :class:`AccessorSpec` comparator against the source vs
  round-tripped ``everything.tio``. This is the strongest coverage
  guarantee the watchdog can express: if any single accessor's
  content drifts, the matching field-level comparator fires.

Python parity for Java's
``global.thalion.ttio.transport.CoverageGapWatchdogTest`` (commit
``2d04e035``).

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import io
import os
import sys
from pathlib import Path

import pytest

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from ttio.spectral_dataset import SpectralDataset  # noqa: E402
from ttio.transport.codec import TransportReader, TransportWriter  # noqa: E402

from _v0_11_accessor_spec import ACCESSOR_SPECS  # noqa: E402
from _v0_11_fixtures import build_everything  # noqa: E402


# everything.tio includes a genomic run, so the same NAME_TOKENIZED_V2
# native-lib gate as test_accessor_matrix_conformance applies. Without
# the lib, the fixture build itself fails — skip rather than report
# a noisy stack trace.
def _native_genomic_codec_available() -> bool:
    try:
        from ttio.codecs.fqzcomp_nx16_z import _load_native_lib
    except Exception:
        return False
    if os.environ.get("TTIO_RANS_LIB_PATH"):
        return _load_native_lib() is not None
    return _load_native_lib() is not None


pytestmark = pytest.mark.skipif(
    not _native_genomic_codec_available(),
    reason=(
        "everything.tio includes a genomic run; libttio_rans native "
        "shim (NAME_TOKENIZED_V2 codec) is required. Set "
        "TTIO_RANS_LIB_PATH or install ttio[native]."
    ),
)


def _encode_via_write_dataset(src: Path, tis: Path) -> Path:
    """Helper: high-level write_dataset emit of ``src`` into ``tis``.
    Returns ``tis`` so callers can chain ``tis.stat().st_size``."""
    with SpectralDataset.open(src) as ds:
        with tis.open("wb") as out, TransportWriter(out) as w:
            w.write_dataset(ds)
    return tis


def test_tis_size_at_least_one_percent_of_tio_on_everything_fixture(
    tmp_path: Path,
) -> None:
    """The .tis byte size MUST be at least 1% of the source .tio
    size. The 1% floor is loose by design — current measurements
    (Java) show 7.8% — so any future writer that silently drops an
    accessor will crash through it cleanly with a message that
    points at the byte counts."""
    src = build_everything(tmp_path / "everything.tio")
    tis = _encode_via_write_dataset(src, tmp_path / "everything.tis")

    src_size = src.stat().st_size
    tis_size = tis.stat().st_size
    assert tis_size > src_size / 100, (
        f"Coverage gap watchdog: .tis {tis_size} bytes < 1% of "
        f".tio {src_size} bytes — likely a writer is silently "
        f"dropping a content type."
    )


def test_everything_fixture_round_trips_every_accessor(tmp_path: Path) -> None:
    """Round-trip the all-in-one fixture and then run *every*
    :class:`AccessorSpec` comparator against (source, round-tripped).
    If any first-class accessor's content drifts during the round
    trip, the matching field-level comparator surfaces the exact
    attribute that mismatched."""
    src = build_everything(tmp_path / "everything.tio")
    tis = tmp_path / "everything.tis"
    rt = tmp_path / "rt.tio"

    with SpectralDataset.open(src) as ds:
        with tis.open("wb") as out, TransportWriter(out) as w:
            w.write_dataset(ds)

    with TransportReader(io.BytesIO(tis.read_bytes())) as r:
        materialised = r.read_to_dataset(output_path=rt)
        materialised.close()

    # Stage 5 (Task 5.6) accessors are intentionally not populated by
    # build_everything: MS_IMAGE_PROCESSED is a wire-mode override of
    # the same MSImage already covered by IMAGE; RAMAN_IMAGE / IR_IMAGE
    # are first-class siblings of MSImage on SpectralDataset that the
    # v0.11 everything fixture does not yet include. The per-accessor
    # conformance suite still exercises all three.
    _STAGE_5_SKIP = {"MS_IMAGE_PROCESSED", "RAMAN_IMAGE", "IR_IMAGE"}
    with SpectralDataset.open(src) as a, SpectralDataset.open(rt) as b:
        for spec in ACCESSOR_SPECS:
            if spec.name in _STAGE_5_SKIP:
                continue
            spec.assert_content_equals(a, b)
