"""Vectorised slice parser and parallel producer tests.

SPDX-License-Identifier: Apache-2.0
"""
import numpy as np
import pytest

from ttio.importers.fastq import FastqParseError
from ttio.importers.fastq_parallel import parse_slice


def _fq(records, eol=b"\n"):
    out = bytearray()
    for name, seq, qual in records:
        out += b"@" + name + eol + seq + eol + b"+" + eol + qual + eol
    return bytes(out)


RECS = [(b"r0 extra tag", b"ACGT", b"II@I"),
        (b"r1", b"", b""),                       # zero-length read
        (b"r2", b"GGGGTTTT", b"JJJJKKKK")]


def _check(names, seq, qual, lens):
    assert names == ["r0", "r1", "r2"]
    assert bytes(seq) == b"ACGT" + b"" + b"GGGGTTTT"
    assert bytes(qual) == b"II@I" + b"" + b"JJJJKKKK"
    assert lens.tolist() == [4, 0, 8]
    assert lens.dtype == np.uint32


def test_clean_slice_fast_path():
    _check(*parse_slice(_fq(RECS)))


def test_crlf_slice():
    _check(*parse_slice(_fq(RECS, eol=b"\r\n")))


def test_stray_blank_line_falls_back():
    data = _fq(RECS[:1]) + b"\n" + _fq(RECS[1:])
    _check(*parse_slice(data))


def test_length_mismatch_raises():
    with pytest.raises(FastqParseError):
        parse_slice(_fq([(b"r0", b"ACGT", b"III")]))


def test_missing_trailing_newline():
    _check(*parse_slice(_fq(RECS)[:-1]))


def _mixed_fixture(tmp_path, gz, n=200, seed=3):
    import gzip as gzmod
    import random
    rng = random.Random(seed)
    path = tmp_path / ("m.fastq.gz" if gz else "m.fastq")
    op = (lambda p: gzmod.open(p, "wb")) if gz else (lambda p: open(p, "wb"))
    with op(path) as f:
        for i in range(n):
            ln = rng.choice([0, 1, 7, 150, 1500, 5000])
            seq = bytes(rng.choice(b"ACGT") for _ in range(ln))
            qual = bytes(rng.randrange(33, 74) for _ in range(ln))
            f.write(b"@read_%d/1 c%d\n" % (i, i) + seq + b"\n+\n" + qual + b"\n")
    return path


def _batches(path, threads, **kw):
    from ttio.importers.fastq import FastqReader
    return list(FastqReader(path).iter_batches(threads=threads, **kw))


def _assert_batches_equal(a, b):
    assert len(a) == len(b)
    for x, y in zip(a, b):
        assert x.read_names == y.read_names
        for f in ("sequences", "qualities", "offsets", "lengths",
                  "positions", "flags", "mapping_qualities"):
            assert np.array_equal(getattr(x, f), getattr(y, f)), f
        assert x.chromosomes == y.chromosomes and x.cigars == y.cigars


def test_pipeline_identical_to_serial(tmp_path):
    fq = _mixed_fixture(tmp_path, gz=True)
    serial = _batches(fq, 1, batch_bytes=32_768)
    para = _batches(fq, 4, batch_bytes=32_768)
    assert len(serial) > 3
    _assert_batches_equal(serial, para)


def test_shard_identical_to_serial(tmp_path):
    from ttio.importers.fastq_parallel import plan_input
    fq = _mixed_fixture(tmp_path, gz=False, n=400, seed=11)
    mode, ranges = plan_input(fq, 4, 16_384)
    assert mode == "shard" and len(ranges) > 2
    assert ranges[0][0] == 0 and ranges[-1][1] == fq.stat().st_size
    serial = _batches(fq, 1, batch_bytes=16_384)
    para = _batches(fq, 4, batch_bytes=16_384)
    _assert_batches_equal(serial, para)


def test_sparse_shards_identical_to_serial(tmp_path):
    from ttio.importers.fastq_parallel import plan_input
    fq = _mixed_fixture(tmp_path, gz=False, n=6, seed=5)
    mode, ranges = plan_input(fq, 8, 64 * 2**20)
    assert mode == "shard" and ranges == [(0, fq.stat().st_size)]
    _assert_batches_equal(_batches(fq, 1), _batches(fq, 8))
