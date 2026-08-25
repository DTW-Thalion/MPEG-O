"""Shard-mode worker shutdown when the consumer abandons the
generator mid-stream.

``iter_batches_shard`` workers deliver slices through depth-1 queues.
A consumer that stops iterating early (an exception, or a caller that
breaks out of the loop) closes the generator; its ``finally`` sets
the stop event and joins the pool. A worker parked in a full
``q.put`` never re-checks the event, so ``pool.shutdown(wait=True)``
waits forever and the process deadlocks. Observed as
``test_exports_bounded_memory`` hanging the whole suite.

The test runs the abandon in a daemon thread and asserts it finishes,
so the failure mode is a plain assertion after the timeout rather
than a hung pytest process.
"""
from __future__ import annotations

import threading
from pathlib import Path


def _write_fastq(path: Path, n_reads: int) -> None:
    with open(path, "w") as f:
        for i in range(n_reads):
            f.write(f"@r{i}\n{'ACGT' * 25}\n+\n{'I' * 100}\n")


def test_shard_abandon_terminates_workers(tmp_path: Path):
    from ttio.importers import fastq_parallel as fp

    fq = tmp_path / "abandon.fastq"
    _write_fastq(fq, 80_000)  # ~10 MB, plenty of slices per shard

    batch_bytes = 1 << 16
    mode, ranges = fp.plan_input(str(fq), 4, batch_bytes)
    assert mode == "shard" and len(ranges) >= 2, (
        f"fixture must shard across workers, got {mode} "
        f"with {ranges if ranges is None else len(ranges)} ranges")

    finished = threading.Event()

    def _consume_one_then_abandon():
        gen = fp.iter_batches_shard(
            str(fq), ranges, threads=4, batch_reads=1_000,
            batch_bytes=batch_bytes, forced=None,
            detected_cb=lambda off: None,
            meta=dict(sample_name="s", platform="",
                      reference_uri="", acquisition_mode=7))
        try:
            next(gen)  # take one batch, then walk away
        finally:
            gen.close()  # runs the generator finally: stop + shutdown
        finished.set()

    t = threading.Thread(target=_consume_one_then_abandon, daemon=True)
    t.start()
    t.join(timeout=60)
    assert finished.is_set(), (
        "abandoning the shard generator deadlocked its worker pool "
        "(workers blocked in q.put never observed the stop event)")
