"""v0.11 transport-spec Task 2.10 — parameterised over every
:class:`AccessorSpec`. For each first-class accessor:

1. Build an isolation fixture (``.tio`` carrying *only* that
   accessor's content).
2. Round-trip it through
   :class:`ttio.transport.codec.TransportWriter` ->
   :class:`ttio.transport.codec.TransportReader` -> ``.tio``.
3. Re-open both sides and assert content equality through the
   accessor's comparator.

If any v0.11 writer silently drops content for an accessor (e.g.
forgets to emit the packet sequence), the test for that accessor
fails immediately with a field-level error message that points at
the exact attribute that drifted.

Python parity for Java's
``global.thalion.ttio.transport.AccessorMatrixConformanceTest``
(commit ``46c26587``). The Java side uses ``@EnumSource`` on
``AccessorSpec``; Python uses ``pytest.mark.parametrize`` over
:data:`ACCESSOR_SPECS` — same matrix, idiomatic harness.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import io
import sys
from pathlib import Path

import pytest

# tests/ has no __init__.py — pytest's rootdir auto-adds it to
# sys.path so a bare module name import works. Defensive path
# insertion here for direct ``python -m pytest tests/...`` runs in
# environments where pytest's rootdir detection has been overridden.
_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from ttio.spectral_dataset import SpectralDataset  # noqa: E402
from ttio.transport.codec import TransportReader  # noqa: E402

from _v0_11_accessor_spec import ACCESSOR_SPECS  # noqa: E402


# GENOMIC_RUNS exercises the v1.0 NAME_TOKENIZED_V2 codec which
# requires the native ``libttio_rans`` library. The codec dispatch is
# inside ``SpectralDataset.write_minimal`` for any genomic_runs= arg,
# so the fixture build itself fails on environments without the
# native shim. Treat that as a precondition — skip rather than fail
# — so the accessor matrix stays meaningful even on minimal CI
# images that don't ship the native lib. Mirrors the gating used by
# ``test_transport_codec.TestGenomicRoundTrip`` (which fails for the
# same reason in environments without the lib).
def _genomic_runs_available() -> bool:
    # The loader honours ``$TTIO_RANS_LIB_PATH`` first, then walks the
    # bundled ``.libs`` dirs, the bare names and ``find_library``. A
    # non-None handle means the shim is reachable however it was built.
    from ttio.codecs._native_loader import load_ttio_rans

    return load_ttio_rans() is not None


@pytest.mark.parametrize("spec", ACCESSOR_SPECS, ids=lambda s: s.name)
def test_round_trip_preserves_accessor(spec, tmp_path: Path) -> None:
    """Round-trip the isolation fixture for ``spec`` through the
    transport codec and assert the per-accessor comparator passes."""
    if spec.name == "GENOMIC_RUNS" and not _genomic_runs_available():
        pytest.skip(
            "GENOMIC_RUNS fixture requires libttio_rans native shim "
            "(NAME_TOKENIZED_V2 codec). Set TTIO_RANS_LIB_PATH or "
            "install ttio[native] to exercise this accessor."
        )

    src = spec.build_fixture(tmp_path / f"{spec.name}.tio")
    tis = tmp_path / f"{spec.name}.tis"
    rt = tmp_path / f"{spec.name}-rt.tio"

    # .tio -> .tis. Most accessors hand off to write_dataset via the
    # default encode_strategy on AccessorSpec; MS_IMAGE_PROCESSED
    # overrides to call write_image_processed for the opt-in sparse
    # wire mode (Task 5.6).
    with SpectralDataset.open(src) as ds_src:
        buf = io.BytesIO()
        spec.encode_strategy(ds_src, buf)
        tis.write_bytes(buf.getvalue())

    # .tis -> .tio (decode via the high-level read_to_dataset /
    # materialize_to path; the Java equivalent uses materializeTo).
    with TransportReader(io.BytesIO(tis.read_bytes())) as r:
        materialised = r.read_to_dataset(output_path=rt)
        materialised.close()

    # Re-open both sides through the canonical reader and compare
    # via the accessor's matcher. Closing happens via the with
    # context — the comparator may raise, which surfaces as the
    # test-level AssertionError with a field-pointing message.
    with SpectralDataset.open(src) as a, SpectralDataset.open(rt) as b:
        spec.assert_content_equals(a, b)
