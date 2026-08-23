# Streaming import/export and the genomic block layout (`blocks_v1`)

> **Status (2026-08-17).** Implemented in Python (branch
> `streaming-blocks-v1`); the normative layout is `docs/format-spec.md`
> section 10.12, which supersedes section 2 below where they differ.
> Decisions made during implementation, all in 10.12: blocks never
> span chromosomes; per-channel `<ch>_codec` index columns;
> `sequences/data` for every codec; every blob channel is codec-coded
> (cigars RANS_ORDER0, qualities FQZCOMP_NX16_Z, reference-less
> sequences RANS_ORDER1; RANS_ORDER0 qualities for a block holding a
> zero-length read); own chromosome ids from `mate_info/chrom_names`;
> whole-channel-only features: per-AU/region encryption, verbatim bulk
> transport for multi-block runs. Sub-project 1 of 4
> (format + Python reference implementation). Java (2), ObjC (3) and
> the cross-language conformance + benchmark work (4) each get their
> own spec that reads this one as the format contract. Plan:
> `docs/superpowers/plans/2026-08-16-streaming-blocks-v1.md`.

> **Out of scope for this spec:** Java and ObjC implementations
> (specs 2 and 3), a region index over blocks beyond what §2.4 gives
> for free, changes to any codec's wire format, per-AU encryption of
> genomic channels (unchanged, §9), the transport wire (already
> streams per AU).

## 0. Why this spec exists

Every TTI-O importer today builds a whole run in memory
(`WrittenGenomicRun`, `WrittenRun`: parallel arrays and Python lists
for every read or spectrum) and every genomic channel is stored as
one encoded blob per run (`read_names` name_tok_v2, `mate_info/
inline_v2`, `qualities` fqzcomp V4/V5, `sequences/refdiff_v2`,
`cigars` rANS). A whole 30x human genome (about 700 M reads, 100 G
bases) therefore cannot be written on a 32 GB machine, and a reader
must decode a whole channel to return one read. CRAM slices and
MPEG-G access units solve the same problem with independently coded
blocks; TTI-O gets the same shape. Mass-spectrometry runs need no
layout change: spectral channels are chunked datasets and codec 17 is
block-structured internally; they need extendable datasets and a
header finalise at close.

## 1. Goals and non-goals

Goals:

1. Import a BAM/SAM/CRAM, FASTQ, mzML, Thermo RAW, Bruker .d or Waters
   .raw of any size with bounded memory (one block plus the reference).
2. Export any run to SAM/BAM, FASTQ or mzML with bounded memory.
3. Random access `run[i]` and `reads_in_region` keep working and touch
   one block, not the whole channel.
4. All four Python storage providers (hdf5, zarr, memory, sqlite)
   support the layout; hdf5 and zarr support true append, memory and
   sqlite emulate it.
5. The layout is the default for genomic writers; `opt_legacy_whole_
   channel=True` writes the v1.8 layout for readers that need it.
6. Compression is within a few percent of the whole-channel layout on
   the audit corpora; the number is measured, not assumed.

Non-goals: changing any codec's byte format; a genomic region index
finer than block granularity; streaming *encryption* of genomic
channels; multi-threaded encode.

## 2. On-disk layout: `blocks_v1` (genomic runs)

### 2.1 Run-level

`/study/genomic_runs/<run>/@layout = "blocks_v1"` (fixed-length
string). Absent attribute means the v1.8 whole-channel layout. A
reader that does not know `blocks_v1` MUST fail with an unsupported-
layout error rather than misread bytes (v1.8 readers already reject
an unknown `@compression`; the attribute makes the failure explicit).

`@block_policy = "reads=1000000,bytes=268435456"` records the writer's
policy (informative).

### 2.2 The block index

`/study/genomic_runs/<run>/blocks/index` is a compound dataset, one
row per block, extendable, chunked (chunk 1024 rows), no filter:

| field | type | meaning |
|---|---|---|
| `read_start` | uint64 | index of the first read in the block |
| `n_reads` | uint32 | reads in the block |
| `base_start` | uint64 | offset into the concatenated base space (== `offsets[read_start]`) |
| `n_bases` | uint64 | bases in the block |
| `<ch>_off` | uint64 | byte offset of this block's blob in `signal_channels/<ch>` |
| `<ch>_len` | uint64 | byte length of that blob |

with `<ch>` in the fixed order `sequences, qualities, read_names,
cigars, mate_info` (10 columns, present even when a channel is absent
in the run: then `_len = 0`). Field order is part of the contract so
Java and ObjC can map it without reflection.

### 2.3 Channel datasets

Each blob channel is one extendable, chunked (chunk 4 MiB), unfiltered
1-D `uint8` dataset holding the blocks' blobs back to back:

```
signal_channels/
├── sequences/refdiff_v2   uint8[*], @compression=14   (or sequences/raw uint8[*], @compression 0/4/5/6 for the non-reference codecs)
├── qualities              uint8[*], @compression=12
├── read_names             uint8[*], @compression=15
├── cigars                 uint8[*], @compression=4|5
└── mate_info/inline_v2    uint8[*], @compression=13
    mate_info/chrom_names  compound (unchanged, whole-run table)
```

Every block's blob is exactly the byte string the v1.8 whole-channel
writer would have produced for a run consisting of that block's reads
alone (same codec, same header, same auto-tune), so the codec wire
formats and their golden fixtures are unchanged; the block index is
the only new structure. Two consequences the codecs already tolerate:
qualities V5 auto-tune runs per block (its 1 MiB floor is met by any
block over about 1 M quality bytes; smaller trailing blocks fall back
to the V4 pick as they do today for small runs); refdiff_v2's slice
index is per block; name_tok_v2 restarts its tokenizer per block.

`mate_info/chrom_names` and the reference tables stay run-level.

### 2.4 Index datasets (per read)

`index/{offsets, lengths, chromosome_ids, positions, mapping_qualities,
flags}` keep their v1.8 element types and codecs and become extendable
chunked datasets (chunk 1 M rows). Because `blocks/index` carries
`read_start` and `base_start`, `run[i]` resolves to a block with one
binary search and `reads_in_region` uses `positions` as today then
touches only the blocks that own the hits.

### 2.5 Counts and close

`@read_count` and `@base_count` on the run group are written at close
(and updated on every flush so a partially written file is readable
up to the last complete block). A writer that dies leaves a file
whose block index and datasets agree up to the last flushed block;
trailing bytes past the last indexed block are ignored by readers.

### 2.6 What is not block-scoped

References (`/study/references/<uri>/`), `mate_info/chrom_names`,
provenance, subjects/samples, signatures: unchanged. Signatures over a
`blocks_v1` run cover the same dataset set plus `blocks/index`
(§9).

## 3. Mass-spectrometry runs: streaming without a layout change

Spectral runs keep their layout (`spectrum_index/*`,
`signal_channels/<c>_values`, `@compression` per channel). The
streaming writer creates every per-spectrum dataset extendable
(chunk sizes as today), appends per batch of spectra, and at close:

- rewrites the FDZ1 header (`n_values`, `n_blocks`) of each codec-17
  channel, which is at byte offset 0 of that channel's dataset; block
  bodies were appended as each 2^20-value block filled;
- writes `@spectrum_count`, `@total_points`, and the `offsets`
  redundancy fields exactly as `write_minimal` does today;
- writes `blocks/index` (§3.1).

A file produced by the streaming writer is byte-for-byte a file
`write_minimal` could have produced except for HDF5 chunk allocation
and `blocks/index`; every existing MS reader opens it unchanged. The
existing `StreamWriter` (whole-file regenerative flush) becomes a thin
wrapper over the new writer and keeps its API.

### 3.1 The spectral block index

An MS run carries the same `blocks/index` a genomic run does (§2.2),
describing the FDZ1 blocks of its signal channels. One compound row
per block ordinal, in this column order:

```
value_start   u64   index of the block's first value
n_values      u32   values in the block; the last block may be short
<channel>_off u64   byte offset of the block in <channel>_values
<channel>_len u64   bytes of the block, its 5-byte header included
<channel>_codec u32 codec that produced it (17)
```

The `_off` / `_len` pairs come first in channel order, then the
`_codec` columns, matching the genomic layout. The channel set is not
fixed for a spectral run: the columns follow the run's own
`@channel_names` order, so two files of the same modality can order
them differently (the mzML importer declares intensity first). A
reader must therefore resolve columns by name, recovering the channel
set from the compound type — every `<name>_off` column names one
channel — and never by position.

A recorded extent covers the block header as well as the body, so the
bytes it names are a self-describing block: transform, body length,
body. Without the table a consumer has to walk each channel's stream
reading 5-byte headers to learn the same offsets; with it, one
compound read plans a range read or a parallel decode.

The group is written only for runs whose channels use codec 17, and
only when every channel cut its blocks at the same value boundaries —
true whenever each spectrum contributes one value per channel. A run
that fell out of step gets no table rather than a wrong one. Readers
must treat the group as optional: MS runs written before it exists do
not have it, and the block offsets remain recoverable from the streams
themselves.

## 4. Provider capability: extendable datasets

`providers/base.py` gains:

```python
def create_dataset(self, name, precision, length, *, chunk_size=0,
                   compression=NONE, compression_level=6,
                   extendable: bool = False) -> StorageDataset
class StorageDataset:
    @property
    def extendable(self) -> bool
    def append(self, data) -> None      # grows length by len(data)
```

`extendable=True` requires `chunk_size > 0` (raise otherwise).
`append` on a non-extendable dataset raises. Provider behaviour:

| provider | mechanism |
|---|---|
| hdf5 | `maxshape=(None,)`, `resize` then slice-assign |
| zarr | `append` |
| memory | list of arrays, concatenated on read |
| sqlite | one row per appended chunk; `read(offset,count)` walks rows |

`create_dataset_nd(..., extendable=True)` extends along axis 0 only.
Compound datasets support `extendable` the same way (the block index
is compound).

## 5. Python API

### 5.1 Genomic streaming writer

```python
class GenomicStreamWriter:
    def __init__(self, dataset: SpectralDataset, run_name: str, *,
                 acquisition_mode, reference_uri, platform, sample_name,
                 reference: ReferenceImport | None = None,   # in-memory reference for refdiff_v2
                 block_reads: int = 1_000_000, block_bytes: int = 256 << 20,
                 opt_disable_qualities_v5=False, signal_codec_overrides=None,
                 embed_reference=False, opt_legacy_whole_channel=False)
    def append(self, read: AlignedRead) -> None
    def append_batch(self, batch: WrittenGenomicRun) -> None   # arrays for many reads at once
    def flush(self) -> None          # encode + write the current partial block
    def close(self) -> None          # flush, finalise counts
    # context manager
```

`opt_legacy_whole_channel=True` buffers everything and calls the v1.8
writer at close (memory-unbounded by definition; kept for compat).
`SpectralDataset.write_minimal(..., genomic_runs=...)` is reimplemented
on top of the streaming writer with `block_reads/bytes` from the run,
so a small run written the old way still yields `blocks_v1` with a
single block.

### 5.2 Spectral streaming writer

```python
class SpectralStreamWriter:
    def __init__(self, dataset, run_name, *, spectrum_class, acquisition_mode,
                 channel_names, instrument_config=None, batch_spectra: int = 4096,
                 opt_disable_float_delta=False, ...)
    def append(self, spectrum: Spectrum) -> None
    def append_batch(self, batch: WrittenRun) -> None
    def flush(self) -> None
    def close(self) -> None
```

### 5.3 Readers

`GenomicRun.__iter__` and a new `GenomicRun.iter_reads(start=0,
stop=None)` decode one block at a time and hold at most one decoded
block; `__getitem__` resolves the block through `blocks/index` and
caches the last decoded block. `AcquisitionRun.__iter__` already
slices per spectrum; it gains `iter_spectra(batch=4096)` that reads
channel ranges per batch (no whole-channel eager decode; the codec-17
decode-once cache is replaced by per-block decode using the FDZ1
block table).

### 5.4 Importers and exporters

Every importer becomes a generator feeding a stream writer:

| importer | source iteration |
|---|---|
| bam / sam / cram | `samtools view` pipe, line by line (existing subprocess path) |
| fastq | existing `FastqReader` record iterator |
| mzml | `pyteomics.mzml.MzML` iterator (already streaming XML) |
| thermo_raw | the RAW reader's per-scan API |
| bruker_tdf | frame iterator over the tdf/tdf_bin |
| waters_masslynx | function-by-function scan iterator |

Every exporter iterates the run (`iter_reads` / `iter_spectra`) and
writes records as it goes: SAM/BAM via a `samtools view -b` pipe,
FASTQ line-wise, mzML through the existing writer made incremental
(spectrum list count written at close via a seek, or the index-less
mzML form).

The reference for `refdiff_v2` is loaded once (per chromosome, lazily
on first use) and is the only unbounded-in-input-size memory: about
1 byte per base of the reference actually touched.

### 5.5 CLI

`ttio encode` and `ttio export` gain `--block-reads` / `--block-bytes`
and `--legacy-whole-channel`; defaults as §5.1. Progress goes to
stderr every block.

## 6. Block sizing policy

Default `block_reads=1_000_000` and `block_bytes=256 MiB` of sequence
bytes, whichever fills first: short-read runs hit the read cap
(~150 MB seq + ~150 MB qual raw per block), HiFi/ONT hit the byte cap
(~17 k reads of 15 kb). Both are per-writer parameters and recorded
in `@block_policy`. Peak writer memory is about 3x the raw block
(input buffers + encoder working set) plus the reference.

## 7. Compatibility

- Default flips: every genomic writer emits `blocks_v1`. Readers up
  to v1.8.0 fail on `@layout` (or on the missing whole-channel
  datasets); the CHANGELOG states it, as for the codec-17 flip.
- `opt_legacy_whole_channel=True` restores the v1.8 layout per run.
- v1.8 readers of this release keep reading v1.8 files (`@layout`
  absent) unchanged; both layouts are read forever.
- Transport wire: unchanged; the transport writer's genomic AU path
  iterates blocks.

## 8. Cross-language contract and golden fixture

`python/tests/fixtures/genomic/blocks_v1_golden.tio`: the m87 test
BAM written with `block_reads=25` (so several blocks and a short
tail), embedded reference, all five channels present. Java and ObjC
(specs 2 and 3) must open it and match the SAM 11-column digest; the
xlang matrix adds a `GENOMIC_RUNS_BLOCKS` accessor cell. The block
index field order (§2.2) and the rule "each blob == the v1.8 writer's
output for that block's reads" are the entire contract.

## 9. Signatures and encryption

`sign_genomic_run` / `verify_genomic_run` cover the same datasets as
today plus `blocks/index` (canonical bytes as compound rows). Per-AU
encryption of genomic channels is not offered by the writers today
and stays out of scope; whole-dataset encryption keys and metadata
are untouched.

## 10. Validation plan

- Provider tests: `append` on all four providers, extendable compound.
- Writer/reader unit tests: multi-block round trip on m87 with
  `block_reads` of 1, 25 and 10^6; `run[i]` and `reads_in_region`
  agree with the whole-run decode; partial-write file readable up to
  the last flushed block.
- Every importer: memory ceiling test on a synthetic 5 M-read FASTQ /
  BAM and a 200 k-spectrum mzML (peak RSS below 2 GB with default
  policy, measured with `resource.getrusage`).
- Exporters: SAM 11-column, FASTQ triple and mzML array digests equal
  the input's (the comparators from the benchmark suite's `verify.py`).
- Codec-efficiency check on the chr22 audit corpora: `blocks_v1`
  default vs `opt_legacy_whole_channel`, reported in the PR.
- Full Python suite + xlang matrix; the golden fixture committed.

## 11. Open questions

- Per-block bulk (verbatim blob) carriage on the transport wire; today
  a multi-block run is sent per-AU.
- The FQZCOMP_NX16_Z zero-length-read decode failure is a kernel bug
  shared by all three languages; once fixed the RANS_ORDER0 fallback
  can go.

- Whether `cigars` should stay rANS per block or move into a
  mate_info-style inline stream is not decided here; per block with
  the existing codec is the conservative choice.
- Vendor importers (Thermo/Bruker/Waters) stream at whatever
  granularity their underlying reader exposes; if one only offers a
  whole-file API, the plan records it as a known limit rather than
  buffering the whole file.
