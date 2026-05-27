"""ProgressSink coverage for :func:`ttio.importers.mztab.read`.

Synthesises a small mzTab with 1200 PSM rows and asserts:
- mid-parse callbacks fire every PROGRESS_INTERVAL_ROWS (500)
- final callback reports the true total
"""
from __future__ import annotations

from pathlib import Path

from ttio.importers.mztab import PROGRESS_INTERVAL_ROWS, read


def _build_mztab(path: Path, n_psm: int) -> None:
    lines: list[str] = []
    lines.append("MTD\tmzTab-version\t1.0")
    lines.append("MTD\tmzTab-mode\tComplete")
    lines.append("MTD\tmzTab-type\tIdentification")
    lines.append("MTD\tdescription\tsynth")
    lines.append("MTD\tms_run[1]-location\tfile:///tmp/run1")
    lines.append("MTD\tassay[1]-sample_ref\tsample_A")
    # PSM section
    lines.append(
        "PSH\tsequence\tPSM_ID\taccession\tunique\tdatabase\t"
        "database_version\tsearch_engine\tsearch_engine_score[1]\t"
        "modifications\tretention_time\tcharge\texp_mass_to_charge\t"
        "calc_mass_to_charge\turi\tspectra_ref\tpre\tpost\tstart\tend"
    )
    for i in range(n_psm):
        lines.append(
            f"PSM\tSEQUENCE_{i}\t{i}\tP12345\t1\tDB\t1\t[MS, MS:1001083, mascot, 1.0]\t"
            f"0.5\t\t100.0\t2\t500.0\t500.0\t\tms_run[1]:scan={i}\t-\t-\t1\t8"
        )
    path.write_text("\n".join(lines) + "\n")


def test_mztab_progress_fires(tmp_path: Path) -> None:
    n = 1200
    p = tmp_path / "synth.mzTab"
    _build_mztab(p, n)

    events: list[tuple[int, int]] = []
    result = read(p, progress=lambda d, t: events.append((d, t)))
    assert len(result.identifications) == n
    assert len(events) >= n // PROGRESS_INTERVAL_ROWS, events
    assert events[-1] == (n, n)
    assert any(t == -1 for _, t in events[:-1])


def test_mztab_progress_none_safe(tmp_path: Path) -> None:
    p = tmp_path / "tiny.mzTab"
    _build_mztab(p, 5)
    result = read(p)
    assert len(result.identifications) == 5
