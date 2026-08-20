"""GenomicStreamWriter writes the blocks_v1 layout (format-spec 10.12)."""
from __future__ import annotations

import dataclasses

import numpy as np
import pytest

from _genomic_fixture import make_written_genomic_run
from ttio import _hdf5_io as io
from ttio.enums import Compression
from ttio.genomic import GenomicStreamWriter, _blocks
from ttio.providers.hdf5 import Hdf5Provider
from ttio.spectral_dataset import SpectralDataset


def _open_run_group(path, name):
    prov = Hdf5Provider.open(path, mode="r")
    return prov, prov.root_group().open_group("study").open_group("genomic_runs").open_group(name)


def _stream(path, run, **kw):
    SpectralDataset.write_minimal(path, title="t", isa_investigation_id="i", runs={})
    ds = SpectralDataset.open(path, writable=True)
    w = GenomicStreamWriter(ds.study_group, "run", acquisition_mode=run.acquisition_mode,
                            reference_uri=run.reference_uri, platform=run.platform,
                            sample_name=run.sample_name,
                            reference_chrom_seqs=run.reference_chrom_seqs,
                            embed_reference=True, **kw)
    return ds, w


def test_multi_block_layout(tmp_path):
    run = make_written_genomic_run(n_reads=100, read_len=20, with_reference=True, paired=True)
    p = str(tmp_path / "s.tio")
    ds, w = _stream(p, run, block_reads=30)
    with ds, w:
        for s in range(0, 100, 10):
            w.append_batch(_blocks.slice_run(run, s, s + 10))
    assert w.read_count == 100 and w.block_count == 4
    prov, rg = _open_run_group(p, "run")
    assert io.read_string_attr(rg, "layout") == "blocks_v1"
    rows = rg.open_group("blocks").open_dataset("index").read_rows()
    assert [int(r["n_reads"]) for r in rows] == [30, 30, 30, 10]
    assert [int(r["read_start"]) for r in rows] == [0, 30, 60, 90]
    assert [int(r["base_start"]) for r in rows] == [0, 600, 1200, 1800]
    q = rg.open_group("signal_channels").open_dataset("qualities")
    assert int(rows[-1]["qualities_off"] + rows[-1]["qualities_len"]) == q.length
    assert int(rg.get_attribute("read_count")) == 100
    assert int(rg.get_attribute("base_count")) == 2000
    idx = rg.open_group("genomic_index")
    assert idx.open_dataset("positions").length == 100
    names = [r["name"] for r in idx.open_dataset("chromosome_names").read_rows()]
    assert [n.decode() if isinstance(n, bytes) else n for n in names] == ["chr1"]
    prov.close()


def test_block_blob_equals_whole_run_writer_for_that_block(tmp_path):
    run = make_written_genomic_run(n_reads=60, read_len=20, with_reference=True, paired=True)
    p = str(tmp_path / "s.tio")
    ds, w = _stream(p, run, block_reads=25)
    with ds, w:
        w.append_batch(run)
    prov, rg = _open_run_group(p, "run")
    rows = rg.open_group("blocks").open_dataset("index").read_rows()
    assert len(rows) == 3
    blk1 = _blocks.slice_run(run, 25, 50)
    blk1.chrom_name_to_id = {"chr1": 0}
    expected = _blocks.encode_block(blk1)
    sc = rg.open_group("signal_channels")
    for ch, ds_ in (("qualities", sc.open_dataset("qualities")),
                    ("read_names", sc.open_dataset("read_names")),
                    ("cigars", sc.open_dataset("cigars")),
                    ("mate_info", sc.open_group("mate_info").open_dataset("inline_v2")),
                    ("sequences", sc.open_group("sequences").open_dataset("data"))):
        off, ln = int(rows[1][f"{ch}_off"]), int(rows[1][f"{ch}_len"])
        assert ds_.read(off, ln).tobytes() == expected.blobs[ch], ch
        assert int(ds_.get_attribute("compression")) == expected.compression[ch], ch
    prov.close()


def test_byte_cap_splits_blocks(tmp_path):
    run = make_written_genomic_run(n_reads=40, read_len=100)
    p = str(tmp_path / "b.tio")
    ds, w = _stream(p, run, block_reads=10 ** 6, block_bytes=1000)
    with ds, w:
        w.append_batch(run)
    prov, rg = _open_run_group(p, "run")
    rows = rg.open_group("blocks").open_dataset("index").read_rows()
    assert [int(r["n_reads"]) for r in rows] == [10, 10, 10, 10]
    prov.close()


def test_write_minimal_default_is_blocks_v1_and_legacy_opt_out(tmp_path):
    run = make_written_genomic_run(n_reads=10, read_len=20)
    p = str(tmp_path / "d.tio")
    SpectralDataset.write_minimal(p, title="t", isa_investigation_id="i", runs={},
                                  genomic_runs={"g": run})
    prov, rg = _open_run_group(p, "g")
    assert io.read_string_attr(rg, "layout") == "blocks_v1"
    prov.close()
    legacy = dataclasses.replace(run, opt_legacy_whole_channel=True)
    p2 = str(tmp_path / "l.tio")
    SpectralDataset.write_minimal(p2, title="t", isa_investigation_id="i", runs={},
                                  genomic_runs={"g": legacy})
    prov, rg = _open_run_group(p2, "g")
    assert not rg.has_attribute("layout")
    prov.close()


def test_placed_unmapped_read_keeps_refdiff_block(tmp_path):
    """A mate-placed unmapped read (RNAME set, FLAG 0x4, CIGAR '*') inside a
    mapped block does not push the block's sequences to BASE_PACK: the
    codec column stays REF_DIFF_V2 and every read reads back."""
    import h5py
    from ttio.codecs import ref_diff_v2 as rdv2
    if not rdv2.HAVE_NATIVE_LIB:
        pytest.skip("native lib")
    from ttio.spectral_dataset import SpectralDataset
    from ttio.written_genomic_run import WrittenGenomicRun
    n, L = 40, 60
    ref = bytes(ord("ACGT"[(i * 7 + i // 3) % 4]) for i in range(5000))
    positions = (np.arange(n) * 30 + 1).astype(np.int64)
    cigars = [f"{L}M"] * n
    flags = np.full(n, 0x3, dtype=np.uint32)
    seqs = bytearray()
    for i in range(n):
        seqs.extend(ref[int(positions[i]) - 1:int(positions[i]) - 1 + L])
    for i in (5, 21):  # placed unmapped: mate's position, no alignment
        cigars[i] = "*"
        flags[i] = 0x4 | 0x1
        seqs[i * L:(i + 1) * L] = (b"GATTACA" * 10)[:L]
    run = WrittenGenomicRun(
        acquisition_mode=7, reference_uri="chr9", platform="ILLUMINA", sample_name="s",
        positions=positions, mapping_qualities=np.full(n, 60, dtype=np.uint8), flags=flags,
        sequences=np.frombuffer(bytes(seqs), dtype=np.uint8),
        qualities=np.frombuffer(bytes([30]) * (n * L), dtype=np.uint8),
        offsets=(np.arange(n) * L).astype(np.uint64), lengths=np.full(n, L, dtype=np.uint32),
        cigars=cigars, read_names=[f"r{i}" for i in range(n)],
        mate_chromosomes=[""] * n, mate_positions=np.full(n, -1, dtype=np.int64),
        template_lengths=np.zeros(n, dtype=np.int32), chromosomes=["chr9"] * n,
        reference_chrom_seqs={"chr9": ref}, embed_reference=True,
    )
    out = tmp_path / "placed.tio"
    SpectralDataset.write_minimal(out, title="t", isa_investigation_id="", runs={},
                                  genomic_runs={"g": run})
    with h5py.File(out, "r") as f:
        idx = f["study/genomic_runs/g/blocks/index"][:]
        assert set(int(x) for x in idx["sequences_codec"]) == {14}
    with SpectralDataset.open(out) as ds:
        g = ds.genomic_runs["g"]
        got = b"".join(r.sequence.encode() for r in g.iter_reads())
        assert got == bytes(seqs)
        assert g[5].cigar == "*" and g[21].cigar == "*"


def _big_synthetic_run(n=60_000, seed=7):
    """A synthetic run over two chromosomes with placed-unmapped reads and
    cross-chromosome mates, big enough for several 20k-read blocks."""
    from ttio.written_genomic_run import WrittenGenomicRun
    rng = np.random.default_rng(seed)
    L = 100
    ref = {"chr1": bytes(rng.choice(list(b"ACGT"), 400_000)),
           "chr2": bytes(rng.choice(list(b"ACGT"), 400_000))}
    half = n // 2
    chroms = ["chr1"] * half + ["chr2"] * (n - half)
    positions = np.concatenate([np.sort(rng.integers(1, 399_000, half)),
                                np.sort(rng.integers(1, 399_000, n - half))]).astype(np.int64)
    seqs = bytearray()
    cigars, mates = [], []
    flags = np.full(n, 0x3, dtype=np.uint32)
    mpos = np.full(n, -1, dtype=np.int64)
    for i in range(n):
        s_ = bytearray(ref[chroms[i]][positions[i] - 1:positions[i] - 1 + L])
        for k in rng.integers(0, L, 3):
            s_[k] = ord("ACGT"[rng.integers(0, 4)])
        seqs.extend(s_)
        if i % 97 == 0:
            cigars.append("*"); flags[i] = 0x5
        else:
            cigars.append(f"{L}M")
        if i % 13 == 0:
            mates.append("chr2" if chroms[i] == "chr1" else "chr1"); mpos[i] = int(positions[(i * 7) % n])
        elif i % 3 == 0:
            mates.append("="); mpos[i] = int(positions[i]) + 200
        else:
            mates.append("")
    return WrittenGenomicRun(
        acquisition_mode=7, reference_uri="synthetic", platform="ILLUMINA", sample_name="s",
        positions=positions, mapping_qualities=np.full(n, 60, dtype=np.uint8), flags=flags,
        sequences=np.frombuffer(bytes(seqs), dtype=np.uint8),
        qualities=np.frombuffer(bytes(rng.integers(2, 40, n * L, dtype=np.uint8)), dtype=np.uint8),
        offsets=(np.arange(n) * L).astype(np.uint64), lengths=np.full(n, L, dtype=np.uint32),
        cigars=cigars, read_names=[f"r{i:06d}" for i in range(n)],
        mate_chromosomes=mates, mate_positions=mpos,
        template_lengths=np.zeros(n, dtype=np.int32), chromosomes=chroms,
        reference_chrom_seqs=ref, embed_reference=True,
    )


def _write_with_threads(tmp_path, run, threads, block_reads=20_000):
    out = tmp_path / f"t{threads}.tio"
    SpectralDataset.write_minimal(out, title="t", isa_investigation_id="i", runs={})
    ds = SpectralDataset.open(out, writable=True)
    with GenomicStreamWriter(ds.study_group, "g", acquisition_mode=7, reference_uri="synthetic",
                             platform="ILLUMINA", sample_name="s",
                             reference_chrom_seqs=run.reference_chrom_seqs, embed_reference=True,
                             block_reads=block_reads, threads=threads) as w:
        n = int(len(run.lengths))
        for a in range(0, n, 7_001):          # blocks are cut inside batches
            w.append_batch(_blocks.slice_run(run, a, min(n, a + 7_001)))
        assert w.threads == threads
    ds.close()
    return out


def _run_bytes(path):
    """Every genomic dataset's raw bytes and every attribute, in a stable
    order: the identity contract between the serial and threaded writer."""
    import h5py
    out = {}
    with h5py.File(path, "r") as f:
        def visit(name, obj):
            if name.startswith("study/genomic_runs") or name.startswith("study/references"):
                attrs = {k: (v.tobytes() if hasattr(v, "tobytes") else v) for k, v in obj.attrs.items()}
                data = None
                if isinstance(obj, h5py.Dataset) and obj.shape != ():
                    arr = obj[()]
                    # a VL string dataset's buffer holds pointers; compare its values
                    data = repr(arr.tolist()) if h5py.check_vlen_dtype(obj.dtype) or arr.dtype.kind == "O"                         or (arr.dtype.fields and any(h5py.check_vlen_dtype(t[0]) for t in arr.dtype.fields.values()))                         else arr.tobytes()
                out[name] = (attrs, data)
        f.visititems(visit)
    return out


def test_threaded_writer_is_byte_identical_to_serial(tmp_path):
    from ttio.codecs import ref_diff_v2 as rdv2
    if not rdv2.HAVE_NATIVE_LIB:
        pytest.skip("native lib")
    run = _big_synthetic_run()
    a = _write_with_threads(tmp_path, run, 1)
    b = _write_with_threads(tmp_path, run, 6)
    ba, bb = _run_bytes(a), _run_bytes(b)
    assert ba.keys() == bb.keys()
    for k in ba:
        assert ba[k] == bb[k], f"{k} differs between threads=1 and threads=6"
    with SpectralDataset.open(b) as ds:
        g = ds.genomic_runs["g"]
        assert len(g) == 60_000
        assert g.layout == "blocks_v1" and g.block_count == 4   # 20k, 10k (chr1 ends), 20k, 10k
        assert g[97].cigar == "*" and g[0].cigar == "*" and g[98].cigar == "100M"
        assert g[59_999].sequence == run.sequences.tobytes()[59_999 * 100:].decode()


def _sticky_bytes(tmp_path, run, sub, threads=6):
    d = tmp_path / sub
    d.mkdir()
    return _run_bytes(_write_with_threads(d, run, threads))


def test_sticky_pin_matches_exhaustive(tmp_path, monkeypatch):
    from ttio.codecs import ref_diff_v2 as rdv2
    if not rdv2.HAVE_NATIVE_LIB:
        pytest.skip("native lib")
    run = _big_synthetic_run(n=40_000)
    a = _sticky_bytes(tmp_path, run, "sticky")
    monkeypatch.setenv("TTIO_M94Z_EXHAUSTIVE", "1")
    b = _sticky_bytes(tmp_path, run, "exhaustive")
    assert a.keys() == b.keys()
    for k in a:
        assert a[k] == b[k], f"{k} differs between sticky and exhaustive"


def test_sticky_deterministic_across_runs(tmp_path):
    from ttio.codecs import ref_diff_v2 as rdv2
    if not rdv2.HAVE_NATIVE_LIB:
        pytest.skip("native lib")
    run = _big_synthetic_run(n=40_000)
    assert _sticky_bytes(tmp_path, run, "r1") == \
        _sticky_bytes(tmp_path, run, "r2")


def test_pin_is_set_after_first_block(tmp_path):
    from ttio.codecs import ref_diff_v2 as rdv2
    if not rdv2.HAVE_NATIVE_LIB:
        pytest.skip("native lib")
    run = _big_synthetic_run(n=40_000)
    out = tmp_path / "pin.tio"
    SpectralDataset.write_minimal(out, title="t", isa_investigation_id="i", runs={})
    ds = SpectralDataset.open(out, writable=True)
    with GenomicStreamWriter(ds.study_group, "g", acquisition_mode=7,
                             reference_uri="synthetic", platform="ILLUMINA",
                             sample_name="s",
                             reference_chrom_seqs=run.reference_chrom_seqs,
                             embed_reference=True, block_reads=20_000,
                             threads=2) as w:
        w.append_batch(run)
    ds.close()
    assert w._qual_hint != -1


def _mini(chroms, mates):
    return make_written_genomic_run(len(chroms), 8, chromosomes=chroms, mate_chromosomes=mates)


def test_register_block_chromosomes_matches_the_encoder_order():
    from ttio.genomic.stream_writer import register_block_chromosomes
    m = {}
    register_block_chromosomes(_mini(["chr2", "*", "chr2"], ["chr1", "*", "="]), m)
    assert m == {"chr2": 0, "*": 1, "chr1": 2}
    register_block_chromosomes(_mini(["chr3"], ["chr2"]), m)
    assert m == {"chr2": 0, "*": 1, "chr1": 2, "chr3": 3}


def test_threads_default_and_window(monkeypatch, tmp_path):
    monkeypatch.setenv("TTIO_THREADS", "4")
    out = tmp_path / "w.tio"
    SpectralDataset.write_minimal(out, title="t", isa_investigation_id="i", runs={})
    ds = SpectralDataset.open(out, writable=True)
    w = GenomicStreamWriter(ds.study_group, "g", acquisition_mode=7,
                            reference_uri="", platform="", sample_name="")
    assert w.threads == 4 and w._window == 5
    w.close(); ds.close()


def test_budget_bounds_inflight_bytes(tmp_path):
    from ttio.codecs import ref_diff_v2 as rdv2
    if not rdv2.HAVE_NATIVE_LIB:
        pytest.skip("native lib")
    run = _big_synthetic_run()
    a = _write_with_threads(tmp_path, run, 1, block_reads=2_000)
    out = tmp_path / "budget.tio"
    SpectralDataset.write_minimal(out, title="t", isa_investigation_id="i", runs={})
    ds = SpectralDataset.open(out, writable=True)
    with GenomicStreamWriter(ds.study_group, "g", acquisition_mode=7, reference_uri="synthetic",
                             platform="ILLUMINA", sample_name="s",
                             reference_chrom_seqs=run.reference_chrom_seqs, embed_reference=True,
                             block_reads=2_000, threads=6,
                             memory_budget_bytes=4 * 2**20) as w:
        n = int(len(run.lengths))
        for s0 in range(0, n, 7_001):
            w.append_batch(_blocks.slice_run(run, s0, min(n, s0 + 7_001)))
    high = w.max_inflight_bytes_observed
    ds.close()
    assert 0 < high <= 2 * 2**20
    ba, bb = _run_bytes(a), _run_bytes(out)
    assert ba.keys() == bb.keys()
    for k in ba:
        assert ba[k] == bb[k], f"{k} differs under the byte budget"
