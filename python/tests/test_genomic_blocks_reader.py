"""Reading blocks_v1 runs: random access, iteration, region queries,
partially written files."""
from __future__ import annotations

import pytest

from _genomic_fixture import make_written_genomic_run
from ttio.genomic import GenomicStreamWriter
from ttio.spectral_dataset import SpectralDataset


def _write(tmp_path, run, name="b.tio", **kw):
    p = str(tmp_path / name)
    SpectralDataset.write_minimal(p, title="t", isa_investigation_id="i", runs={})
    ds = SpectralDataset.open(p, writable=True)
    with ds, GenomicStreamWriter(ds.study_group, "run", acquisition_mode=run.acquisition_mode,
                                 reference_uri=run.reference_uri, platform=run.platform,
                                 sample_name=run.sample_name,
                                 reference_chrom_seqs=run.reference_chrom_seqs,
                                 embed_reference=True, **kw) as w:
        w.append_batch(run)
    return p


def _check_read(r, run, i):
    assert r.read_name == run.read_names[i]
    o, l = int(run.offsets[i]), int(run.lengths[i])
    assert r.sequence == run.sequences[o:o + l].tobytes().decode()
    assert list(r.qualities) == run.qualities[o:o + l].tolist()
    assert r.cigar == run.cigars[i]
    assert r.position == int(run.positions[i])
    assert r.chromosome == run.chromosomes[i]
    assert r.flags == int(run.flags[i])
    assert r.mate_chromosome == run.mate_chromosomes[i]
    assert r.mate_position == int(run.mate_positions[i])
    assert r.template_length == int(run.template_lengths[i])


@pytest.mark.parametrize("block_reads", [1, 25, 10 ** 6])
def test_random_access_and_iteration_match_source(tmp_path, block_reads):
    run = make_written_genomic_run(n_reads=100, read_len=30, with_reference=True, paired=True)
    p = _write(tmp_path, run, block_reads=block_reads)
    with SpectralDataset.open(p) as ds:
        g = ds.genomic_runs["run"]
        assert g.layout == "blocks_v1"
        assert len(g) == 100
        assert g.block_count == {1: 100, 25: 4, 10 ** 6: 1}[block_reads]
        for i in (0, 24, 25, 99, 50, -1):
            _check_read(g[i], run, i % 100)
        names = [r.read_name for r in g.iter_reads()]
        assert names == run.read_names
        assert [r.read_name for r in g.iter_reads(30, 35)] == run.read_names[30:35]
        assert [r.read_name for r in g] == run.read_names


def test_reads_in_region_touches_only_needed_blocks(tmp_path):
    run = make_written_genomic_run(n_reads=100, read_len=30, with_reference=True)
    p = _write(tmp_path, run, block_reads=10)
    with SpectralDataset.open(p) as ds:
        g = ds.genomic_runs["run"]
        # positions are i*10+1 -> reads 50..56 lie in [500, 570)
        hits = g.reads_in_region("chr1", 500, 570)
        assert [r.position for r in hits] == [int(x) for x in run.positions[50:57]]
        assert g._blocks_materialised <= 2


def test_partial_file_reads_up_to_last_flushed_block(tmp_path):
    run = make_written_genomic_run(n_reads=50, read_len=30, with_reference=True)
    p = str(tmp_path / "p.tio")
    SpectralDataset.write_minimal(p, title="t", isa_investigation_id="i", runs={})
    ds = SpectralDataset.open(p, writable=True)
    w = GenomicStreamWriter(ds.study_group, "run", acquisition_mode=run.acquisition_mode,
                            reference_uri=run.reference_uri, platform=run.platform,
                            sample_name=run.sample_name,
                            reference_chrom_seqs=run.reference_chrom_seqs,
                            embed_reference=True, block_reads=20, threads=1)
    w.append_batch(run)          # 2 full blocks written (serial writer), 10 reads pending
    w._write_close_tables()      # tables present, the pending reads are lost
    ds.close()
    with SpectralDataset.open(p) as ds2:
        g = ds2.genomic_runs["run"]
        assert len(g) == 40
        assert [r.read_name for r in g.iter_reads()] == run.read_names[:40]


def test_legacy_layout_still_reads(tmp_path):
    import dataclasses
    run = dataclasses.replace(
        make_written_genomic_run(n_reads=30, read_len=20, with_reference=True, paired=True),
        opt_legacy_whole_channel=True)
    p = str(tmp_path / "legacy.tio")
    SpectralDataset.write_minimal(p, title="t", isa_investigation_id="i", runs={},
                                  genomic_runs={"g": run})
    with SpectralDataset.open(p) as ds:
        g = ds.genomic_runs["g"]
        assert g.layout == "whole" and g.block_count == 1
        for i in (0, 29):
            _check_read(g[i], run, i)


def test_iter_reads_threaded_matches_serial(tmp_path):
    from ttio.codecs import ref_diff_v2 as rdv2
    if not rdv2.HAVE_NATIVE_LIB:
        pytest.skip("native lib")
    from test_genomic_stream_writer import _big_synthetic_run, _write_with_threads
    run = _big_synthetic_run(n=30_000)
    path = _write_with_threads(tmp_path, run, 1, block_reads=5_000)
    with SpectralDataset.open(path) as ds:
        g = ds.genomic_runs["g"]
        serial = [(r.read_name, r.sequence, r.cigar, r.mate_chromosome) for r in g.iter_reads(threads=1)]
        threaded = [(r.read_name, r.sequence, r.cigar, r.mate_chromosome) for r in g.iter_reads(threads=4)]
        assert threaded == serial
        part = [r.read_name for r in g.iter_reads(12_345, 17_890, threads=3)]
        assert part == [t[0] for t in serial[12_345:17_890]]
