# Streaming import/export + `blocks_v1` (Python reference implementation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Genomic runs are written and read as independently coded blocks (`blocks_v1`), spectral runs are written through extendable datasets, and every Python importer/exporter streams with bounded memory, so a whole genome or a whole mzML run can be imported and exported on a 32 GB machine.

**Architecture:** Two reuse tricks keep the codecs untouched. (1) The block *encoder* runs the existing whole-run writer `_write_genomic_run` against an in-memory provider group and harvests each channel's blob bytes + `@compression`, so a block's blob is byte-identical to what v1.8 would write for those reads alone. (2) The block *reader* materialises one block as a v1.8-shaped in-memory run group (blobs + attrs + index slice + run-level tables) and drives the existing `GenomicRun` decode path over it (`_BlockView`), so random access and codec dispatch are unchanged. Around those sit: an `extendable`/`append` capability in all four providers, `GenomicStreamWriter` / `SpectralStreamWriter`, `GenomicRun.iter_reads` / `AcquisitionRun.iter_spectra`, generator-shaped importers and streaming exporters, and CLI flags.

**Tech Stack:** Python 3.12 in `python/.venv`, numpy, h5py, zarr, sqlite3, pyteomics (mzML iteration), samtools pipes for SAM/BAM/CRAM in/out, existing native codecs (`libttio_rans`), pytest.

**Spec:** `docs/superpowers/specs/2026-08-16-streaming-blocks-v1-design.md`

## Global Constraints

- All commands run in WSL at `/home/toddw/TTI-O`; `PY=python/.venv/bin/python`. Test runs: `$PY -m pytest python/tests/<file> -q`. Full suite at the end: `$PY -m pytest python/tests -q --ignore=python/tests/conformance` then `python/tests/conformance`.
- Codec wire formats do not change. A block's blob MUST equal the v1.8 writer's output for a run consisting of that block's reads alone (spec §2.3); a test asserts it.
- Block index compound field order (spec §2.2): `read_start u64, n_reads u32, base_start u64, n_bases u64, sequences_off u64, sequences_len u64, qualities_off, qualities_len, read_names_off, read_names_len, cigars_off, cigars_len, mate_info_off, mate_info_len` (all u64 after n_reads).
- Defaults: `block_reads=1_000_000`, `block_bytes=256<<20`; `blocks_v1` is the default genomic layout; `opt_legacy_whole_channel=True` restores v1.8.
- Chromosome ids are assigned once, globally per run, in first-seen order across blocks; `mate_info/chrom_names` and `genomic_index/chromosome_names` are written at close from that map.
- The cross-language xlang genomic fixtures pin `opt_legacy_whole_channel=True` until the Java/ObjC readers (specs 2 and 3) land; the plan says where.
- Public text (spec/CHANGELOG/commit messages): plain statements, digits, no em dashes.
- Commit after every task with `git commit -F /home/toddw/msg.txt` (subject given per task; body: what changed and the test evidence).

---

### Task 1: Extendable datasets in all four providers

**Files:**
- Modify: `python/src/ttio/providers/base.py` (`create_dataset`, `create_compound_dataset`, `StorageDataset`)
- Modify: `python/src/ttio/providers/hdf5.py`, `providers/zarr.py`, `providers/memory.py`, `providers/sqlite.py`
- Test: `python/tests/test_providers_extendable.py`

**Interfaces:**
- Produces: `StorageGroup.create_dataset(name, precision, length, *, chunk_size=0, compression=NONE, compression_level=6, extendable: bool = False)`; `StorageGroup.create_compound_dataset(name, fields, count, *, extendable: bool = False, chunk_rows: int = 1024)`.
- Produces: `StorageDataset.extendable -> bool` (property) and `StorageDataset.append(data) -> None` (grows `length` by `len(data)`; `data` is an ndarray of the dataset dtype, or a structured ndarray / list[dict] for compound).
- `extendable=True` with `chunk_size == 0` raises `ValueError("extendable datasets require chunk_size > 0")`; `append` on a non-extendable dataset raises `TypeError`.

- [ ] **Step 1: Write the failing tests**

```python
# python/tests/test_providers_extendable.py
import numpy as np
import pytest

from ttio.enums import Precision
from ttio.providers.base import CompoundField
from ttio.providers.hdf5 import HDF5Provider
from ttio.providers.memory import MemoryProvider
from ttio.providers.sqlite import SqliteProvider
from ttio.providers.zarr import ZarrProvider


def _providers(tmp_path):
    yield "hdf5", HDF5Provider.create(str(tmp_path / "a.tio"))
    yield "zarr", ZarrProvider.create(str(tmp_path / "a.zarr"))
    yield "memory", MemoryProvider.create()
    yield "sqlite", SqliteProvider.create(str(tmp_path / "a.sqlite"))


@pytest.mark.parametrize("which", ["hdf5", "zarr", "memory", "sqlite"])
def test_append_primitive(tmp_path, which):
    prov = dict(_providers(tmp_path))[which]
    root = prov.root()
    ds = root.create_dataset("x", Precision.UINT8, 0, chunk_size=4, extendable=True)
    assert ds.extendable and ds.length == 0
    ds.append(np.arange(5, dtype=np.uint8))
    ds.append(np.arange(5, 9, dtype=np.uint8))
    assert ds.length == 9
    assert ds.read(3, 4).tolist() == [3, 4, 5, 6]
    assert ds.read().tolist() == list(range(9))


@pytest.mark.parametrize("which", ["hdf5", "zarr", "memory", "sqlite"])
def test_append_compound(tmp_path, which):
    prov = dict(_providers(tmp_path))[which]
    root = prov.root()
    fields = [CompoundField("a", Precision.UINT64), CompoundField("b", Precision.UINT32)]
    ds = root.create_compound_dataset("idx", fields, 0, extendable=True, chunk_rows=2)
    ds.append([{"a": 1, "b": 2}, {"a": 3, "b": 4}])
    ds.append([{"a": 5, "b": 6}])
    rows = ds.read_rows()
    assert [(int(r["a"]), int(r["b"])) for r in rows] == [(1, 2), (3, 4), (5, 6)]


def test_non_extendable_rejects_append(tmp_path):
    root = MemoryProvider.create().root()
    ds = root.create_dataset("x", Precision.UINT8, 3, chunk_size=4)
    with pytest.raises(TypeError):
        ds.append(np.zeros(1, dtype=np.uint8))
    with pytest.raises(ValueError, match="chunk_size"):
        root.create_dataset("y", Precision.UINT8, 0, extendable=True)


def test_hdf5_extendable_survives_reopen(tmp_path):
    p = str(tmp_path / "r.tio")
    prov = HDF5Provider.create(p)
    ds = prov.root().create_dataset("x", Precision.FLOAT64, 0, chunk_size=1024, extendable=True)
    ds.append(np.arange(3000, dtype="<f8"))
    prov.close()
    prov = HDF5Provider.open(p)
    ds = prov.root().open_dataset("x")
    assert ds.length == 3000 and float(ds.read(2999, 1)[0]) == 2999.0
```

- [ ] **Step 2: Run to verify failure**

Run: `$PY -m pytest python/tests/test_providers_extendable.py -q`
Expected: FAIL (`unexpected keyword argument 'extendable'`). If the constructor names (`HDF5Provider.create/open`, `root()`) differ, read `python/src/ttio/providers/__init__.py` and use the real ones in the test.

- [ ] **Step 3: Implement in base.py**

Add `extendable: bool = False` to `create_dataset` and `create_dataset_nd`; add `extendable: bool = False, chunk_rows: int = 1024` to `create_compound_dataset`; on `StorageDataset` add:

```python
    @property
    def extendable(self) -> bool:
        return False

    def append(self, data: Any) -> None:
        raise TypeError(f"dataset '{self.name}' is not extendable")
```

- [ ] **Step 4: Implement hdf5.py**

In `create_dataset`: when `extendable`, require `chunk_size > 0`, set `kwargs["maxshape"] = (None,)`, `kwargs["chunks"] = (chunk_size,)` even when `length == 0` (h5py accepts chunked zero-length when maxshape is unlimited). In `_Dataset`: `extendable` returns `self._ds.maxshape == (None,)`; `append`:

```python
    def append(self, data):
        if not self.extendable:
            raise TypeError(f"dataset '{self.name}' is not extendable")
        arr = self._coerce(data)          # existing write() coercion for compound/list-of-dict
        n = self._ds.shape[0]
        self._ds.resize((n + len(arr),))
        self._ds[n:n + len(arr)] = arr
```

Factor the coercion used by `write()` (structured dtype build for list[dict]) into `_coerce`. In `create_compound_dataset`: `maxshape=(None,)`, `chunks=(chunk_rows,)` when `extendable`.

- [ ] **Step 5: Implement zarr.py, memory.py, sqlite.py**

zarr: `extendable` stored on the adapter; `append` calls `self._arr.append(arr)`; creation with `chunks=(chunk_size,)`, `shape=(length,)`. memory: `_Dataset` keeps `self._parts: list[np.ndarray]`; `append` extends; `read`/`length` concatenate lazily (cache the concatenation until next append). sqlite: add table `dataset_chunks(dataset_id, seq, data BLOB, n INTEGER)`; `append` inserts a row; `read(offset, count)` walks rows for extendable datasets; `length` = sum of `n`. Compound extendable in memory/sqlite: rows kept as list[dict] parts.

- [ ] **Step 6: Run tests**

Run: `$PY -m pytest python/tests/test_providers_extendable.py python/tests/test_providers*.py -q`
Expected: new tests pass, existing provider tests unchanged.

- [ ] **Step 7: Commit** — subject `feat(providers): extendable datasets with append on hdf5, zarr, memory, sqlite`

---

### Task 2: Block encoder over the existing whole-run writer

**Files:**
- Create: `python/src/ttio/genomic/_blocks.py`
- Modify: `python/src/ttio/_dataset_write_genomic.py` (`_write_mate_info_inline_v2`, `_write_genomic_run` signature)
- Modify: `python/src/ttio/genomic_index.py` (`GenomicIndex.write` accepts a preassigned id map)
- Modify: `python/src/ttio/written_genomic_run.py` (new optional field)
- Test: `python/tests/test_genomic_blocks_encoder.py`

**Interfaces:**
- Produces: `WrittenGenomicRun.chrom_name_to_id: dict[str, int] | None = None` (when given, mate_info and genomic_index use these ids and extend the map in place for names not yet present).
- Produces: `_blocks.BLOCK_CHANNELS = ("sequences", "qualities", "read_names", "cigars", "mate_info")`.
- Produces: `_blocks.encode_block(block: WrittenGenomicRun, *, references_provider=None) -> BlockBlobs` with `BlockBlobs(blobs: dict[str, bytes], compression: dict[str, int], seq_layout: str, extra_attrs: dict[str, dict])` where `seq_layout` is `"refdiff_v2"` or `"raw"` (dataset name under `signal_channels/sequences/` vs flat), `blobs[ch]` is `b""` for a channel the block does not carry, and `extra_attrs[ch]` holds every attribute the v1.8 writer set on that channel dataset (besides `compression`).
- Produces: `_blocks.slice_run(run: WrittenGenomicRun, start: int, stop: int) -> WrittenGenomicRun` (per-read arrays sliced, `sequences/qualities` sliced by `offsets`, `offsets` rebased to 0).

- [ ] **Step 1: Write the failing tests**

```python
# python/tests/test_genomic_blocks_encoder.py
import numpy as np
import pytest

from ttio.genomic import _blocks
from ttio.providers.memory import MemoryProvider
from ttio._dataset_write_genomic import _write_genomic_run
from tests.helpers.genomic_fixture import make_written_genomic_run  # existing helper; see Step 2


def test_slice_run_rebases_offsets():
    run = make_written_genomic_run(n_reads=10, read_len=7)
    s = _blocks.slice_run(run, 3, 6)
    assert len(s.lengths) == 3 and int(s.offsets[0]) == 0
    assert bytes(s.sequences) == bytes(run.sequences[21:42])
    assert s.read_names == run.read_names[3:6]


def test_encode_block_equals_whole_run_writer_bytes():
    run = make_written_genomic_run(n_reads=40, read_len=50, with_reference=True)
    blobs = _blocks.encode_block(run)
    prov = MemoryProvider.create(); root = prov.root()
    _write_genomic_run(root, "r", run)
    sc = root.open_group("r").open_group("signal_channels")
    for ch in _blocks.BLOCK_CHANNELS:
        if ch == "sequences":
            ds = sc.open_group("sequences").open_dataset(blobs.seq_layout) if sc.has_child("sequences") \
                and not sc.open_group("sequences").has_child("chrom_names") else None
        elif ch == "mate_info":
            ds = sc.open_group("mate_info").open_dataset("inline_v2")
        else:
            ds = sc.open_dataset(ch)
        assert bytes(ds.read().tobytes()) == blobs.blobs[ch], ch
        assert int(ds.get_attribute("compression")) == blobs.compression[ch], ch


def test_encode_block_uses_preassigned_chrom_ids():
    run = make_written_genomic_run(n_reads=8, read_len=10, chromosomes=["chrB"] * 4 + ["chrA"] * 4)
    run.chrom_name_to_id = {"chrA": 0}
    _blocks.encode_block(run)
    assert run.chrom_name_to_id == {"chrA": 0, "chrB": 1}
```

- [ ] **Step 2: Create the fixture helper if absent**

Look for an existing builder: `grep -rn "def make_written_genomic_run\|WrittenGenomicRun(" python/tests | head`. If none is importable, create `python/tests/helpers/genomic_fixture.py` with `make_written_genomic_run(n_reads, read_len, *, with_reference=False, chromosomes=None)` that builds deterministic ACGT sequences (`random.Random(7)`), qualities 30..40, names `r{i}`, cigars `f"{read_len}M"`, positions `i*10`, mapq 60, flags 0/16 alternating, mate fields unpaired (`"*"`, -1, 0), and when `with_reference` a `reference_chrom_seqs={"chr1": <200 kb random>}` with reads copied from it so refdiff_v2 engages, `embed_reference=True`. Reuse whatever the existing genomic tests already do (`python/tests/test_m93*.py`, `test_ref_diff_v2*.py` build such runs; lift theirs).

- [ ] **Step 3: Run to verify failure**

Run: `$PY -m pytest python/tests/test_genomic_blocks_encoder.py -q`
Expected: FAIL (`No module named 'ttio.genomic._blocks'`).

- [ ] **Step 4: Plumb `chrom_name_to_id`**

`written_genomic_run.py`: add `chrom_name_to_id: dict[str, int] | None = None` (documented: "preassigned chromosome id map shared across blocks; extended in place"). In `_dataset_write_genomic._write_mate_info_inline_v2` replace `own_chrom_ids, name_to_id = _build_chrom_id_table(run.chromosomes)` by

```python
    if run.chrom_name_to_id is not None:
        name_to_id = run.chrom_name_to_id
        own_chrom_ids = np.empty(len(run.chromosomes), dtype=np.uint16)
        for i, nm in enumerate(run.chromosomes):
            if nm == "*" or not nm:
                own_chrom_ids[i] = 0xFFFF; continue
            if nm not in name_to_id:
                name_to_id[nm] = len(name_to_id)
            own_chrom_ids[i] = name_to_id[nm]
    else:
        own_chrom_ids, name_to_id = _build_chrom_id_table(run.chromosomes)
```

and make `_resolve_mate_chrom_ids` extend that same map in place (it currently copies; add a keyword `extend_in_place: bool` and pass `True` here). In `GenomicIndex.write(idx_group, name_to_id=None)`: when given, use/extend it instead of the local map. `_write_genomic_run` passes `run.chrom_name_to_id` to `GenomicIndex.write`.

- [ ] **Step 5: Implement `_blocks.py`**

```python
# python/src/ttio/genomic/_blocks.py
"""Block encoder for the blocks_v1 layout: run the whole-run writer on a
block's reads against an in-memory group and harvest the blobs."""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from ..written_genomic_run import WrittenGenomicRun

BLOCK_CHANNELS = ("sequences", "qualities", "read_names", "cigars", "mate_info")


@dataclass
class BlockBlobs:
    blobs: dict[str, bytes]
    compression: dict[str, int]
    seq_layout: str                       # "refdiff_v2" | "raw"
    extra_attrs: dict[str, dict] = field(default_factory=dict)
    n_reads: int = 0
    n_bases: int = 0


def slice_run(run: WrittenGenomicRun, start: int, stop: int) -> WrittenGenomicRun:
    import dataclasses
    b0 = int(run.offsets[start]); b1 = int(run.offsets[stop - 1] + run.lengths[stop - 1]) if stop > start else b0
    return dataclasses.replace(
        run,
        positions=run.positions[start:stop], mapping_qualities=run.mapping_qualities[start:stop],
        flags=run.flags[start:stop], sequences=run.sequences[b0:b1], qualities=run.qualities[b0:b1],
        offsets=(run.offsets[start:stop] - b0).astype(np.uint64), lengths=run.lengths[start:stop],
        cigars=run.cigars[start:stop], read_names=run.read_names[start:stop],
        mate_chromosomes=run.mate_chromosomes[start:stop], mate_positions=run.mate_positions[start:stop],
        template_lengths=run.template_lengths[start:stop], chromosomes=run.chromosomes[start:stop],
        provenance_records=[],
    )


def _harvest(ds) -> tuple[bytes, int, dict]:
    attrs = {k: ds.get_attribute(k) for k in ds.attribute_names() if k != "compression"}
    comp = int(ds.get_attribute("compression")) if ds.has_attribute("compression") else 0
    return bytes(np.asarray(ds.read(), dtype=np.uint8).tobytes()), comp, attrs


def encode_block(block: WrittenGenomicRun, *, references_provider=None) -> BlockBlobs:
    from .._dataset_write_genomic import _write_genomic_run
    from ..providers.memory import MemoryProvider
    root = MemoryProvider.create().root()
    _write_genomic_run(root, "b", block)
    sc = root.open_group("b").open_group("signal_channels")
    out = BlockBlobs(blobs={}, compression={}, seq_layout="raw",
                     n_reads=int(len(block.lengths)), n_bases=int(block.lengths.sum()))
    for ch in BLOCK_CHANNELS:
        if ch == "sequences" and sc.has_child("sequences") and sc.open_group("sequences").has_child("refdiff_v2") \
                if _is_group(sc, "sequences") else False:
            ds = sc.open_group("sequences").open_dataset("refdiff_v2"); out.seq_layout = "refdiff_v2"
        elif ch == "mate_info":
            ds = sc.open_group("mate_info").open_dataset("inline_v2") if sc.has_child("mate_info") else None
        else:
            ds = sc.open_dataset(ch) if sc.has_child(ch) and not _is_group(sc, ch) else None
        if ds is None:
            out.blobs[ch] = b""; out.compression[ch] = 0; out.extra_attrs[ch] = {}; continue
        out.blobs[ch], out.compression[ch], out.extra_attrs[ch] = _harvest(ds)
    return out


def _is_group(parent, name: str) -> bool:
    try:
        parent.open_group(name); return True
    except Exception:
        return False
```

Adjust `_is_group` to whatever the provider protocol offers (`child_kind(name)` if present). `attribute_names()`/`has_attribute` names come from `StorageDataset` (line ~238-295 of `providers/hdf5.py`); use the protocol names.

- [ ] **Step 6: Run tests**

Run: `$PY -m pytest python/tests/test_genomic_blocks_encoder.py python/tests/test_m93*.py python/tests/test_ref_diff_v2*.py -q`
Expected: pass; the existing writer tests confirm the chrom-id plumbing did not change v1.8 output.

- [ ] **Step 7: Commit** — subject `feat(genomic): block encoder over the whole-run writer, shared chromosome id map`

---

### Task 3: `GenomicStreamWriter` and the `blocks_v1` layout

**Files:**
- Create: `python/src/ttio/genomic/stream_writer.py`
- Modify: `python/src/ttio/spectral_dataset.py` (`write_minimal` genomic path → stream writer), `python/src/ttio/genomic/__init__.py` (export)
- Modify: `docs/format-spec.md` (new §10.12 `blocks_v1`, from spec §2)
- Test: `python/tests/test_genomic_stream_writer.py`

**Interfaces:**
- Produces: `ttio.genomic.GenomicStreamWriter(dataset_or_root_group, run_name, *, acquisition_mode, reference_uri, platform, sample_name, reference_chrom_seqs=None, embed_reference=False, block_reads=1_000_000, block_bytes=256<<20, opt_disable_qualities_v5=False, signal_codec_overrides=None, opt_legacy_whole_channel=False)` with `append_batch(batch: WrittenGenomicRun)`, `append(read: AlignedRead)`, `flush()`, `close()`, context manager, `read_count` property. The first argument is the `/study` `StorageGroup` (a `SpectralDataset` opened for write exposes it as `dataset.study_group`; add that property if missing).
- Produces on disk: spec §2 exactly. Datasets: `blocks/index` compound (Task 1 extendable), `signal_channels/<ch>` uint8 extendable chunk 4 MiB (`sequences/refdiff_v2` group form or flat `sequences`, decided by the first non-empty block and enforced for the rest), `genomic_index/{lengths,positions,mapping_qualities,flags,chromosome_ids}` extendable (chunk 1<<20) with the same element types/`@compression` as `GenomicIndex.write` uses (zlib per its `_write_*_channel` helpers → these become extendable variants: add `extendable=True` passthrough to `io._write_uint32_channel` etc. or create them directly here with `Precision` + `Compression.ZLIB`, chunk 1<<20).
- At close: `@read_count`, `@base_count`, `@layout="blocks_v1"`, `@block_policy`, `genomic_index/chromosome_names` compound and `signal_channels/mate_info/chrom_names` from the shared map, run-level attrs as `_write_genomic_run` writes them (`acquisition_mode`, `modality`, `spectrum_class=5`, `reference_uri`, `platform`, `sample_name`), reference embedding via the existing `_embed_references_for_runs` when `embed_reference`.
- `SpectralDataset.write_minimal(..., genomic_runs=...)` calls the stream writer per run with `block_reads/bytes` defaults, so small runs become one-block `blocks_v1` files; `WrittenGenomicRun.opt_legacy_whole_channel: bool = False` (new field) selects `_write_genomic_run` instead.

- [ ] **Step 1: Write the failing tests**

```python
# python/tests/test_genomic_stream_writer.py
import numpy as np
import pytest

from ttio.spectral_dataset import SpectralDataset
from ttio.genomic import GenomicStreamWriter, _blocks
from tests.helpers.genomic_fixture import make_written_genomic_run


def _open_run_group(path, name):
    from ttio.providers.hdf5 import HDF5Provider
    prov = HDF5Provider.open(path)
    return prov, prov.root().open_group("study").open_group("genomic_runs").open_group(name)


def test_multi_block_layout(tmp_path):
    run = make_written_genomic_run(n_reads=100, read_len=20, with_reference=True)
    p = str(tmp_path / "s.tio")
    SpectralDataset.write_minimal(p, title="t", isa_investigation_id="i", runs={})
    with SpectralDataset.open(p, mode="a") as ds:
        with GenomicStreamWriter(ds.study_group, "run", acquisition_mode=run.acquisition_mode,
                                 reference_uri=run.reference_uri, platform=run.platform,
                                 sample_name=run.sample_name, reference_chrom_seqs=run.reference_chrom_seqs,
                                 embed_reference=True, block_reads=30) as w:
            for s in range(0, 100, 10):
                w.append_batch(_blocks.slice_run(run, s, s + 10))
        assert w.read_count == 100
    prov, rg = _open_run_group(p, "run")
    assert rg.get_attribute("layout") == "blocks_v1"
    rows = rg.open_group("blocks").open_dataset("index").read_rows()
    assert [int(r["n_reads"]) for r in rows] == [30, 30, 30, 10]
    assert [int(r["read_start"]) for r in rows] == [0, 30, 60, 90]
    q = rg.open_group("signal_channels").open_dataset("qualities")
    assert int(rows[-1]["qualities_off"] + rows[-1]["qualities_len"]) == q.length
    assert int(rg.get_attribute("read_count")) == 100
    prov.close()


def test_block_blob_equals_whole_run_writer_for_that_block(tmp_path):
    run = make_written_genomic_run(n_reads=60, read_len=20, with_reference=True)
    p = str(tmp_path / "s.tio")
    SpectralDataset.write_minimal(p, title="t", isa_investigation_id="i", runs={})
    with SpectralDataset.open(p, mode="a") as ds:
        with GenomicStreamWriter(ds.study_group, "run", acquisition_mode=run.acquisition_mode,
                                 reference_uri=run.reference_uri, platform=run.platform,
                                 sample_name=run.sample_name, reference_chrom_seqs=run.reference_chrom_seqs,
                                 embed_reference=True, block_reads=25) as w:
            w.append_batch(run)
    prov, rg = _open_run_group(p, "run")
    rows = rg.open_group("blocks").open_dataset("index").read_rows()
    blk1 = _blocks.slice_run(run, 25, 50)
    blk1.chrom_name_to_id = {"chr1": 0}
    expected = _blocks.encode_block(blk1)
    q = rg.open_group("signal_channels").open_dataset("qualities")
    off, ln = int(rows[1]["qualities_off"]), int(rows[1]["qualities_len"])
    assert q.read(off, ln).tobytes() == expected.blobs["qualities"]
    prov.close()


def test_write_minimal_default_is_blocks_v1_and_legacy_opt_out(tmp_path):
    run = make_written_genomic_run(n_reads=10, read_len=20)
    p = str(tmp_path / "d.tio")
    SpectralDataset.write_minimal(p, title="t", isa_investigation_id="i", runs={}, genomic_runs={"g": run})
    prov, rg = _open_run_group(p, "g")
    assert rg.get_attribute("layout") == "blocks_v1"; prov.close()
    run.opt_legacy_whole_channel = True
    p2 = str(tmp_path / "l.tio")
    SpectralDataset.write_minimal(p2, title="t", isa_investigation_id="i", runs={}, genomic_runs={"g": run})
    prov, rg = _open_run_group(p2, "g")
    assert not rg.has_attribute("layout"); prov.close()
```

- [ ] **Step 2: Run to verify failure**

Run: `$PY -m pytest python/tests/test_genomic_stream_writer.py -q`
Expected: FAIL (`cannot import name 'GenomicStreamWriter'`).

- [ ] **Step 3: Implement `genomic/stream_writer.py`**

```python
# python/src/ttio/genomic/stream_writer.py
"""GenomicStreamWriter: blocks_v1 writer with bounded memory."""
from __future__ import annotations

import numpy as np

from ..enums import Compression, Precision
from ..providers.base import CompoundField
from ..written_genomic_run import WrittenGenomicRun
from . import _blocks

INDEX_FIELDS = [CompoundField("read_start", Precision.UINT64), CompoundField("n_reads", Precision.UINT32),
                CompoundField("base_start", Precision.UINT64), CompoundField("n_bases", Precision.UINT64)] + [
    CompoundField(f"{ch}_{k}", Precision.UINT64) for ch in _blocks.BLOCK_CHANNELS for k in ("off", "len")]
CHANNEL_CHUNK = 4 << 20
INDEX_CHUNK = 1 << 20


class GenomicStreamWriter:
    def __init__(self, study_group, run_name, *, acquisition_mode, reference_uri, platform, sample_name,
                 reference_chrom_seqs=None, embed_reference=False, block_reads=1_000_000,
                 block_bytes=256 << 20, opt_disable_qualities_v5=False, signal_codec_overrides=None,
                 opt_legacy_whole_channel=False):
        self._study = study_group; self._name = run_name
        self._meta = dict(acquisition_mode=acquisition_mode, reference_uri=reference_uri, platform=platform,
                          sample_name=sample_name, reference_chrom_seqs=reference_chrom_seqs,
                          embed_reference=embed_reference, opt_disable_qualities_v5=opt_disable_qualities_v5,
                          signal_codec_overrides=dict(signal_codec_overrides or {}))
        self._block_reads, self._block_bytes = int(block_reads), int(block_bytes)
        self._legacy = bool(opt_legacy_whole_channel)
        self._pending: list[WrittenGenomicRun] = []; self._pending_reads = 0; self._pending_bytes = 0
        self._chrom_map: dict[str, int] = {}
        self._read_count = 0; self._base_count = 0
        self._rg = None; self._ds = {}; self._index = None; self._seq_layout = None
        self._legacy_parts: list[WrittenGenomicRun] = []

    # -- public --------------------------------------------------------
    @property
    def read_count(self): return self._read_count

    def append(self, read) -> None:
        from ..aligned_read import AlignedRead  # noqa
        self.append_batch(_single_read_run(read, self._meta))

    def append_batch(self, batch: WrittenGenomicRun) -> None:
        if self._legacy:
            self._legacy_parts.append(batch); return
        # split the batch so no block exceeds either cap
        start = 0; n = len(batch.lengths)
        while start < n:
            room_reads = self._block_reads - self._pending_reads
            stop = min(n, start + max(room_reads, 1))
            # byte cap: advance stop while cumulative bases stay under block_bytes
            bases = np.cumsum(batch.lengths[start:stop])
            fit = int(np.searchsorted(bases, self._block_bytes - self._pending_bytes, side="right"))
            stop = start + max(fit, 1) if fit < stop - start else stop
            part = _blocks.slice_run(batch, start, stop) if (start, stop) != (0, n) else batch
            self._pending.append(part); self._pending_reads += stop - start
            self._pending_bytes += int(part.lengths.sum())
            if self._pending_reads >= self._block_reads or self._pending_bytes >= self._block_bytes:
                self.flush()
            start = stop

    def flush(self) -> None:
        if not self._pending: return
        block = _concat_runs(self._pending); self._pending = []; self._pending_reads = 0; self._pending_bytes = 0
        block.chrom_name_to_id = self._chrom_map
        for k, v in self._meta.items():
            if hasattr(block, k) and k not in ("acquisition_mode",): setattr(block, k, v)
        blobs = _blocks.encode_block(block)
        self._ensure_layout(blobs)
        row = {"read_start": self._read_count, "n_reads": blobs.n_reads,
               "base_start": self._base_count, "n_bases": blobs.n_bases}
        for ch in _blocks.BLOCK_CHANNELS:
            ds = self._ds[ch]; row[f"{ch}_off"] = ds.length; row[f"{ch}_len"] = len(blobs.blobs[ch])
            if blobs.blobs[ch]:
                ds.append(np.frombuffer(blobs.blobs[ch], dtype=np.uint8))
        self._index.append([row])
        self._append_index_arrays(block)
        self._read_count += blobs.n_reads; self._base_count += blobs.n_bases
        self._rg.set_attribute("read_count", self._read_count)   # int attr helper as _write_genomic_run uses
        self._rg.set_attribute("base_count", self._base_count)

    def close(self) -> None:
        if self._legacy:
            from .._dataset_write_genomic import _write_genomic_run
            whole = _concat_runs(self._legacy_parts) if self._legacy_parts else None
            if whole is not None:
                _apply_meta(whole, self._meta); _write_genomic_run(self._study.open_group("genomic_runs"), self._name, whole)
                self._read_count = len(whole.lengths)
            return
        self.flush()
        if self._rg is None:
            self._ensure_layout(None)          # empty run: still valid blocks_v1
        self._write_close_tables()

    def __enter__(self): return self
    def __exit__(self, *a): self.close()
```

Then the private parts: `_ensure_layout(blobs)` creates `genomic_runs/<name>` (if absent), sets run-level attrs via `_hdf5_io.write_int_attr/write_fixed_string_attr` exactly as `_write_genomic_run` lines 77-84 do, `@layout`, `@block_policy=f"reads={block_reads},bytes={block_bytes}"`, creates `blocks/index` (extendable compound, `chunk_rows=1024`), `genomic_index/*` extendable datasets (`lengths` UINT32, `positions` INT64, `mapping_qualities` UINT8, `flags` UINT32, `chromosome_ids` UINT16; ZLIB, chunk `INDEX_CHUNK`, and the same `@compression` attributes the `io._write_*_channel` helpers set), and the channel datasets: on the first non-empty block decide `seq_layout` (`sequences/refdiff_v2` group+dataset when `blobs.seq_layout == "refdiff_v2"`, else flat `sequences`), `qualities`, `read_names`, `cigars`, `mate_info/inline_v2` (group), each `UINT8`, `chunk_size=CHANNEL_CHUNK`, `extendable=True`, `@compression = blobs.compression[ch]` plus `extra_attrs`. `_append_index_arrays(block)` appends `lengths/positions/mapping_qualities/flags` and `chromosome_ids` computed from `self._chrom_map` (extend for own chromosomes, `0xFFFF` for `*`). `_write_close_tables()` writes `genomic_index/chromosome_names` and `signal_channels/mate_info/chrom_names` (compound `(name VL_STRING)` rows in id order) reusing the row shape `GenomicIndex.write` and `_write_mate_info_inline_v2` produce, and embeds references via `_embed_references_for_runs` when `embed_reference`. `_concat_runs(parts)` concatenates the parallel arrays and rebases offsets; `_apply_meta` sets the metadata fields on a `WrittenGenomicRun`; `_single_read_run(read, meta)` builds a 1-read `WrittenGenomicRun` from an `AlignedRead` (fields: `read.sequence`, `read.qualities`, `read.name`, `read.cigar`, `read.chromosome`, `read.position`, `read.mapping_quality`, `read.flags`, `read.mate_chromosome`, `read.mate_position`, `read.template_length`; check names in `aligned_read.py`).

- [ ] **Step 4: Reroute `write_minimal`**

In `spectral_dataset.py` where `_write_genomic_run(g_group, name, run)` is called for each genomic run: replace with

```python
            if getattr(run, "opt_legacy_whole_channel", False):
                _write_genomic_run(g_group, name, run)
            else:
                from .genomic.stream_writer import GenomicStreamWriter
                with GenomicStreamWriter(study, name, acquisition_mode=run.acquisition_mode,
                                         reference_uri=run.reference_uri, platform=run.platform,
                                         sample_name=run.sample_name,
                                         reference_chrom_seqs=getattr(run, "reference_chrom_seqs", None),
                                         embed_reference=run.embed_reference,
                                         opt_disable_qualities_v5=run.opt_disable_qualities_v5,
                                         signal_codec_overrides=run.signal_codec_overrides) as w:
                    w.append_batch(run)
```

Add `opt_legacy_whole_channel: bool = False` to `WrittenGenomicRun`; add `SpectralDataset.study_group` property returning the `/study` StorageGroup of an open-for-write dataset (check how `open(mode="a")` exposes the provider root; add the mode if only `"r"` exists, or accept a provider root group directly in the writer and adjust the tests to pass it).

- [ ] **Step 5: Run tests**

Run: `$PY -m pytest python/tests/test_genomic_stream_writer.py -q`
Expected: 3 passed. (Reads of `blocks_v1` files are not possible yet; the tests only inspect datasets.)

- [ ] **Step 6: Document the layout**

Add `docs/format-spec.md` §10.12 "`blocks_v1` genomic block layout" with the tables from spec §2.1-2.5 (attribute, index fields, channel datasets, index datasets, close semantics), and update §10.6/§10.8/§10.9b/§10.10b/§10.11 with one sentence each: "Under `blocks_v1` this dataset holds one such blob per block, back to back, addressed through `blocks/index` (§10.12)".

- [ ] **Step 7: Commit** — subject `feat(genomic): GenomicStreamWriter and the blocks_v1 layout; write_minimal streams by default`

---

### Task 4: Reading `blocks_v1` in `GenomicRun`

**Files:**
- Create: `python/src/ttio/genomic/_block_view.py`
- Modify: `python/src/ttio/genomic_run.py` (`open`, `__getitem__`, `__iter__`, `reads_in_region`, `__len__`, new `iter_reads`)
- Test: `python/tests/test_genomic_blocks_reader.py`

**Interfaces:**
- Produces: `_block_view.materialise_block(run_group, block_row, chrom_names_table, mate_chrom_table, seq_layout) -> StorageGroup` — an in-memory v1.8-shaped run group for one block: run attrs copied, `genomic_index/*` = slices `[read_start, read_start+n_reads)` of the extendable index datasets plus a `chromosome_names` copy, `signal_channels/<ch>` = the block's blob bytes with `@compression` and the extra attrs copied from the extendable dataset, `mate_info/chrom_names` copied.
- Produces: `GenomicRun.iter_reads(start=0, stop=None) -> Iterator[AlignedRead]`; `GenomicRun.block_count`; `GenomicRun.__getitem__` for `blocks_v1` = locate block by `bisect` on `read_start`, materialise (cache last one), delegate to a `GenomicRun.open(memgroup, ...)` instance's `__getitem__(i - read_start)`.
- `GenomicRun.open` reads `@layout`; for `blocks_v1` it builds `self._blocks` (index rows as ndarray columns) and keeps `_index` from the extendable index datasets (already the same names) so `reads_in_region`, `indices_for_flag` etc. work unchanged.

- [ ] **Step 1: Write the failing tests**

```python
# python/tests/test_genomic_blocks_reader.py
import numpy as np
import pytest

from ttio.spectral_dataset import SpectralDataset
from tests.helpers.genomic_fixture import make_written_genomic_run


def _write(tmp_path, run, **kw):
    p = str(tmp_path / "b.tio")
    from ttio.genomic import GenomicStreamWriter
    SpectralDataset.write_minimal(p, title="t", isa_investigation_id="i", runs={})
    with SpectralDataset.open(p, mode="a") as ds:
        with GenomicStreamWriter(ds.study_group, "run", acquisition_mode=run.acquisition_mode,
                                 reference_uri=run.reference_uri, platform=run.platform,
                                 sample_name=run.sample_name, reference_chrom_seqs=run.reference_chrom_seqs,
                                 embed_reference=True, **kw) as w:
            w.append_batch(run)
    return p


@pytest.mark.parametrize("block_reads", [1, 25, 10**6])
def test_random_access_and_iteration_match_source(tmp_path, block_reads):
    run = make_written_genomic_run(n_reads=100, read_len=30, with_reference=True, paired=True)
    p = _write(tmp_path, run, block_reads=block_reads)
    with SpectralDataset.open(p) as ds:
        g = ds.genomic_runs["run"]
        assert len(g) == 100
        for i in (0, 24, 25, 99, 50):
            r = g[i]
            assert r.name == run.read_names[i]
            o, l = int(run.offsets[i]), int(run.lengths[i])
            assert r.sequence == run.sequences[o:o + l].tobytes().decode()
            assert list(r.qualities) == run.qualities[o:o + l].tolist()
            assert r.cigar == run.cigars[i] and r.position == int(run.positions[i])
            assert r.mate_chromosome == run.mate_chromosomes[i]
        names = [r.name for r in g.iter_reads()]
        assert names == run.read_names
        assert [r.name for r in g.iter_reads(30, 35)] == run.read_names[30:35]


def test_reads_in_region_touches_only_needed_blocks(tmp_path):
    run = make_written_genomic_run(n_reads=100, read_len=30, with_reference=True)
    p = _write(tmp_path, run, block_reads=10)
    with SpectralDataset.open(p) as ds:
        g = ds.genomic_runs["run"]
        hits = g.reads_in_region("chr1", 500, 560)      # positions are i*10 -> reads 50..56
        assert [r.position for r in hits] == [int(x) for x in run.positions[50:57]]
        assert g._blocks_materialised <= 2


def test_partial_file_reads_up_to_last_flushed_block(tmp_path):
    run = make_written_genomic_run(n_reads=50, read_len=30, with_reference=True)
    p = str(tmp_path / "p.tio")
    from ttio.genomic import GenomicStreamWriter
    SpectralDataset.write_minimal(p, title="t", isa_investigation_id="i", runs={})
    ds = SpectralDataset.open(p, mode="a")
    w = GenomicStreamWriter(ds.study_group, "run", acquisition_mode=run.acquisition_mode,
                            reference_uri=run.reference_uri, platform=run.platform, sample_name=run.sample_name,
                            reference_chrom_seqs=run.reference_chrom_seqs, embed_reference=True, block_reads=20)
    w.append_batch(run)          # 2 full blocks flushed, 10 reads pending
    w._write_close_tables()      # simulate: tables present, pending block lost
    ds.close()
    with SpectralDataset.open(p) as ds2:
        assert len(ds2.genomic_runs["run"]) == 40
```

- [ ] **Step 2: Run to verify failure**

Run: `$PY -m pytest python/tests/test_genomic_blocks_reader.py -q`
Expected: FAIL (reader raises on the unknown layout / missing whole-channel datasets).

- [ ] **Step 3: Implement `_block_view.py` and the `GenomicRun` changes**

`materialise_block`: create `MemoryProvider.create().root()`, `create_group("run")`; copy every run attribute; `genomic_index`: for each of `lengths, positions, mapping_qualities, flags, chromosome_ids` create a dataset of the slice (`ds.read(read_start, n_reads)`) with the same precision and copy `@compression`; write `chromosome_names` rows (the whole table; ids are global); `signal_channels`: for each `BLOCK_CHANNELS` entry with `_len > 0`, create the dataset (`sequences/refdiff_v2` under a group when `seq_layout == "refdiff_v2"`, `mate_info/inline_v2` under a group + `chrom_names` copy) from `ds.read(off, len)` and copy attributes. Return the group.

In `GenomicRun`: add fields `_layout: str`, `_block_rows` (dict of column ndarrays), `_block_cache: tuple[int, GenomicRun] | None`, `_blocks_materialised: int = 0`. In `open`: `layout = attr("layout") or "whole"`; when `blocks_v1`, `read_count` from `@read_count` and the index datasets are read as today (`GenomicIndex.read` already reads these names; `offsets` derived from `cumsum(lengths)`). `_block_for(i)`: `b = bisect_right(read_start, i) - 1`; if cached b return it; else `sub = GenomicRun.open(materialise_block(...), "run", references_group=self._references_group)`; cache; `_blocks_materialised += 1`. `__getitem__`: `if self._layout == "blocks_v1": b, sub = self._block_for(i); return sub[i - read_start[b]]` (then patch the returned `AlignedRead.index` if it carries the in-run index). `iter_reads(start, stop)`: walk blocks in order, materialise each once, yield `sub[j]`. `__iter__` = `iter_reads()`. `reads_in_region` keeps using `self._index.indices_for_region` and maps through `__getitem__` (block cache makes consecutive hits cheap).

- [ ] **Step 4: Run tests**

Run: `$PY -m pytest python/tests/test_genomic_blocks_reader.py python/tests/test_genomic_stream_writer.py -q`
Expected: pass. Add `paired=True` to the fixture helper (mate fields set) if not present.

- [ ] **Step 5: Commit** — subject `feat(genomic): read blocks_v1 through per-block views; iter_reads`

---

### Task 5: Suite fallout: signatures, transport bulk mode, xlang fixtures pinned to legacy, direct-dataset tests

**Files:**
- Modify: `python/src/ttio/signatures.py` (`sign_genomic_run` / `verify_genomic_run` dataset set)
- Modify: `python/src/ttio/transport/_writer.py` (bulk-mode probe: skip `blocks_v1` runs), `transport/_common.py` if it slices channels directly
- Modify: `python/tests/conformance/*` fixture builders for genomic runs (`opt_legacy_whole_channel=True` with a comment naming spec 2/3), any test that opens `signal_channels/qualities` etc. directly
- Test: `python/tests/test_signatures*.py` (extend), `python/tests/test_transport_codec.py` (extend)

- [ ] **Step 1: Run the full suite and list failures**

Run: `$PY -m pytest python/tests -q --ignore=python/tests/conformance -x --maxfail=200 2>&1 | grep -E "^FAILED|passed|failed" | head -80`
Every failure is one of: (a) a test reading a whole-channel dataset directly, (b) a signature over a genomic run, (c) transport bulk mode reading blobs verbatim, (d) an assertion on the v1.8 layout by name. Fix (a) by going through `GenomicRun` or by setting `opt_legacy_whole_channel=True` when the test is *about* the v1.8 layout; (b) and (c) per steps 2-3; (d) update the expectation.

- [ ] **Step 2: Signatures**

In `sign_genomic_run` / `verify_genomic_run`, when the run has `@layout == "blocks_v1"`, include `blocks/index` (via `read_canonical_bytes`) in the canonical concatenation after `genomic_index/*` and before `signal_channels/*`; document the order in the function docstring and in `docs/format-spec.md` §10.1. Test: sign a two-block run, verify passes; flip one byte in `blocks/index`, verify fails.

- [ ] **Step 3: Transport bulk mode**

Where the writer probes a genomic run for v2 blobs (`_write_bulk_v2_blob` callers / `use_bulk_mode` path in `transport/_writer.py`), add: if the run group has `@layout == "blocks_v1"`, do not emit `BlobV2*` packets for it (fall back to per-AU). Add a test in `test_transport_codec.py`: a `blocks_v1` genomic run with `use_bulk_mode=True` round-trips with no `BLOB_V2_*` packets present and content equal. Add to spec §11 open items: "per-block bulk carriage".

- [ ] **Step 4: Pin xlang genomic fixtures to legacy**

In `python/tests/conformance/` (and `python/tests/validation/`) every builder that writes a genomic run for Java/ObjC to read sets `opt_legacy_whole_channel=True` with the comment `# blocks_v1 read support lands with the Java/ObjC streaming specs; until then the xlang genomic fixtures use the whole-channel layout.` Run: `$PY -m pytest python/tests/conformance -q` and confirm green.

- [ ] **Step 5: Full suite green, commit** — subject `test: adapt signatures, transport bulk mode and fixtures to blocks_v1`

---

### Task 6: `SpectralStreamWriter` (extendable spectral datasets, codec-17 finalise)

**Files:**
- Create: `python/src/ttio/spectral/stream_writer.py` (package `ttio/spectral/__init__.py` if absent; else `python/src/ttio/spectral_stream_writer.py`)
- Modify: `python/src/ttio/codecs/float_delta_zstd.py` (add `encode_block(values) -> tuple[int, bytes]`, `header_bytes(n_values, n_blocks)`), `python/src/ttio/stream_writer.py` (rewrap)
- Test: `python/tests/test_spectral_stream_writer.py`

**Interfaces:**
- Produces: `SpectralStreamWriter(study_group, run_name, *, spectrum_class, acquisition_mode, channel_names, instrument_config=None, batch_spectra=4096, opt_disable_float_delta=False, signal_compression=None)`; `append(spectrum)`, `append_batch(batch: WrittenRun)`, `flush()`, `close()`, `spectrum_count`.
- Produces: `float_delta_zstd.encode_block(values: np.ndarray) -> tuple[int, bytes]` (transform byte, zstd body for one block of ≤ BLOCK_SIZE values, using the same none/delta pick) and `float_delta_zstd.header_bytes(n_values: int, n_blocks: int) -> bytes` (the 22-byte header); `encode()` is re-expressed with them so its bytes are unchanged (golden fixture test guards it).
- On disk: identical to `write_minimal` for MS (spectrum_index datasets, `<c>_values` with `@compression`, codec-17 stream per float64 channel).

- [ ] **Step 1: Write the failing tests**

```python
# python/tests/test_spectral_stream_writer.py
import numpy as np
from ttio.codecs import float_delta_zstd as fdz
from ttio.spectral_dataset import SpectralDataset, WrittenRun
from ttio.enums import AcquisitionMode, Polarity
from ttio.spectral.stream_writer import SpectralStreamWriter


def _run(n, pts, seed=1):
    rng = np.random.default_rng(seed)
    mz = np.sort(rng.uniform(100, 2000, n * pts)).reshape(n, pts).ravel()
    it = rng.uniform(0, 1e6, n * pts)
    return WrittenRun(spectrum_class="TTIOMassSpectrum", acquisition_mode=int(AcquisitionMode.MS1_DDA),
                      channel_data={"mz": mz, "intensity": it},
                      offsets=np.arange(0, n * pts, pts, dtype="<u8"), lengths=np.full(n, pts, dtype="<u4"),
                      retention_times=np.arange(n, dtype="<f8"), ms_levels=np.ones(n, dtype="<i4"),
                      polarities=np.full(n, int(Polarity.POSITIVE), dtype="<i4"),
                      precursor_mzs=np.zeros(n, dtype="<f8"), precursor_charges=np.zeros(n, dtype="<i4"),
                      base_peak_intensities=np.ones(n, dtype="<f8"))


def test_encode_via_blocks_matches_encode():
    v = np.random.default_rng(3).uniform(0, 1, 3 * fdz.BLOCK_SIZE + 17)
    whole = fdz.encode(v)
    parts = [fdz.encode_block(v[i:i + fdz.BLOCK_SIZE]) for i in range(0, len(v), fdz.BLOCK_SIZE)]
    rebuilt = fdz.header_bytes(len(v), len(parts)) + b"".join(
        bytes([t]) + len(b).to_bytes(4, "little") + b for t, b in parts)
    assert rebuilt == whole


def test_stream_writer_output_reads_like_write_minimal(tmp_path):
    run = _run(3000, 700)   # 2.1 M points: crosses a codec-17 block boundary
    a = str(tmp_path / "a.tio"); b = str(tmp_path / "b.tio")
    SpectralDataset.write_minimal(a, title="t", isa_investigation_id="i", runs={"r": run})
    SpectralDataset.write_minimal(b, title="t", isa_investigation_id="i", runs={})
    with SpectralDataset.open(b, mode="a") as ds:
        with SpectralStreamWriter(ds.study_group, "r", spectrum_class="TTIOMassSpectrum",
                                  acquisition_mode=int(AcquisitionMode.MS1_DDA),
                                  channel_names=["mz", "intensity"], batch_spectra=500) as w:
            for s in range(0, 3000, 250):
                w.append_batch(_slice_written_run(run, s, s + 250))
    with SpectralDataset.open(a) as da, SpectralDataset.open(b) as db:
        ra, rb = da.all_runs["r"], db.all_runs["r"]
        assert len(ra) == len(rb) == 3000
        for i in (0, 1499, 2999):
            for c in ("mz", "intensity"):
                assert np.array_equal(np.asarray(ra[i].signal_array(c).data), np.asarray(rb[i].signal_array(c).data))
```

with `_slice_written_run` a small helper in the test (slice arrays, rebase offsets), or import one if `WrittenRun` has it.

- [ ] **Step 2: Run to verify failure**

Run: `$PY -m pytest python/tests/test_spectral_stream_writer.py -q`
Expected: FAIL (`No module named 'ttio.spectral.stream_writer'` / no `encode_block`).

- [ ] **Step 3: Refactor `float_delta_zstd.encode` into `header_bytes` + `encode_block`; implement `SpectralStreamWriter`**

Writer: on first batch, create the run group with the same attrs `write_minimal` writes for a spectral run (find `_write_run` in `spectral_dataset.py` and reuse its attribute-writing helper), create `spectrum_index/*` datasets extendable (same precisions/compression as `_write_run`), and per channel: if codec 17 applies (float64 MS channel and not `opt_disable_float_delta`) create `<c>_values` UINT8 extendable chunk 4 MiB with `@compression=17` and append `header_bytes(0, 0)` placeholder; keep a per-channel pending float64 buffer; whenever it reaches `BLOCK_SIZE`, `encode_block` and append `transform + len + body`; else create `<c>_values` FLOAT64 extendable with the run's chunk size/`@compression` and append raw. `flush()` appends index arrays for the batch; `close()` encodes the trailing partial block, then rewrites bytes `[0,22)` of each codec-17 dataset with `header_bytes(n_values, n_blocks)` (needs `StorageDataset.write_slice(offset, data)`; add it to the protocol in Task 1 style for hdf5/zarr/memory/sqlite: hdf5 `self._ds[o:o+len] = data`), then writes `@spectrum_count`/`@total_points` and the `offsets` redundancy fields as `_write_run` does. `ttio/stream_writer.py::StreamWriter` keeps its API and delegates to `SpectralStreamWriter` (flush appends instead of rewriting the file).

- [ ] **Step 4: Run tests**

Run: `$PY -m pytest python/tests/test_spectral_stream_writer.py python/tests/test_float_delta_zstd*.py python/tests/test_stream_writer*.py -q`
Expected: pass; the codec-17 golden fixture test still passes (bytes unchanged).

- [ ] **Step 5: Commit** — subject `feat(spectral): SpectralStreamWriter over extendable datasets; codec 17 header finalised at close`

---

### Task 7: `AcquisitionRun.iter_spectra` with per-block codec-17 decode

**Files:**
- Modify: `python/src/ttio/acquisition_run.py` (replace decode-once cache for `@compression == 17` with a block-table decoder), `python/src/ttio/codecs/float_delta_zstd.py` (`BlockTable.from_stream_header(ds) `, `decode_block`)
- Test: `python/tests/test_acquisition_run_iter.py`

**Interfaces:**
- Produces: `float_delta_zstd.read_block_table(ds: StorageDataset) -> BlockTable` (n_values, block_size, list of `(byte_off, transform, body_len)` read by walking headers with `ds.read(off, 5)`); `decode_block(ds, table, k) -> np.ndarray`.
- Produces: `AcquisitionRun.iter_spectra(batch: int = 4096) -> Iterator[Spectrum]` and `AcquisitionRun.channel_range(name, start, count) -> np.ndarray` (values `[start, start+count)`, decoding only the blocks touched, cached one block per channel).
- `__getitem__` and `signal_array` for codec-17 channels go through `channel_range`; the eager `_numpress_channels` decode-once entry for codec 17 is removed (numpress keeps its path).

- [ ] **Step 1: Write the failing test**

```python
# python/tests/test_acquisition_run_iter.py
import numpy as np, resource
from ttio.spectral_dataset import SpectralDataset
from tests.test_spectral_stream_writer import _run


def test_iter_spectra_matches_getitem_and_bounds_memory(tmp_path):
    run = _run(4000, 700)     # 2.8 M points, 3 codec-17 blocks per channel
    p = str(tmp_path / "a.tio")
    SpectralDataset.write_minimal(p, title="t", isa_investigation_id="i", runs={"r": run})
    with SpectralDataset.open(p) as ds:
        r = ds.all_runs["r"]
        before = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        n = 0
        for i, sp in enumerate(r.iter_spectra(batch=256)):
            if i % 997 == 0:
                assert np.array_equal(np.asarray(sp.signal_array("mz").data), np.asarray(r[i].signal_array("mz").data))
            n += 1
        assert n == 4000
        assert r._fdz_blocks_decoded["mz"] <= 4   # blocks, not spectra
```

- [ ] **Step 2: Run to verify failure**, then implement per the interfaces (the block table is built once at open by walking the stream headers, which reads 5 bytes per block; `channel_range` computes `k0 = start // block_size`, `k1 = (start+count-1) // block_size`, decodes those blocks with a one-block LRU per channel, concatenates the needed slice). Keep `_fdz_blocks_decoded: dict[str, int]` counters for the test.

- [ ] **Step 3: Run** `$PY -m pytest python/tests/test_acquisition_run_iter.py python/tests/test_transport_codec.py python/tests/test_encryption*.py -q` (transport and encryption consumers read channels through the run; they must still pass).

- [ ] **Step 4: Commit** — subject `feat(spectral): per-block codec 17 decode; AcquisitionRun.iter_spectra`

---

### Task 8: Streaming genomic importers (BAM/SAM/CRAM, FASTQ)

**Files:**
- Modify: `python/src/ttio/importers/bam.py`, `sam.py`, `cram.py`, `fastq.py` (+ `fasta.py` reference loading helper), `python/src/ttio/tools/fastq_import_cli.py`, `importers/registry.py` (pass `block_reads/block_bytes/opt_legacy_whole_channel`)
- Test: `python/tests/test_importers_stream_genomic.py`

**Interfaces:**
- Produces: `bam.iter_batches(path, *, batch_reads=100_000, reference=None) -> Iterator[WrittenGenomicRun]` (the existing `samtools view` line parser, yielding a `WrittenGenomicRun` per `batch_reads` lines; header parsed once for `@RG` sample/platform and `@SQ`); `bam.read(path, output_path, *, block_reads=1_000_000, block_bytes=256<<20, opt_legacy_whole_channel=False, reference_fasta=None, ...)` writes through `GenomicStreamWriter`. Same for `sam` and `cram` (cram = `samtools view -T ref`). `fastq.FastqReader.iter_batches(batch_reads)` and `fastq` import writing through the stream writer.
- Reference for refdiff_v2: `importers/fasta.py` gains `lazy_reference(path) -> Mapping[str, bytes]` (loads a chromosome on first access via `samtools faidx`/`.fai` offsets); the writer's `reference_chrom_seqs` accepts that mapping.

- [ ] **Step 1: Write the failing tests**

```python
# python/tests/test_importers_stream_genomic.py
import resource, shutil, subprocess, sys
from pathlib import Path
import pytest
from ttio.importers import bam as bam_imp
from ttio.spectral_dataset import SpectralDataset

REPO = Path(__file__).resolve().parents[2]
BAM = REPO / "python/tests/fixtures/genomic/m87_test.bam"
sys.path.insert(0, str(REPO / "tools/perf/compression_suite"))
import verify  # the suite's digests (Task 2 of the suite plan); if that plan is not merged yet, copy sam11_md5 into tests/helpers/digests.py


@pytest.mark.skipif(shutil.which("samtools") is None, reason="samtools")
def test_bam_import_streams_and_round_trips(tmp_path):
    out = tmp_path / "o.tio"
    bam_imp.read(str(BAM), str(out), block_reads=25)
    with SpectralDataset.open(str(out)) as ds:
        g = next(iter(ds.genomic_runs.values()))
        assert g.block_count >= 2
    from ttio.exporters import registry as ex
    sam = tmp_path / "o.sam"
    ex.export("sam", str(out), next(iter(SpectralDataset.open(str(out)).genomic_runs)), str(sam))
    assert verify.sam11_md5(sam) == verify.sam11_md5(BAM)


@pytest.mark.skipif(shutil.which("samtools") is None, reason="samtools")
def test_bam_import_memory_ceiling(tmp_path):
    big = tmp_path / "big.fastq"
    with open(big, "w") as f:
        for i in range(2_000_000):
            f.write(f"@r{i}\n{'ACGT' * 25}\n+\n{'I' * 100}\n")
    from ttio.importers import fastq as fq
    before = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    fq.read(str(big), str(tmp_path / "big.tio"), block_reads=250_000)
    after = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    assert (after - before) / 1024 < 2000, "peak RSS grew by more than 2 GB"
```

- [ ] **Step 2: Run to verify failure**, then implement: turn the accumulate-then-write bodies of `bam.py` (lines ~200-330), `sam.py`, `cram.py`, `fastq.py` into `iter_batches` generators (same parsing code, `yield` a `WrittenGenomicRun` every `batch_reads`), and make `read()` open the output with `SpectralDataset.write_minimal(..., runs={})` then `GenomicStreamWriter(...).append_batch` per batch. Reference: `lazy_reference` mapping backed by `.fai` (`samtools faidx <fa> <chrom>` per chromosome on first access, cached).

- [ ] **Step 3: Run** the two tests plus `python/tests/test_m87*.py python/tests/test_m88*.py python/tests/test_fastq*.py -q`.

- [ ] **Step 4: Commit** — subject `feat(importers): stream BAM/SAM/CRAM and FASTQ through GenomicStreamWriter`

---

### Task 9: Streaming spectral importers (mzML, Thermo RAW, Bruker .d, Waters .raw)

**Files:**
- Modify: `python/src/ttio/importers/mzml.py`, `thermo_raw.py`, `bruker_tdf.py`, `waters_masslynx.py`
- Test: `python/tests/test_importers_stream_spectral.py`

**Interfaces:**
- Produces: `mzml.iter_batches(path, batch_spectra=4096) -> Iterator[WrittenRun]` over `pyteomics.mzml.MzML` (already an XML iterator); `mzml.read(path, output_path, *, batch_spectra=4096, ...)` through `SpectralStreamWriter`. Thermo: iterate scans through the existing per-scan accessor (`thermo_raw.py` uses a `RawFileReader`-style API with `GetScan`/scan range; yield batches). Bruker: frame iterator over `tdf_bin` (`bruker_tdf.read_dataset` already walks frames; make it yield). Waters: function/scan iterator. Where a backend only exposes a whole-file API, keep the whole-file path and record it in `docs/migration-guide.md` "streaming support" table (spec §11).

- [ ] **Step 1: Test** — `tiny.pwiz.1.1.mzML` and `1min.mzML` (`objc/Tests/Fixtures/1min.mzML`) import with `batch_spectra=7`, then export mzML and compare `verify.mzml_arrays_md5`; a synthesised 200 k-spectrum mzML (write with psims in the test, 100 points each) imports with peak RSS growth under 2 GB.

- [ ] **Step 2: Implement; run** `$PY -m pytest python/tests/test_importers_stream_spectral.py python/tests/test_mzml*.py python/tests/test_thermo*.py python/tests/test_bruker*.py -q`.

- [ ] **Step 3: Commit** — subject `feat(importers): stream mzML and vendor readers through SpectralStreamWriter`

---

### Task 10: Streaming exporters (SAM/BAM, FASTQ, mzML)

**Files:**
- Modify: `python/src/ttio/exporters/sam.py` (or `bam.py`), `exporters/fastq.py`, `exporters/mzml.py`, `tools/fastq_export_cli.py`
- Test: `python/tests/test_exporters_stream.py`

**Interfaces:**
- SAM/BAM: iterate `run.iter_reads()`, write SAM lines to a `samtools view -b -o out -` pipe (BAM) or a file (SAM); header from `@SQ` (reference names/lengths from the embedded or external reference and `run.chromosome_names`), `@RG` from `sample_name/platform`.
- FASTQ: iterate `iter_reads`, write 4 lines per read to a text stream (gzip when the path ends `.gz`).
- mzML: iterate `iter_spectra(batch)`, write with the existing writer made incremental: open, write header, stream `<spectrum>` elements, at close write the `spectrumList count` (seek back to a fixed-width placeholder written at open) and the index if the writer emits indexed mzML.
- Memory: peak RSS growth under 1 GB on the 2 M-read FASTQ file from Task 8 and the 200 k-spectrum mzML from Task 9.

- [ ] **Step 1: Test** — round-trip digests (`sam11_md5`, `fastq_md5`, `mzml_arrays_md5`) equal for the m87 BAM, a 10 k-read FASTQ, `1min.mzML`; RSS bound test on the big inputs.
- [ ] **Step 2: Implement; run** `$PY -m pytest python/tests/test_exporters_stream.py python/tests/test_export*.py -q`.
- [ ] **Step 3: Commit** — subject `feat(exporters): stream SAM/BAM, FASTQ and mzML from iter_reads/iter_spectra`

---

### Task 11: CLI flags, golden fixture, docs, efficiency measurement

**Files:**
- Modify: `python/src/ttio/tools/workbench_cli.py` (`encode`: `--block-reads`, `--block-bytes`, `--legacy-whole-channel`; `export` unchanged), `importers/registry.py` (forward the three)
- Create: `python/tests/fixtures/genomic/blocks_v1_golden.tio` + `python/tests/fixtures/genomic/generate_blocks_v1_golden.py`
- Modify: `CHANGELOG.md` `[Unreleased]`, `docs/format-spec.md` §1 versioning note, `docs/migration-guide.md` streaming section
- Test: `python/tests/test_blocks_v1_golden.py`

- [ ] **Step 1: Golden fixture** — `generate_blocks_v1_golden.py` writes m87 BAM through `bam.read(..., block_reads=25, embed_reference=True)`; the test opens the fixture, checks `layout == "blocks_v1"`, `block_count >= 2`, and that `sam11_md5` of an export equals the m87 BAM's. Commit the `.tio` (small).
- [ ] **Step 2: CLI** — add the three options to `ttio encode`, forwarded through `registry.encode(fmt, inputs, output, **opts)`; test via `subprocess` that `--block-reads 25` yields `block_count >= 2`.
- [ ] **Step 3: Efficiency measurement** — on `data/genomic/na12878/na12878.chr22.lean.mapped.bam` and `data/genomic/na12878_wes/na12878_wes.chr22.bam`, import with defaults and with `--legacy-whole-channel`; record output sizes and peak RSS (`/usr/bin/time -v`) in the PR body and in `docs/format-spec.md` §10.12 as a one-line note ("measured on chr22: blocks_v1 vs whole-channel +X.X%").
- [ ] **Step 4: CHANGELOG** — `### Changed`: streaming import/export in all Python importers/exporters, `blocks_v1` default genomic layout with `opt_legacy_whole_channel`, extendable datasets in the four providers, per-block codec-17 reads; **Reader compatibility:** genomic files written with defaults are not readable by releases up to and including v1.8.0; Java and ObjC read support follows in the next two PRs.
- [ ] **Step 5: Commit** — subject `feat(cli): block sizing flags; blocks_v1 golden fixture; docs`

---

### Task 12: Full suites, PR

- [ ] **Step 1: Run** `$PY -m pytest python/tests -q --ignore=python/tests/conformance` then `python/tests/conformance -q`; both green. Also `cd java && mvn -q -o test` and `cd objc && ./build.sh check` (they must stay green: their fixtures are pinned to legacy in Task 5 and MS files are layout-identical).
- [ ] **Step 2: Push** via Windows git; open the PR with a gated `--body-file` (5 parts, under 200 words): problem (whole-run memory), fix (blocks_v1 + extendable datasets + streaming importers/exporters), what it does not do (Java/ObjC read support, per-block bulk mode, lossy), test paths, tallies before/after; include the chr22 efficiency and RSS numbers.

---

## Self-review

- Spec §2 (layout): Task 3 writes it, Task 4 reads it, Task 3 Step 6 documents it. §2.5 partial-file: Task 4 test 3. §2.6 signatures: Task 5.
- Spec §3 (MS): Task 6 (writer, header finalise), Task 7 (reader per block).
- Spec §4 (providers): Task 1 (+ `write_slice` added in Task 6 Step 3, all four providers).
- Spec §5.1-5.2 (writers): Tasks 3, 6. §5.3 (readers): Tasks 4, 7. §5.4 (importers/exporters): Tasks 8-10, incl. the vendor readers and the "whole-file API" fallback recorded in docs. §5.5 (CLI): Task 11.
- Spec §6 (policy): Task 3 (both caps, `@block_policy`).
- Spec §7 (compat): Task 3 Step 4 (`opt_legacy_whole_channel`), Task 5 Step 4 (xlang pins), Task 11 CHANGELOG.
- Spec §8 (golden fixture): Task 11 Step 1; xlang cell deferred to spec 4 by design.
- Spec §9: Task 5 Step 2 (signatures), bulk mode fallback Step 3.
- Spec §10 (validation): provider tests (T1), multi-block round trip 1/25/10^6 (T4), partial write (T4), importer memory ceilings (T8, T9), exporter digests (T10), efficiency measurement (T11), full suites (T12).
- Names used consistently: `GenomicStreamWriter`, `SpectralStreamWriter`, `_blocks.encode_block/slice_run/BLOCK_CHANNELS/BlockBlobs`, `materialise_block`, `iter_reads`, `iter_spectra`, `channel_range`, `read_block_table/decode_block/encode_block/header_bytes`, `study_group`, `opt_legacy_whole_channel`, `chrom_name_to_id`, index field names per Global Constraints.
