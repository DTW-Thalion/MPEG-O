"""``GenomicStreamWriter``: write a genomic run as ``blocks_v1`` with
bounded memory.

Reads are buffered until a block is full (``block_reads`` reads or
``block_bytes`` sequence bytes, whichever first), encoded through
:func:`ttio.genomic._blocks.encode_block`, and appended to extendable
per-channel datasets; ``blocks/index`` records where each block's
blob lives. Format: ``docs/format-spec.md`` section 10.12; design:
``docs/superpowers/specs/2026-08-16-streaming-blocks-v1-design.md``.

Cross-language equivalents
--------------------------
Java: ``global.thalion.ttio.genomics.GenomicStreamWriter`` ·
Objective-C: ``TTIOGenomicStreamWriter`` (both follow this module).

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import dataclasses
from typing import Any

import numpy as np

from .. import _hdf5_io as io
from ..enums import Compression, Precision
from ..providers.base import CompoundField, CompoundFieldKind
from ..written_genomic_run import WrittenGenomicRun
from . import _blocks

LAYOUT = "blocks_v1"
DEFAULT_BLOCK_READS = 1_000_000
DEFAULT_BLOCK_BYTES = 256 << 20
CHANNEL_CHUNK = 4 << 20

#: Block index schema, in the fixed column order of format-spec 10.12.
INDEX_FIELDS: list[CompoundField] = (
    [CompoundField("read_start", CompoundFieldKind.UINT64),
     CompoundField("n_reads", CompoundFieldKind.UINT32),
     CompoundField("base_start", CompoundFieldKind.UINT64),
     CompoundField("n_bases", CompoundFieldKind.UINT64)]
    + [CompoundField(f"{ch}_{k}", CompoundFieldKind.UINT64)
       for ch in _blocks.BLOCK_CHANNELS for k in ("off", "len")]
)

_INDEX_ARRAYS = (
    ("lengths", Precision.UINT32, np.uint32),
    ("positions", Precision.INT64, np.int64),
    ("mapping_qualities", Precision.UINT8, np.uint8),
    ("flags", Precision.UINT32, np.uint32),
    ("chromosome_ids", Precision.UINT16, np.uint16),
)


class GenomicStreamWriter:
    """Append reads to one genomic run of an open-for-write dataset."""

    def __init__(self, study_group, run_name: str, *,
                 acquisition_mode: int, reference_uri: str, platform: str,
                 sample_name: str, reference_chrom_seqs=None,
                 embed_reference: bool = False,
                 block_reads: int = DEFAULT_BLOCK_READS,
                 block_bytes: int = DEFAULT_BLOCK_BYTES,
                 opt_disable_qualities_v5: bool = False,
                 signal_codec_overrides: dict | None = None,
                 signal_compression: str = "gzip",
                 opt_legacy_whole_channel: bool = False,
                 provenance_records=None):
        self._study = study_group
        self._provenance = list(provenance_records or [])
        self._name = run_name
        self._meta: dict[str, Any] = dict(
            acquisition_mode=int(acquisition_mode), reference_uri=reference_uri,
            platform=platform, sample_name=sample_name,
            reference_chrom_seqs=reference_chrom_seqs,
            embed_reference=bool(embed_reference),
            opt_disable_qualities_v5=bool(opt_disable_qualities_v5),
            signal_codec_overrides=dict(signal_codec_overrides or {}),
            signal_compression=signal_compression,
        )
        if block_reads < 1 or block_bytes < 1:
            raise ValueError("block_reads and block_bytes must be >= 1")
        self._block_reads = int(block_reads)
        self._block_bytes = int(block_bytes)
        self._legacy = bool(opt_legacy_whole_channel)
        self._pending: list[WrittenGenomicRun] = []
        self._pending_reads = 0
        self._pending_bytes = 0
        self._chrom_map: dict[str, int] = {}
        self._read_count = 0
        self._base_count = 0
        self._block_count = 0
        self._rg = None
        self._ds: dict[str, Any] = {}
        self._idx: dict[str, Any] = {}
        self._index = None
        self._seq_layout: str | None = None
        self._embedded = False
        self._closed = False
        self._legacy_parts: list[WrittenGenomicRun] = []

    # ------------------------------------------------------------------
    @property
    def read_count(self) -> int:
        return self._read_count

    @property
    def block_count(self) -> int:
        return self._block_count

    def append(self, read) -> None:
        """Append one :class:`~ttio.aligned_read.AlignedRead`."""
        self.append_batch(_single_read_run(read, self._meta))

    def append_batch(self, batch: WrittenGenomicRun) -> None:
        """Append the reads of ``batch`` (its run-level metadata is
        ignored; the writer's own applies)."""
        if self._closed:
            raise RuntimeError("writer is closed")
        n = int(len(batch.lengths))
        if n == 0:
            return
        if self._legacy:
            self._legacy_parts.append(batch)
            return
        start = 0
        while start < n:
            room_reads = self._block_reads - self._pending_reads
            room_bytes = self._block_bytes - self._pending_bytes
            stop = min(n, start + max(room_reads, 1))
            cum = np.cumsum(np.asarray(batch.lengths[start:stop], dtype=np.int64))
            fit = int(np.searchsorted(cum, room_bytes, side="right"))
            if fit < stop - start:
                stop = start + max(fit, 1)
            part = batch if (start, stop) == (0, n) else _blocks.slice_run(batch, start, stop)
            self._pending.append(part)
            self._pending_reads += stop - start
            self._pending_bytes += int(np.asarray(part.lengths, dtype=np.int64).sum())
            if self._pending_reads >= self._block_reads or self._pending_bytes >= self._block_bytes:
                self.flush()
            start = stop

    def flush(self) -> None:
        """Encode and write the pending reads as one block."""
        if self._legacy or not self._pending:
            return
        block = _blocks.concat_runs(self._pending)
        self._pending = []
        self._pending_reads = 0
        self._pending_bytes = 0
        block = _apply_meta(block, self._meta, self._chrom_map)
        if not self._embedded and self._meta["embed_reference"]:
            from .._dataset_write_genomic import _embed_references_for_runs
            _embed_references_for_runs(self._study, {self._name: block})
            self._embedded = True
        blobs = _blocks.encode_block(block)
        self._ensure_layout(blobs)
        row = {"read_start": self._read_count, "n_reads": blobs.n_reads,
               "base_start": self._base_count, "n_bases": blobs.n_bases}
        for ch in _blocks.BLOCK_CHANNELS:
            data = blobs.blobs[ch]
            ds = self._ds.get(ch)
            if ds is None:
                if data:
                    ds = self._create_channel(ch, blobs)
                else:
                    row[f"{ch}_off"] = 0
                    row[f"{ch}_len"] = 0
                    continue
            row[f"{ch}_off"] = int(ds.length)
            row[f"{ch}_len"] = len(data)
            if data:
                ds.append(np.frombuffer(data, dtype=np.uint8))
        self._index.append([row])
        self._append_index_arrays(block)
        self._read_count += blobs.n_reads
        self._base_count += blobs.n_bases
        self._block_count += 1
        io.write_int_attr(self._rg, "read_count", self._read_count)
        io.write_int_attr(self._rg, "base_count", self._base_count)

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        if self._legacy:
            if self._legacy_parts:
                from .._dataset_write_genomic import (
                    _embed_references_for_runs, _write_genomic_run)
                whole = _apply_meta(_blocks.concat_runs(self._legacy_parts), self._meta, None)
                if self._meta["embed_reference"]:
                    _embed_references_for_runs(self._study, {self._name: whole})
                whole = dataclasses.replace(whole, provenance_records=list(self._provenance))
                _write_genomic_run(self._runs_group(), self._name, whole)
                self._read_count = int(len(whole.lengths))
            self._legacy_parts = []
            return
        self.flush()
        if self._rg is None:
            self._ensure_layout(None)
        self._write_close_tables()
        if self._provenance:
            from .._dataset_write_metadata import _write_provenance
            prov = self._rg.create_group("provenance")
            _write_provenance(prov, self._provenance, dataset_name="steps")

    def __enter__(self) -> "GenomicStreamWriter":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    # ------------------------------------------------------------------
    def _runs_group(self):
        if self._study.has_child("genomic_runs"):
            g = self._study.open_group("genomic_runs")
        else:
            g = self._study.create_group("genomic_runs")
            io.write_fixed_string_attr(g, "_run_names", "")
        names = [n for n in (io.read_string_attr(g, "_run_names", default="") or "").split(",") if n]
        if self._name not in names:
            names.append(self._name)
            io.write_fixed_string_attr(g, "_run_names", ",".join(names))
        return g

    def _ensure_layout(self, blobs) -> None:
        if self._rg is not None:
            return
        g = self._runs_group()
        if g.has_child(self._name):
            raise ValueError(f"genomic run {self._name!r} already exists")
        rg = g.create_group(self._name)
        m = self._meta
        io.write_int_attr(rg, "acquisition_mode", m["acquisition_mode"])
        io.write_fixed_string_attr(rg, "modality", "genomic_sequencing")
        io.write_int_attr(rg, "spectrum_class", 5)
        io.write_fixed_string_attr(rg, "reference_uri", m["reference_uri"])
        io.write_fixed_string_attr(rg, "platform", m["platform"])
        io.write_fixed_string_attr(rg, "sample_name", m["sample_name"])
        io.write_int_attr(rg, "read_count", 0)
        io.write_int_attr(rg, "base_count", 0)
        io.write_fixed_string_attr(rg, "layout", LAYOUT)
        io.write_fixed_string_attr(
            rg, "block_policy", f"reads={self._block_reads},bytes={self._block_bytes}")
        blocks = rg.create_group("blocks")
        self._index = blocks.create_compound_dataset(
            "index", INDEX_FIELDS, 0, extendable=True, chunk_rows=1024)
        idx_group = rg.create_group("genomic_index")
        for name, prec, _ in _INDEX_ARRAYS:
            self._idx[name] = idx_group.create_dataset(
                name, prec, 0, chunk_size=io.DEFAULT_SIGNAL_CHUNK,
                compression=Compression.ZLIB, compression_level=6, extendable=True)
        rg.create_group("signal_channels")
        self._rg = rg

    def _create_channel(self, ch: str, blobs: _blocks.BlockBlobs):
        sc = self._rg.open_group("signal_channels")
        if ch == "sequences":
            self._seq_layout = blobs.seq_layout
            if blobs.seq_layout == "refdiff_v2":
                parent, name = sc.create_group("sequences"), "refdiff_v2"
            else:
                parent, name = sc, "sequences"
        elif ch == "mate_info":
            parent, name = sc.create_group("mate_info"), "inline_v2"
        else:
            parent, name = sc, ch
        ds = parent.create_dataset(name, Precision.UINT8, 0, chunk_size=CHANNEL_CHUNK,
                                   compression=Compression.NONE, extendable=True)
        io.write_int_attr(ds, "compression", int(blobs.compression[ch]), dtype="<u1")
        for k, v in blobs.extra_attrs.get(ch, {}).items():
            ds.set_attribute(k, v)
        self._ds[ch] = ds
        return ds

    def _append_index_arrays(self, block: WrittenGenomicRun) -> None:
        # The block encoder already registered this block's chromosome
        # names in the shared map (genomic_index assigns slots to every
        # name, '*' included), so every name resolves here.
        m = self._chrom_map
        ids = np.fromiter((m[c] for c in block.chromosomes), dtype=np.uint16,
                          count=len(block.chromosomes))
        arrays = {
            "lengths": np.asarray(block.lengths, dtype=np.uint32),
            "positions": np.asarray(block.positions, dtype=np.int64),
            "mapping_qualities": np.asarray(block.mapping_qualities, dtype=np.uint8),
            "flags": np.asarray(block.flags, dtype=np.uint32),
            "chromosome_ids": ids,
        }
        for name, _, dt in _INDEX_ARRAYS:
            self._idx[name].append(arrays[name].astype(dt, copy=False))

    def _write_close_tables(self) -> None:
        names = sorted(self._chrom_map, key=self._chrom_map.get)
        rows = [{"name": n} for n in names]
        idx_group = self._rg.open_group("genomic_index")
        io.write_compound_dataset(idx_group, "chromosome_names", rows,
                                  [("name", io.vl_str())])
        sc = self._rg.open_group("signal_channels")
        if sc.has_child("mate_info"):
            mate = sc.open_group("mate_info")
        else:
            mate = sc.create_group("mate_info")
        if not mate.has_child("chrom_names"):
            io.write_compound_dataset(mate, "chrom_names", rows,
                                      [("name", io.vl_str())])


# ----------------------------------------------------------------------
def _apply_meta(run: WrittenGenomicRun, meta: dict, chrom_map) -> WrittenGenomicRun:
    return dataclasses.replace(
        run,
        acquisition_mode=meta["acquisition_mode"], reference_uri=meta["reference_uri"],
        platform=meta["platform"], sample_name=meta["sample_name"],
        reference_chrom_seqs=meta["reference_chrom_seqs"],
        embed_reference=meta["embed_reference"],
        opt_disable_qualities_v5=meta["opt_disable_qualities_v5"],
        signal_codec_overrides=dict(meta["signal_codec_overrides"]),
        signal_compression=meta["signal_compression"],
        chrom_name_to_id=chrom_map,
    )


def _single_read_run(read, meta: dict) -> WrittenGenomicRun:
    seq = read.sequence
    seq_b = seq.encode("ascii") if isinstance(seq, str) else bytes(seq)
    qual = np.asarray(read.qualities, dtype=np.uint8)
    n = len(seq_b)
    return WrittenGenomicRun(
        acquisition_mode=meta["acquisition_mode"], reference_uri=meta["reference_uri"],
        platform=meta["platform"], sample_name=meta["sample_name"],
        positions=np.array([int(read.position)], dtype=np.int64),
        mapping_qualities=np.array([int(read.mapping_quality)], dtype=np.uint8),
        flags=np.array([int(read.flags)], dtype=np.uint32),
        sequences=np.frombuffer(seq_b, dtype=np.uint8),
        qualities=qual,
        offsets=np.zeros(1, dtype=np.uint64),
        lengths=np.array([n], dtype=np.uint32),
        cigars=[read.cigar],
        read_names=[read.read_name],
        mate_chromosomes=[read.mate_chromosome if read.mate_chromosome else "*"],
        mate_positions=np.array([int(read.mate_position)], dtype=np.int64),
        template_lengths=np.array([int(read.template_length)], dtype=np.int32),
        chromosomes=[read.chromosome],
    )
