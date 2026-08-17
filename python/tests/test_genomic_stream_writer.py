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
                    ("sequences", sc.open_group("sequences").open_dataset("refdiff_v2"))):
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
