"""Qualities V5 (sequence-context) — wrapper dispatch, the writer
gate, reader ordering, and the golden decode fixture."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ttio.codecs import fqzcomp_nx16_z as fz

FIXDIR = Path(__file__).parent / "fixtures" / "codecs"


def _motif_corpus(n_reads: int = 11000, length: int = 100):
    """Quality is a function of the current base plus 2 bits of noise
    and bases are i.i.d., so the V4 contexts carry nothing while the
    sequence window recovers ~2 bits per quality."""
    rng = np.random.default_rng(7)
    bases = np.frombuffer(b"ACGT", dtype=np.uint8)
    bi = rng.integers(0, 4, n_reads * length)
    seq = bases[bi]
    qual = (40 + 10 * bi + rng.integers(0, 4, bi.shape[0])).astype(np.uint8)
    lens = [length] * n_reads
    flags = [0] * n_reads
    return bytes(qual), bytes(seq), lens, flags


class TestWrapper:
    def test_v5_emitted_and_smaller(self):
        qual, seq, lens, flags = _motif_corpus()
        v4 = fz.encode(qual, lens, flags)
        v5 = fz.encode(qual, lens, flags, sequences=seq)
        assert v4[4] == 4
        assert v5[4] == 5
        assert len(v5) < len(v4)

    def test_no_sequences_is_byte_identical_v4(self):
        qual, _seq, lens, flags = _motif_corpus(n_reads=2000)
        assert fz.encode(qual, lens, flags) == \
            fz.encode(qual, lens, flags, sequences=None)

    def test_v5_round_trips(self):
        qual, seq, lens, flags = _motif_corpus()
        blob = fz.encode(qual, lens, flags, sequences=seq)
        back, back_lens, _rc = fz.decode_with_metadata(
            blob, flags, sequences_provider=lambda: seq)
        assert bytes(back) == qual
        assert list(back_lens) == lens

    def test_v5_decode_without_sequences_raises(self):
        qual, seq, lens, flags = _motif_corpus()
        blob = fz.encode(qual, lens, flags, sequences=seq)
        assert blob[4] == 5
        with pytest.raises(ValueError, match="sequences"):
            fz.decode_with_metadata(blob, flags)

    def test_v5_decode_length_mismatch_raises(self):
        qual, seq, lens, flags = _motif_corpus()
        blob = fz.encode(qual, lens, flags, sequences=seq)
        with pytest.raises(ValueError, match="sequences"):
            fz.decode_with_metadata(
                blob, flags, sequences_provider=lambda: seq[:-1])

    def test_small_channel_stays_v4(self):
        qual, seq, lens, flags = _motif_corpus(n_reads=300)
        assert fz.encode(qual, lens, flags, sequences=seq)[4] == 4

    def test_encode_length_mismatch_raises(self):
        qual, seq, lens, flags = _motif_corpus(n_reads=300)
        with pytest.raises(ValueError, match="sequences"):
            fz.encode(qual, lens, flags, sequences=seq[:-1])

    def test_forced_strategy_emits_v5_below_floor(self):
        qual, seq, lens, flags = _motif_corpus(n_reads=300)
        blob = fz.encode(qual, lens, flags, sequences=seq,
                         v4_strategy_hint=5)
        assert blob[4] == 5
        back, _lens, _rc = fz.decode_with_metadata(
            blob, flags, sequences_provider=lambda: seq)
        assert bytes(back) == qual

    def test_hint_v4_auto_ignores_sequences(self):
        qual, seq, lens, flags = _motif_corpus()
        pinned = fz.encode(qual, lens, flags, sequences=seq,
                           v4_strategy_hint=fz.HINT_V4_AUTO)
        assert pinned == fz.encode(qual, lens, flags)

    def test_stream_strategy_sniffer(self):
        qual, seq, lens, flags = _motif_corpus(n_reads=300)
        v4 = fz.encode(qual, lens, flags)
        assert fz.stream_strategy(v4) == 4
        s5 = fz.encode(qual, lens, flags, sequences=seq,
                       v4_strategy_hint=5)
        assert fz.stream_strategy(s5) == 5
        s6 = fz.encode(qual, lens, flags, sequences=seq,
                       v4_strategy_hint=6)
        assert fz.stream_strategy(s6) == 6
        with pytest.raises(ValueError):
            fz.stream_strategy(b"XX")


class TestGolden:
    def test_golden_decodes(self):
        blob = (FIXDIR / "qualities_v5_golden.bin").read_bytes()
        seq = (FIXDIR / "qualities_v5_golden_seq.bin").read_bytes()
        expected = (FIXDIR / "qualities_v5_golden_qual.bin").read_bytes()
        back, lens, _rc = fz.decode_with_metadata(
            blob, [0] * 300, sequences_provider=lambda: seq)
        assert bytes(back) == expected
        assert lens == [100] * 300

    def test_v6_golden_decodes(self):
        blob = (FIXDIR / "qualities_v6_golden.bin").read_bytes()
        expected = (FIXDIR / "qualities_v6_golden_qual.bin").read_bytes()
        assert blob[4] == 6
        back, lens, _rc = fz.decode_with_metadata(blob, [0] * 300)
        assert bytes(back) == expected
        assert lens == [100] * 300


def _written_run(*, n_reads: int, length: int = 100, disable: bool = False):
    from ttio.enums import Compression
    from ttio.written_genomic_run import WrittenGenomicRun

    qual, seq, lens, _flags = _motif_corpus(n_reads=n_reads, length=length)
    positions = np.arange(n_reads, dtype=np.int64) * 100 + 10_000
    return WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="NA12878",
        positions=positions,
        mapping_qualities=np.full(n_reads, 60, dtype=np.uint8),
        flags=np.zeros(n_reads, dtype=np.uint32),
        sequences=np.frombuffer(seq, dtype=np.uint8),
        qualities=np.frombuffer(qual, dtype=np.uint8),
        offsets=np.arange(n_reads, dtype=np.uint64) * length,
        lengths=np.full(n_reads, length, dtype=np.uint32),
        cigars=[f"{length}M" for _ in range(n_reads)],
        read_names=[f"read_{i:06d}" for i in range(n_reads)],
        mate_chromosomes=["*" for _ in range(n_reads)],
        mate_positions=np.full(n_reads, -1, dtype=np.int64),
        template_lengths=np.zeros(n_reads, dtype=np.int32),
        chromosomes=["chr1"] * n_reads,
        # No reference in this synthetic run, so the v1.5 qualities
        # auto-default does not fire; select codec 12 explicitly. The
        # V5 gate applies to both selection routes.
        signal_codec_overrides={"qualities": Compression.FQZCOMP_NX16_Z},
        opt_disable_qualities_v5=disable,
    ), qual


class TestFileLevel:
    def _write(self, tmp_path, **kw):
        from ttio.spectral_dataset import SpectralDataset
        run, qual = _written_run(**kw)
        p = tmp_path / "v5.tio"
        SpectralDataset.write_minimal(
            p, title="v5", isa_investigation_id="V5",
            runs={"genomic_0001": run})
        return p, qual

    def test_file_round_trip_v5(self, tmp_path):
        from ttio.spectral_dataset import SpectralDataset
        import h5py
        p, qual = self._write(tmp_path, n_reads=11000)
        with h5py.File(p, "r") as f:
            blob = bytes(
                f["/study/genomic_runs/genomic_0001/signal_channels/"
                  "qualities"][()])
            assert blob[4] == 5
        with SpectralDataset.open(p) as ds:
            run = ds.genomic_runs["genomic_0001"]
            got = b"".join(run[i].qualities for i in range(3))
            assert got == qual[:300]

    def test_opt_disable_stays_v4(self, tmp_path):
        import h5py
        p, _ = self._write(tmp_path, n_reads=11000, disable=True)
        with h5py.File(p, "r") as f:
            blob = bytes(
                f["/study/genomic_runs/genomic_0001/signal_channels/"
                  "qualities"][()])
            assert blob[4] == 4


def test_autotune_threads_setter_round_trips():
    from ttio.codecs import fqzcomp_nx16_z as fz
    from ttio.codecs._native_loader import load_ttio_rans
    if load_ttio_rans() is None:
        pytest.skip("native lib")
    before = fz.get_autotune_threads()
    try:
        fz.set_autotune_threads(1)
        assert fz.get_autotune_threads() == 1
        fz.set_autotune_threads(3)
        assert fz.get_autotune_threads() == 3
    finally:
        fz.set_autotune_threads(before)


def test_v6_round_trips_and_sniffs():
    qual, _seq, lens, flags = _motif_corpus(n_reads=2000)
    blob = fz.encode(qual, lens, flags, v4_strategy_hint=fz.HINT_V6)
    assert blob[4] == 6
    assert fz.stream_strategy(blob) == 8
    back, back_lens, _rc = fz.decode_with_metadata(blob, flags)
    assert bytes(back) == qual
    assert list(back_lens) == list(lens)


def test_v6_decode_needs_no_sequences():
    """V6 builds its context from qualities alone, so unlike V5 it must
    decode with no sequences_provider at all."""
    qual, _seq, lens, flags = _motif_corpus(n_reads=2000)
    blob = fz.encode(qual, lens, flags, v4_strategy_hint=fz.HINT_V6)
    back, _lens, _rc = fz.decode_with_metadata(
        blob, flags, sequences_provider=None)
    assert bytes(back) == qual


def test_auto_never_picks_v6():
    qual, seq, lens, flags = _motif_corpus()
    assert fz.encode(qual, lens, flags, sequences=seq)[4] in (4, 5)
