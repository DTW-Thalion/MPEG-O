"""GenomicStreamWriter writes the blocks_v1 layout (format-spec 10.12)."""
from __future__ import annotations

import dataclasses

import numpy as np

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
