import os
import pytest
from ttio import _threads


def test_resolve_threads_precedence(monkeypatch):
    monkeypatch.delenv("TTIO_THREADS", raising=False)
    monkeypatch.setattr(os, "cpu_count", lambda: 32)
    assert _threads.resolve_threads() == 24
    monkeypatch.setattr(os, "cpu_count", lambda: 4)
    assert _threads.resolve_threads() == 1
    monkeypatch.setenv("TTIO_THREADS", "0")
    assert _threads.resolve_threads() == 1
    monkeypatch.setenv("TTIO_THREADS", "6")
    assert _threads.resolve_threads() == 6
    assert _threads.resolve_threads(2) == 2
    assert _threads.resolve_threads(0) == 6
    monkeypatch.setenv("TTIO_THREADS", "junk")
    assert _threads.resolve_threads() == 1


def test_pool_context_stands_down_the_autotune(monkeypatch):
    calls = []
    monkeypatch.setattr(_threads, "_get_autotune", lambda: 3)
    monkeypatch.setattr(_threads, "_set_autotune", lambda n: calls.append(n))
    with _threads.pool_context(1):
        pass
    assert calls == []
    with _threads.pool_context(4):
        with _threads.pool_context(2):
            assert calls == [1]
        assert calls == [1]
    assert calls == [1, 3]


def test_cli_threads_flag_sets_env(monkeypatch, tmp_path):
    from ttio.tools.workbench_cli import main
    monkeypatch.delenv("TTIO_THREADS", raising=False)
    fq = tmp_path / "in.fastq"
    fq.write_text("@r1\nACGT\n+\nIIII\n")
    assert main(["encode", "--input", str(fq), "--format", "fastq",
                 "--output", str(tmp_path / "o.tio"), "--threads", "3"]) == 0
    assert os.environ["TTIO_THREADS"] == "3"
