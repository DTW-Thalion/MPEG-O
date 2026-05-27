"""ProgressSink coverage for :func:`ttio.importers.jcamp_dx.read_spectrum`.

JCAMP-DX is single-spectrum; progress fires once with ``(1, 1)``.
"""
from __future__ import annotations

from pathlib import Path

from ttio.importers.jcamp_dx import read_spectrum


def _build_raman_jdx(path: Path) -> None:
    """Tiny AFFN-encoded JCAMP-DX Raman spectrum (3 points)."""
    txt = """##TITLE=tiny
##JCAMP-DX=5.01
##DATA TYPE=RAMAN SPECTRUM
##XUNITS=1/CM
##YUNITS=ARBITRARY
##XFACTOR=1.0
##YFACTOR=1.0
##FIRSTX=100.0
##LASTX=300.0
##NPOINTS=3
##XYDATA=(X++(Y..Y))
100.0 1.0
200.0 2.0
300.0 3.0
##END=
"""
    path.write_text(txt)


def test_jcampdx_progress_fires_once(tmp_path: Path) -> None:
    p = tmp_path / "tiny.jdx"
    _build_raman_jdx(p)

    events: list[tuple[int, int]] = []
    spec = read_spectrum(p, progress=lambda d, t: events.append((d, t)))
    assert spec is not None
    assert events == [(1, 1)]


def test_jcampdx_progress_none_safe(tmp_path: Path) -> None:
    p = tmp_path / "tiny.jdx"
    _build_raman_jdx(p)
    spec = read_spectrum(p)
    assert spec is not None
