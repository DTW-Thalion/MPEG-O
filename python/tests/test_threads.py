import os
import pytest
from ttio import _threads


def test_resolve_threads_precedence(monkeypatch):
    monkeypatch.delenv("TTIO_THREADS", raising=False)
    monkeypatch.setattr(os, "cpu_count", lambda: 32)
    assert _threads.resolve_threads() == 30
    monkeypatch.setattr(os, "cpu_count", lambda: 4)
    assert _threads.resolve_threads() == 2
    # Two cores would otherwise resolve to zero workers.
    monkeypatch.setattr(os, "cpu_count", lambda: 2)
    assert _threads.resolve_threads() == 1
    monkeypatch.setattr(os, "cpu_count", lambda: 1)
    assert _threads.resolve_threads() == 1
    # 0 means "use the default", which is still the one-core answer here.
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


def test_read_ahead_window_env_override(monkeypatch):
    """The window is settable so the memory/latency trade can be
    measured. Java: GenomicRun.readAheadBlocks; ObjC:
    TTIOReadAheadBlocks."""
    from ttio import genomic_run

    monkeypatch.delenv("TTIO_READ_AHEAD_BLOCKS", raising=False)
    assert genomic_run._read_ahead_blocks() == genomic_run._READ_AHEAD_BLOCKS
    monkeypatch.setenv("TTIO_READ_AHEAD_BLOCKS", "9")
    assert genomic_run._read_ahead_blocks() == 9
    # Junk and non-positive values defer to the default rather than
    # leaving a reader with no lookahead at all.
    monkeypatch.setenv("TTIO_READ_AHEAD_BLOCKS", "junk")
    assert genomic_run._read_ahead_blocks() == genomic_run._READ_AHEAD_BLOCKS
    monkeypatch.setenv("TTIO_READ_AHEAD_BLOCKS", "0")
    assert genomic_run._read_ahead_blocks() == genomic_run._READ_AHEAD_BLOCKS


def test_v6_segment_threads_clamp(monkeypatch):
    """The argument is blocks in flight, not the pool size, and the
    cap is the core count. Parity with Threads.resolveV6SegmentThreads
    (Java) and +[TTIOThreads resolveV6SegmentThreads:] (ObjC)."""
    monkeypatch.setattr(os, "cpu_count", lambda: 32)
    assert _threads.resolve_v6_segment_threads(1) == 32     # the machine
    assert _threads.resolve_v6_segment_threads(4) == 8
    assert _threads.resolve_v6_segment_threads(16) == 2
    assert _threads.resolve_v6_segment_threads(64) == 2     # floor
    assert _threads.resolve_v6_segment_threads(0) == 32     # read as one
    # The product stays near the core count wherever it can.
    for blocks in (1, 2, 4, 8, 16):
        assert _threads.resolve_v6_segment_threads(blocks) * blocks <= 32


def test_v6_segment_threads_env_override(monkeypatch):
    """TTIO_V6_SEGMENT_THREADS wins whatever the worker count, and
    reaches outside the clamp on purpose: a sweep has to be able to ask
    for 1 and for more than 8. Parity with the Java and ObjC resolvers."""
    monkeypatch.setattr(os, "cpu_count", lambda: 32)
    monkeypatch.setenv("TTIO_V6_SEGMENT_THREADS", "5")
    assert _threads.resolve_v6_segment_threads(1) == 5
    assert _threads.resolve_v6_segment_threads(64) == 5
    monkeypatch.setenv("TTIO_V6_SEGMENT_THREADS", "1")
    assert _threads.resolve_v6_segment_threads(1) == 1       # below the floor
    monkeypatch.setenv("TTIO_V6_SEGMENT_THREADS", "16")
    assert _threads.resolve_v6_segment_threads(1) == 16      # above the cap
    for bad in ("junk", "0", "-1", ""):
        monkeypatch.setenv("TTIO_V6_SEGMENT_THREADS", bad)
        assert _threads.resolve_v6_segment_threads(16) == 2  # falls through
    monkeypatch.delenv("TTIO_V6_SEGMENT_THREADS")
    assert _threads.resolve_v6_segment_threads(16) == 2


def test_import_threads_caps_the_default_at_what_memory_affords(monkeypatch):
    # A thread costs a gibibyte of the pipeline budget, so the default
    # count is capped at what a quarter of physical memory affords.
    monkeypatch.delenv("TTIO_THREADS", raising=False)
    monkeypatch.delenv("TTIO_IMPORT_THREADS", raising=False)
    monkeypatch.setattr(os, "cpu_count", lambda: 32)
    per_thread = _threads.IMPORT_BLOCK_BYTES * 16

    def phys(gib):
        monkeypatch.setattr(
            os, "sysconf",
            lambda n: (gib << 30) // 4096 if n == "SC_PHYS_PAGES" else 4096)

    phys(32)                       # 8 GiB quarter / 1 GiB a thread
    assert _threads.resolve_import_threads() == 8
    phys(256)                      # affords more than the plain default
    assert _threads.resolve_import_threads() == 30
    phys(1)                        # affords none: the floor is one
    assert _threads.resolve_import_threads() == 1
    assert (32 >> 2) << 30 == 8 * per_thread


def test_import_threads_honours_what_the_caller_asked_for(monkeypatch):
    monkeypatch.setattr(os, "cpu_count", lambda: 32)
    monkeypatch.setattr(
        os, "sysconf",
        lambda n: (32 << 30) // 4096 if n == "SC_PHYS_PAGES" else 4096)
    monkeypatch.delenv("TTIO_IMPORT_THREADS", raising=False)
    # An explicit count is not capped.
    monkeypatch.setenv("TTIO_THREADS", "30")
    assert _threads.resolve_import_threads() == 30
    # The import knob overrides the rule, and TTIO_THREADS with it.
    monkeypatch.setenv("TTIO_IMPORT_THREADS", "3")
    assert _threads.resolve_import_threads() == 3
    monkeypatch.delenv("TTIO_THREADS")
    assert _threads.resolve_import_threads() == 3
    # Junk falls through to the count asked for.
    monkeypatch.setenv("TTIO_IMPORT_THREADS", "junk")
    monkeypatch.setenv("TTIO_THREADS", "12")
    assert _threads.resolve_import_threads() == 12
