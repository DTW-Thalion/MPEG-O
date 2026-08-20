"""Streaming genomic importers: BAM/SAM/CRAM and FASTQ through the block writer."""
from __future__ import annotations

import os
import resource
import shutil
import subprocess
import numpy as np
from pathlib import Path

import pytest

from _digests import (fastq_md5, genomic_run_fastq_md5, genomic_run_sam11_md5,
                      sam11_md5)
from ttio.importers import bam as bam_imp
from ttio.importers import fastq as fq_imp
from ttio.importers import registry
from ttio.spectral_dataset import SpectralDataset

REPO = Path(__file__).resolve().parents[2]
BAM = REPO / "python/tests/fixtures/genomic/m87_test.bam"
needs_samtools = pytest.mark.skipif(shutil.which("samtools") is None, reason="samtools")


@needs_samtools
def test_iter_batches_concatenates_to_the_whole_run():
    reader = bam_imp.BamReader(BAM)
    whole = reader.to_genomic_run()
    batches = list(reader.iter_batches(batch_reads=7))
    assert sum(len(b.read_names) for b in batches) == len(whole.read_names)
    assert len(batches) >= 2
    assert [n for b in batches for n in b.read_names] == whole.read_names
    assert batches[0].provenance_records and not batches[1].provenance_records
    assert all(b.reference_uri == whole.reference_uri for b in batches)


@needs_samtools
def test_registry_encode_streams_bam_and_round_trips(tmp_path):
    out = tmp_path / "o.tio"
    registry.encode("bam", [str(BAM)], str(out), block_reads=25)
    with SpectralDataset.open(str(out)) as ds:
        g = ds.genomic_runs["genomic_0001"]
        assert g.layout == "blocks_v1" and g.block_count >= 2
        assert genomic_run_sam11_md5(g) == sam11_md5(BAM)


@needs_samtools
def test_blocks_cut_at_chromosome_boundaries_with_reference(tmp_path):
    """A multi-chromosome BAM with a reference streams through
    REF_DIFF_V2 because every block holds one chromosome."""
    ref = tmp_path / "ref.fa"
    import random
    rng = random.Random(3)
    chroms = {"chrA": "".join(rng.choice("ACGT") for _ in range(3000)),
              "chrB": "".join(rng.choice("ACGT") for _ in range(2000))}
    ref.write_text("".join(f">{n}\n{s}\n" for n, s in chroms.items()))
    subprocess.run(["samtools", "faidx", str(ref)], check=True)
    sam = tmp_path / "in.sam"
    lines = ["@HD\tVN:1.6\tSO:coordinate", "@SQ\tSN:chrA\tLN:3000", "@SQ\tSN:chrB\tLN:2000",
             "@RG\tID:g\tSM:S1\tPL:ILLUMINA"]
    i = 0
    for chrom in ("chrA", "chrB"):
        for pos in range(1, 1500, 37):
            seq = chroms[chrom][pos - 1:pos - 1 + 50]
            lines.append(f"r{i}\t0\t{chrom}\t{pos}\t60\t50M\t*\t0\t0\t{seq}\t{'I' * 50}")
            i += 1
    for k in range(5):
        lines.append(f"u{k}\t4\t*\t0\t0\t*\t*\t0\t0\t{'ACGT' * 10}\t{'#' * 40}")
    sam.write_text("\n".join(lines) + "\n")
    out = tmp_path / "o.tio"
    registry.encode("sam", [str(sam)], str(out), reference=str(ref), embed_reference=True,
                    block_reads=1000)
    with SpectralDataset.open(str(out)) as ds:
        g = ds.genomic_runs["genomic_0001"]
        assert g.block_count == 3           # chrA, chrB, unmapped
        assert genomic_run_sam11_md5(g) == sam11_md5(sam)
        from ttio.enums import Compression
        sc = g.group.open_group("signal_channels")
        rows = g.group.open_group("blocks").open_dataset("index").read_rows()
        assert [int(r["sequences_codec"]) for r in rows][:2] == [int(Compression.REF_DIFF_V2)] * 2
        assert int(rows[2]["sequences_codec"]) != int(Compression.REF_DIFF_V2)


def test_fastq_encode_bench_tool(tmp_path):
    from ttio.tools import fastq_encode_bench
    fq = tmp_path / "in.fastq"
    with open(fq, "w") as f:
        for i in range(400):
            f.write(f"@r{i} extra\n{'ACGT' * 25}\n+\n{'I' * 50}{'#' * 50}\n")
    out = tmp_path / "o.tio"
    assert fastq_encode_bench.main([str(fq), str(out), "0", "65536"]) == 0
    with SpectralDataset.open(str(out)) as ds:
        g = ds.genomic_runs["genomic_0001"]
        assert genomic_run_fastq_md5(g) == fastq_md5(fq)
    assert fastq_encode_bench.main([]) == 1


def test_fastq_iter_batches_and_registry_stream(tmp_path):
    fq = tmp_path / "in.fastq"
    with open(fq, "w") as f:
        for i in range(2500):
            f.write(f"@r{i} extra\n{'ACGT' * 25}\n+\n{'I' * 50}{'#' * 50}\n")
    reader = fq_imp.FastqReader(fq)
    batches = list(reader.iter_batches(batch_reads=1000))
    assert [len(b.read_names) for b in batches] == [1000, 1000, 500]
    assert reader.detected_phred_offset == 33
    out = tmp_path / "o.tio"
    from ttio.tools import fastq_import_cli
    assert fastq_import_cli.main(["--fastq", str(fq), "--out", str(out), "--block-reads", "700"]) == 0
    with SpectralDataset.open(str(out)) as ds:
        g = ds.genomic_runs["genomic_0001"]
        assert g.block_count == 4
        assert genomic_run_fastq_md5(g) == fastq_md5(fq)


def test_fastq_import_memory_ceiling(tmp_path):
    big = tmp_path / "big.fastq"
    with open(big, "w") as f:
        for i in range(2_000_000):
            f.write(f"@r{i}\n{'ACGT' * 25}\n+\n{'I' * 50}{'#' * 50}\n")
    before = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    out = tmp_path / "big.tio"
    # The subject is the serial streaming path's boundedness; the
    # parallel producer's contract is the byte budget, tested in
    # test_genomic_stream_writer and measured by the acceptance run.
    src = fq_imp.FastqReader(big).stream_source(batch_reads=100_000,
                                                threads=1)
    src.block_reads = 250_000
    SpectralDataset.write_minimal(str(out), title="", isa_investigation_id="", runs={})
    with SpectralDataset.open(str(out), writable=True) as ds:
        n = src.write_into(ds.study_group)
    after = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    assert n == 2_000_000
    assert (after - before) / 1024 < 2000, f"peak RSS grew by {(after - before) / 1024:.0f} MB"
    with SpectralDataset.open(str(out)) as ds:
        assert len(ds.genomic_runs["genomic_0001"]) == 2_000_000


def test_fastq_export_memory_ceiling(tmp_path):
    """Long-read FASTQ export streams: peak RSS stays far below the output.

    The exporter used to build the whole FASTQ in a BytesIO before one
    write (plus a getvalue copy), so exporting the 20 GB HiFi corpus
    needed the output twice in memory on top of the decode and the
    suite's 20 GB cap killed it. Long reads mirror that shape: the
    output dwarfs every per-read structure. Measured in a subprocess so
    the import's high-water mark does not mask the export's.
    """
    import sys
    import textwrap

    rng = np.random.default_rng(7)
    big = tmp_path / "big.fastq"
    read = 20_000
    with open(big, "wb") as f:
        for i in range(20_000):
            seq = rng.integers(0, 4, read)
            qual = rng.integers(33, 74, read).astype(np.uint8).tobytes()
            f.write(b"@r%d\n" % i)
            f.write(bytes(np.frombuffer(b"ACGT", dtype=np.uint8)[seq]))
            f.write(b"\n+\n")
            f.write(qual)
            f.write(b"\n")
    out = tmp_path / "big.tio"
    # The child's ru_maxrss records the fork-moment snapshot of the
    # parent's resident pages before exec replaces them, so a large
    # parent floors the child's reading. The import is setup, not
    # the measurement: it runs serial to keep the parent small.
    src = fq_imp.FastqReader(big).stream_source(batch_reads=2_500,
                                                threads=1)
    src.block_reads = 2_500
    SpectralDataset.write_minimal(str(out), title="", isa_investigation_id="", runs={})
    with SpectralDataset.open(str(out), writable=True) as ds:
        assert src.write_into(ds.study_group) == 20_000

    script = textwrap.dedent("""
        import resource, sys
        from ttio.spectral_dataset import SpectralDataset
        from ttio.exporters.fastq import FastqWriter
        with SpectralDataset.open(sys.argv[1]) as ds:
            FastqWriter.write(ds.genomic_runs["genomic_0001"], sys.argv[2])
        try:
            # exec resets VmHWM, so this is the export's own peak;
            # ru_maxrss survives exec and keeps the fork-moment
            # snapshot of the parent's pages.
            with open("/proc/self/status") as st:
                line = next(l for l in st if l.startswith("VmHWM:"))
            print(int(line.split()[1]))
        except (OSError, StopIteration):
            print(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    """)
    exported = tmp_path / "roundtrip.fastq"
    env = dict(os.environ)
    env["MALLOC_ARENA_MAX"] = "2"
    proc = subprocess.Popen([sys.executable, "-c", script, str(out), str(exported)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, env=env)
    # The streaming property itself: the file grows while the export
    # runs. The old exporter held the whole body in a BytesIO and wrote
    # it after the last record, so no partial size was ever observable
    # (and the 20 GB HiFi export needed the output twice in memory on
    # top of the decode, dying on the suite's 20 GB cap).
    partial = 0
    import time
    while proc.poll() is None:
        if partial == 0 and exported.exists():
            size = exported.stat().st_size
            if 0 < size:
                partial = size   # first observation: a true mid-write size
        time.sleep(0.2)
    stdout, stderr = proc.communicate()
    assert proc.returncode == 0, stderr[-500:]
    final = exported.stat().st_size
    assert final / (1024 * 1024) > 700, final
    assert 0 < partial < final, (
        f"no mid-write size observed (first={partial}, final={final}): "
        "the export did not stream")
    # Backstop only: peak RSS varies with allocator behaviour, but the
    # old code needed the 810 MB output twice on top of the decode.
    peak_mb = int(stdout.strip().splitlines()[-1]) / 1024
    assert peak_mb < 4096, f"export peak RSS {peak_mb:.0f} MB"
    assert fastq_md5(exported) == fastq_md5(big)


@pytest.mark.slow
def test_threaded_writer_memory_window(tmp_path):
    """RSS with threads=8 stays under 9 times the one-block working set.

    The writer holds at most threads + 1 blocks in flight, so the peak of
    an 8-thread write is bounded by 9 one-block working sets on top of the
    fixed cost the serial write also pays.
    """
    import sys
    import textwrap

    script = textwrap.dedent("""
        import resource, sys
        sys.path.insert(0, "tests")
        from pathlib import Path
        from test_genomic_stream_writer import _big_synthetic_run, _write_with_threads
        run = _big_synthetic_run(n=200_000)
        _write_with_threads(Path(sys.argv[1]), run, int(sys.argv[2]), block_reads=20_000)
        print(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    """)

    def rss(threads):
        out = subprocess.run(
            [sys.executable, "-c", script, str(tmp_path), str(threads)],
            capture_output=True, text=True, check=True,
            cwd=str(Path(__file__).resolve().parents[1]))
        return int(out.stdout.strip().splitlines()[-1])

    one, eight = rss(1), rss(8)
    assert eight < 9 * one, (one, eight)
