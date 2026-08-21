"""The decode-ahead window benchmark, exercised end to end on a corpus
small enough for the suite.

The tool's own output is the thing under test: a sweep that prints a
row per window, a control row repeating the first window, and a verdict
that reads the spread against the control's drift. A control row that
never appears, or a verdict printed when the spread is inside the
drift, would make the tool say more than it measured.
"""
from __future__ import annotations

from pathlib import Path

import pytest

from ttio.tools import genomic_read_bench as grb


def _tiny(tmp_path: Path) -> Path:
    """Two blocks, which is the fewest that gives the window anything to
    do, and small enough to sweep several times in a test."""
    out = tmp_path / "bench.tio"
    assert grb.main(["make", str(out), "200", "50", "100"]) == 0
    assert out.exists()
    return out


def test_make_writes_a_blocks_v1_run(tmp_path, capsys):
    out = _tiny(tmp_path)
    line = capsys.readouterr().out
    assert "[py-bench] wrote reads=200 read_len=50 block_reads=100" in line

    from ttio.spectral_dataset import SpectralDataset

    with SpectralDataset.open(str(out)) as ds:
        g = ds.genomic_runs["run"]
        assert g.layout == "blocks_v1"
        assert g.block_count == 2
        assert len(g) == 200


def test_read_sweeps_windows_and_prints_a_control_and_verdict(tmp_path, capsys):
    out = _tiny(tmp_path)
    capsys.readouterr()
    assert grb.main(["read", str(out), "1,2"]) == 0
    printed = capsys.readouterr().out

    assert "window=1 " in printed
    assert "window=2 " in printed
    # The control repeats the first window under a second name; without
    # it a flat sweep cannot be told from a machine too noisy to show
    # anything.
    assert "window=control" in printed
    assert "control drift=" in printed and "window spread=" in printed
    assert "verdict: the window" in printed


def test_read_counts_every_read_at_every_window(tmp_path, capsys):
    """Widening the window changes when blocks decode, not how many
    reads come back."""
    out = _tiny(tmp_path)
    capsys.readouterr()
    assert grb.main(["read", str(out), "1,2,4"]) == 0
    counts = {
        line.split("reads=")[1].split()[0]
        for line in capsys.readouterr().out.splitlines()
        if "[py-bench] window=" in line
    }
    assert counts == {"200"}


def test_iterate_returns_the_same_totals_whatever_the_window(tmp_path):
    out = _tiny(tmp_path)
    one = grb._iterate(out, "run", 1)
    four = grb._iterate(out, "run", 4)
    assert one[0] == four[0] == 200
    assert one[1] == four[1] == 200 * 50


def test_iterate_restores_the_module_default(tmp_path):
    """The window is set by assigning a module global, so a pass that
    raised or returned early would leave the reader retuned for
    everything after it."""
    from ttio import genomic_run as gr

    out = _tiny(tmp_path)
    before = gr._READ_AHEAD_BLOCKS
    grb._iterate(out, "run", 4)
    assert gr._READ_AHEAD_BLOCKS == before


@pytest.mark.parametrize(
    "argv",
    [
        [],
        ["bogus"],
        ["make"],
        ["make", "f", "1", "2"],
        ["read"],
        ["read", "a", "b", "c", "d"],
    ],
)
def test_main_rejects_bad_argv(argv, capsys):
    assert grb.main(argv) == 1
    assert capsys.readouterr().err != ""
