"""M99: per-AU encryption over the blocks_v1 genomic layout.

The walkers stream block by block: decode one block's sequences +
qualities blobs, slice per read, encrypt one AU per read with global
AU numbering, append to the segments tables. Decrypt-in-place
reverses it and restores the channel blobs byte-identically, leaving
the block index untouched.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

pytest.importorskip("h5py")
import h5py

from _genomic_fixture import make_written_genomic_run
from ttio import SpectralDataset
from ttio.encryption_per_au import (
    decrypt_per_au,
    decrypt_per_au_in_place,
    encrypt_per_au,
)
from ttio.genomic._blocks import slice_run
from ttio.genomic.stream_writer import GenomicStreamWriter
from ttio.written_genomic_run import WrittenGenomicRun

KEY = b"\x51" * 32


def _make_run(n_reads=900, *, zero_lengths=(), seed=3):
    rng = np.random.default_rng(seed)
    lengths = rng.integers(60, 200, n_reads).astype(np.uint32)
    for i in zero_lengths:
        lengths[i] = 0
    offsets = np.zeros(n_reads, dtype=np.uint64)
    offsets[1:] = np.cumsum(lengths[:-1])
    total = int(lengths.sum())
    sequences = rng.choice(np.frombuffer(b"ACGTN", dtype=np.uint8),
                           total, p=[0.24, 0.26, 0.25, 0.24, 0.01])
    qualities = rng.integers(33, 73, total).astype(np.uint8)
    half = n_reads // 2
    return WrittenGenomicRun(
        acquisition_mode=7, reference_uri="", platform="ILLUMINA",
        sample_name="M99",
        positions=np.arange(n_reads, dtype=np.int64) * 40,
        mapping_qualities=np.full(n_reads, 60, dtype=np.uint8),
        flags=np.zeros(n_reads, dtype=np.uint32),
        sequences=sequences, qualities=qualities,
        offsets=offsets, lengths=lengths,
        cigars=[(f"{int(l)}M" if l else "*") for l in lengths],
        read_names=[f"m99r{i:06d}" for i in range(n_reads)],
        mate_chromosomes=[""] * n_reads,
        mate_positions=np.full(n_reads, -1, dtype=np.int64),
        template_lengths=np.zeros(n_reads, dtype=np.int32),
        chromosomes=(["chr1"] * half) + (["chr2"] * (n_reads - half)),
    )


def _stream_blocks_file(path, run, *, block_reads=200, **writer_kw):
    SpectralDataset.write_minimal(str(path), title="m99",
                                  isa_investigation_id="i", runs={})
    ds = SpectralDataset.open(str(path), writable=True)
    n = len(run.lengths)
    w = GenomicStreamWriter(ds.study_group, "run",
                            acquisition_mode=run.acquisition_mode,
                            reference_uri=run.reference_uri,
                            platform=run.platform,
                            sample_name=run.sample_name,
                            reference_chrom_seqs=run.reference_chrom_seqs,
                            embed_reference=(
                                run.reference_chrom_seqs is not None),
                            block_reads=block_reads, **writer_kw)
    with ds, w:
        for s in range(0, n, 100):
            w.append_batch(slice_run(run, s, min(s + 100, n)))
    return path


def _blob_state(path):
    """(index rows bytes, seq blob, qual blob, run attrs) snapshot."""
    with h5py.File(path, "r") as f:
        rg = f["study/genomic_runs/run"]
        return (
            rg["blocks/index"][...].tobytes(),
            bytes(rg["signal_channels/sequences/data"][...]),
            bytes(rg["signal_channels/qualities"][...]),
            {k: rg.attrs[k] for k in rg.attrs},
        )


class TestBlocksV1Encrypt:

    def test_encrypt_strips_channels_and_appends_aus(self, tmp_path):
        run = _make_run()
        path = _stream_blocks_file(tmp_path / "b.tio", run)
        idx_before = _blob_state(path)[0]

        encrypt_per_au(str(path), KEY)

        with h5py.File(path, "r") as f:
            sig = f["study/genomic_runs/run/signal_channels"]
            assert "sequences" not in sig
            assert "qualities" not in sig
            for ch in ("sequences", "qualities"):
                seg = sig[f"{ch}_segments"]
                assert len(seg) == len(run.lengths), (
                    "one AU per read, streamed across all blocks")
                rows = seg[...]
                assert np.array_equal(
                    rows["length"].astype(np.uint32),
                    np.asarray(run.lengths))
                want_off = np.zeros(len(run.lengths), dtype=np.uint64)
                want_off[1:] = np.cumsum(
                    np.asarray(run.lengths, dtype=np.uint64))[:-1]
                assert np.array_equal(
                    rows["offset"].astype(np.uint64), want_off), (
                    "segment offsets are global plaintext offsets")
                assert sig.attrs.get(f"{ch}_algorithm") is not None
            assert f["study/genomic_runs/run/blocks/index"][...]\
                .tobytes() == idx_before, "block index untouched"
            feats = f.attrs["ttio_features"]
            feats = feats.decode() if isinstance(feats, bytes) else feats
            assert "opt_per_au_encryption" in feats

    def test_read_only_decrypt_parity(self, tmp_path):
        run = _make_run(seed=5)
        path = _stream_blocks_file(tmp_path / "b.tio", run)
        encrypt_per_au(str(path), KEY)

        plain = decrypt_per_au(str(path), KEY)
        got = plain["run"]
        assert bytes(np.asarray(got["sequences"], dtype=np.uint8)
                     .tobytes()) == np.asarray(run.sequences).tobytes()
        assert bytes(np.asarray(got["qualities"], dtype=np.uint8)
                     .tobytes()) == np.asarray(run.qualities).tobytes()


class TestBlocksV1RoundTrip:

    def _round_trip(self, tmp_path, run, **writer_kw):
        path = _stream_blocks_file(tmp_path / "b.tio", run, **writer_kw)
        pristine = tmp_path / "pristine.tio"
        shutil.copyfile(path, pristine)
        before = _blob_state(path)

        encrypt_per_au(str(path), KEY)
        decrypt_per_au_in_place(str(path), KEY)

        after = _blob_state(path)
        assert after[0] == before[0], "block index byte-identical"
        assert after[1] == before[1], "sequences blob byte-identical"
        assert after[2] == before[2], "qualities blob byte-identical"

        with h5py.File(path, "r") as f:
            feats = f.attrs["ttio_features"]
            feats = feats.decode() if isinstance(feats, bytes) else feats
            assert "opt_per_au_encryption" not in feats
            sig = f["study/genomic_runs/run/signal_channels"]
            assert "sequences_segments" not in sig
            assert "qualities_segments" not in sig

        ds = SpectralDataset.open(str(path))
        gr = ds.genomic_runs["run"]
        n = len(run.lengths)
        for i in (0, 1, n // 2, n - 1):
            rd = gr[i]
            lo = int(np.asarray(run.offsets)[i])
            ln = int(np.asarray(run.lengths)[i])
            assert rd.sequence.encode("ascii") == bytes(
                np.asarray(run.sequences[lo:lo + ln], dtype=np.uint8)
                .tobytes())
            assert rd.read_name == run.read_names[i]

    def test_round_trip_plain(self, tmp_path):
        self._round_trip(tmp_path, _make_run(seed=7))

    def test_round_trip_zero_length_reads(self, tmp_path):
        self._round_trip(
            tmp_path, _make_run(seed=9, zero_lengths=(120, 121, 700)))

    def test_round_trip_ref_diff(self, tmp_path):
        run = make_written_genomic_run(n_reads=300, read_len=120,
                                       with_reference=True, paired=True)
        self._round_trip(tmp_path, run, block_reads=80)

    def test_round_trip_cross_chromosome_mates(self, tmp_path):
        """Mate chrom ids come from the run-wide name map; the
        per-block re-encode must reproduce them byte-exactly."""
        rng = np.random.default_rng(21)
        n = 600
        lengths = rng.integers(60, 150, n).astype(np.uint32)
        offsets = np.zeros(n, dtype=np.uint64)
        offsets[1:] = np.cumsum(lengths[:-1])
        total = int(lengths.sum())
        run = WrittenGenomicRun(
            acquisition_mode=7, reference_uri="", platform="ILLUMINA",
            sample_name="M99",
            positions=np.arange(n, dtype=np.int64) * 40,
            mapping_qualities=np.full(n, 60, dtype=np.uint8),
            flags=np.full(n, 0x1, dtype=np.uint32),
            sequences=rng.choice(
                np.frombuffer(b"ACGT", dtype=np.uint8), total),
            qualities=rng.integers(33, 73, total).astype(np.uint8),
            offsets=offsets, lengths=lengths,
            cigars=[f"{int(l)}M" for l in lengths],
            read_names=[f"r{i}" for i in range(n)],
            mate_chromosomes=(["chr2"] * 300) + (["chr1"] * 300),
            mate_positions=rng.integers(0, 10_000, n).astype(np.int64),
            template_lengths=rng.integers(-500, 500, n).astype(np.int32),
            chromosomes=(["chr1"] * 300) + (["chr2"] * 300),
        )
        self._round_trip(tmp_path, run, block_reads=150)


class TestBlocksV1Transport:

    def test_send_refuses_blocks_v1_containers(self, tmp_path):
        """The v1.0 encrypted transport stream does not carry the
        blocks_v1 sidecars; the sender must refuse rather than emit a
        stream whose received container cannot be restored."""
        run = _make_run(n_reads=300, seed=11)
        path = _stream_blocks_file(tmp_path / "b.tio", run)
        encrypt_per_au(str(path), KEY)

        from ttio.transport.codec import TransportWriter
        from ttio.transport.encrypted import write_encrypted_dataset

        out = tmp_path / "stream.tis"
        with pytest.raises(ValueError, match="blocks_v1"):
            with TransportWriter(str(out)) as writer:
                write_encrypted_dataset(writer, str(path))


class TestBlocksV1Memory:

    def test_encrypt_rss_bounded_by_block_size(self, tmp_path):
        """A run much larger than one block encrypts within a peak-RSS
        envelope set by the block size, not the run size.

        The write happens in this process; the encrypt runs in a
        FRESH subprocess so its ru_maxrss delta reflects the walker
        alone, not the writer's own high-water. The run carries
        ~50 MB per channel across ~20 blocks; a whole-channel walker
        needs > 100 MB over baseline (two decoded channels plus the
        segment tables), a block-wise walker a few MB.
        """
        run = _make_run(n_reads=400_000, seed=13)
        path = _stream_blocks_file(tmp_path / "big.tio", run,
                                   block_reads=20_000)
        script = tmp_path / "rss_probe.py"
        script.write_text(
            "import resource, sys\n"
            "from ttio.encryption_per_au import encrypt_per_au\n"
            "before = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss\n"
            "encrypt_per_au(sys.argv[1], b'\\x51' * 32)\n"
            "after = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss\n"
            "print((after - before) * 1024)\n"
        )
        out = subprocess.run(
            [sys.executable, str(script), str(path)],
            capture_output=True, text=True, timeout=600)
        assert out.returncode == 0, out.stderr[-800:]
        delta = int(out.stdout.strip().splitlines()[-1])
        assert delta < 60 * 1024 * 1024, (
            f"peak RSS grew {delta / 1e6:.1f} MB during encrypt; "
            "expected a block-bounded walker")
