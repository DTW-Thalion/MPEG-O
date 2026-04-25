# HANDOFF — M82: GenomicRun + AlignedRead + Signal Channel Layout

**Scope:** Full three-language implementation of the genomic data model:
`GenomicRun`, `AlignedRead`, `GenomicIndex`, and the genomic signal
channel layout. This is the genomic analogue of M4 (AcquisitionRun +
SpectrumIndex). Python is the reference; ObjC (normative) and Java
ship in the same milestone to maintain language parity.

**Branch from:** `main` after M81.

**Depends on:** M79 enums (UINT8, Compression 4–8, AcquisitionMode 7–8,
spectrum_class=5, @modality attribute).

---

## 1. Architecture — How Genomics Parallels Mass Spectrometry

The existing mass-spec pipeline is:

```
SpectralDataset
  └── /study/ms_runs/<name>/
        ├── @acquisition_mode, @modality, @spectrum_class, ...
        ├── spectrum_index/        (SpectrumIndex: offsets, lengths, RTs, ...)
        ├── signal_channels/       (mz_values, intensity_values)
        ├── instrument_config/
        ├── chromatograms/
        └── provenance/
```

The genomic pipeline mirrors this exactly:

```
SpectralDataset
  └── /study/genomic_runs/<name>/
        ├── @acquisition_mode = 7 (GENOMIC_WGS) or 8 (GENOMIC_WES)
        ├── @modality = "genomic_sequencing"
        ├── @spectrum_class = 5
        ├── @reference_uri = "GRCh38.p14"
        ├── @platform = "ILLUMINA"
        ├── @sample_name = "NA12878"
        ├── @read_count = 10000 (uint64)
        ├── genomic_index/         (GenomicIndex: offsets, lengths, chroms, ...)
        ├── signal_channels/
        │     ├── positions        (INT64, one per read)
        │     ├── sequences        (UINT8, packed bases, concatenated)
        │     ├── qualities        (UINT8, Phred scores, concatenated)
        │     ├── flags            (UINT32, one per read — uint16 is too
        │     │                     narrow for future extended flags)
        │     ├── mapping_qualities (UINT8, one per read)
        │     ├── cigars           (compound VL_BYTES, one row per read)
        │     ├── read_names       (compound VL_BYTES, one row per read)
        │     └── mate_info        (compound: chrom VL_BYTES, pos INT64,
        │                           tlen INT32 — one row per read)
        └── provenance/
```

Key design decisions:

- `genomic_runs` is a **separate group** from `ms_runs`, not
  interleaved. This lets `SpectralDataset.open()` dispatch cleanly
  and avoids confusing ms_runs iterators.
- Signal channels use the same `signal_channels/` group name and the
  same StorageDataset contract (chunked, typed, compressed). The only
  new thing is UINT8 precision and compound VL_BYTES for variable-
  length per-read data (cigars, read_names, mate_info).
- GenomicIndex is the genomic SpectrumIndex: parallel arrays for
  per-read metadata that's cheap to scan without loading signal data.
- `@spectrum_class = 5` means the transport layer (M82 deferred)
  knows how to interpret the AU payload.

---

## 2. New Files

### 2.1 `python/src/ttio/aligned_read.py`

```python
@dataclass(frozen=True, slots=True)
class AlignedRead:
    """One aligned sequencing read — the genomic analogue of Spectrum."""

    read_name: str
    chromosome: str           # reference sequence name (e.g., "chr1")
    position: int             # 0-based mapping position
    mapping_quality: int      # 0–255
    cigar: str                # CIGAR string (e.g., "150M")
    sequence: str             # base sequence (ACGTN...)
    qualities: bytes          # Phred quality scores (raw bytes)
    flags: int                # SAM flags (uint16 on disk, uint32 in memory)
    mate_chromosome: str      # "" if unpaired
    mate_position: int        # -1 if unpaired
    template_length: int      # 0 if unpaired
    tags: dict[str, object] | None = None  # optional SAM tags (deferred)

    @property
    def is_mapped(self) -> bool:
        return not (self.flags & 0x4)

    @property
    def is_paired(self) -> bool:
        return bool(self.flags & 0x1)

    @property
    def is_reverse(self) -> bool:
        return bool(self.flags & 0x10)

    @property
    def is_secondary(self) -> bool:
        return bool(self.flags & 0x100)

    @property
    def is_supplementary(self) -> bool:
        return bool(self.flags & 0x800)

    @property
    def read_length(self) -> int:
        return len(self.sequence)
```

No HDF5 I/O on this class directly — it's a value object materialised
by `GenomicRun.__getitem__()` from the signal channel arrays, same
pattern as `MassSpectrum` being materialised by `AcquisitionRun`.

### 2.2 `python/src/ttio/genomic_index.py`

Parallel arrays loaded eagerly when a GenomicRun is opened.
Analogous to `SpectrumIndex` but with genomic filter keys.

```python
@dataclass(slots=True)
class GenomicIndex:
    """Per-read metadata for selective access.

    All arrays have length == read_count. They are small (one value
    per read) and held in memory for fast scanning.
    """

    offsets: np.ndarray          # uint64 — byte offset into sequence channel
    lengths: np.ndarray          # uint32 — read length (bases)
    chromosomes: list[str]       # one per read (string, not array)
    positions: np.ndarray        # int64 — 0-based mapping position
    mapping_qualities: np.ndarray  # uint8
    flags: np.ndarray            # uint32

    @property
    def count(self) -> int:
        return len(self.offsets)

    def indices_for_region(
        self, chromosome: str, start: int, end: int
    ) -> list[int]:
        """Return read indices within [start, end) on chromosome."""
        mask = np.array(
            [c == chromosome for c in self.chromosomes], dtype=bool
        )
        mask &= self.positions >= start
        mask &= self.positions < end
        return np.where(mask)[0].tolist()

    def indices_for_unmapped(self) -> list[int]:
        """Return indices of unmapped reads (flag & 0x4)."""
        return np.where(self.flags & 0x4)[0].tolist()

    def indices_for_flag(self, flag_mask: int) -> list[int]:
        """Return indices where (flags & flag_mask) != 0."""
        return np.where(self.flags & flag_mask)[0].tolist()

    @classmethod
    def read(cls, idx_group: StorageGroup) -> "GenomicIndex":
        """Load from a ``genomic_index/`` StorageGroup."""
        ...

    def write(self, idx_group: StorageGroup) -> None:
        """Write all columns into ``idx_group``."""
        ...
```

### 2.3 `python/src/ttio/genomic_run.py`

```python
@dataclass(slots=True)
class GenomicRun:
    """Lazy view over one ``/study/genomic_runs/<n>/`` group.

    Analogous to AcquisitionRun. Signal channels are loaded on demand;
    the GenomicIndex is loaded eagerly at open time.
    """

    name: str
    acquisition_mode: AcquisitionMode   # GENOMIC_WGS or GENOMIC_WES
    modality: str                       # always "genomic_sequencing"
    reference_uri: str                  # e.g., "GRCh38.p14"
    platform: str                       # e.g., "ILLUMINA"
    sample_name: str
    index: GenomicIndex
    group: StorageGroup                 # kept open for lazy channel access
    channel_names: list[str]            # e.g., ["positions", "sequences", ...]

    # Internal lazy caches
    _signal_cache: dict[str, StorageDataset] = field(default_factory=dict)

    def __len__(self) -> int:
        return self.index.count

    def __getitem__(self, i: int) -> AlignedRead:
        """Materialise read ``i`` from signal channels."""
        ...

    def __iter__(self) -> Iterator[AlignedRead]:
        for i in range(len(self)):
            yield self[i]

    def reads_in_region(
        self, chromosome: str, start: int, end: int
    ) -> list[AlignedRead]:
        """Return reads overlapping [start, end) on chromosome."""
        indices = self.index.indices_for_region(chromosome, start, end)
        return [self[i] for i in indices]

    @classmethod
    def open(cls, parent_group: StorageGroup, name: str) -> "GenomicRun":
        """Open an existing genomic run group."""
        ...

    # No write() on GenomicRun — writing goes through WrittenGenomicRun
    # (same pattern as WrittenRun / SpectralDataset.write_minimal).
```

### 2.4 `python/src/ttio/written_genomic_run.py`

Simple container for the write path, analogous to `WrittenRun`:

```python
@dataclass(slots=True)
class WrittenGenomicRun:
    """Data container for writing a genomic run via SpectralDataset."""

    acquisition_mode: int           # AcquisitionMode.GENOMIC_WGS or WES
    reference_uri: str
    platform: str
    sample_name: str
    # Per-read parallel arrays (all length == read_count):
    positions: np.ndarray           # int64
    mapping_qualities: np.ndarray   # uint8
    flags: np.ndarray               # uint32
    # Concatenated signal data:
    sequences: np.ndarray           # uint8 (raw bytes, one base per byte
                                    #   for M82; base-packing deferred to
                                    #   codec milestone)
    qualities: np.ndarray           # uint8 (Phred scores, concatenated)
    # Per-read offsets into sequences/qualities:
    offsets: np.ndarray             # uint64
    lengths: np.ndarray             # uint32 (read lengths)
    # Per-read variable-length fields:
    cigars: list[str]               # one CIGAR string per read
    read_names: list[str]           # one read name per read
    # Mate info (per-read):
    mate_chromosomes: list[str]
    mate_positions: np.ndarray      # int64 (-1 if unpaired)
    template_lengths: np.ndarray    # int32 (0 if unpaired)
    # Chromosomes (per-read, for the index):
    chromosomes: list[str]
    # Optional:
    provenance_records: list = field(default_factory=list)
    signal_compression: str = "gzip"  # "gzip" for M82; rANS in codec milestone
```

---

## 3. SpectralDataset Extensions

### 3.1 `write_minimal()` — add `genomic_runs` parameter

```python
@classmethod
def write_minimal(
    cls,
    path, title, isa_investigation_id,
    runs=None,                    # existing: dict[str, WrittenRun]
    genomic_runs=None,            # NEW: dict[str, WrittenGenomicRun]
    identifications=None,
    quantifications=None,
    provenance=None,
    features=None,
    provider="hdf5",
) -> Path:
```

When `genomic_runs` is non-empty:
- Add `"opt_genomic"` to the feature flag list.
- Create `/study/genomic_runs/` group.
- Write `@_run_names` CSV attribute (same pattern as `ms_runs`).
- For each `WrittenGenomicRun`, call `_write_genomic_run()`.

### 3.2 `_write_genomic_run()` helper

Creates the group structure under `/study/genomic_runs/<name>/`:

```python
def _write_genomic_run(
    parent: StorageGroup, name: str, run: WrittenGenomicRun
) -> None:
    rg = parent.create_group(name)

    # Run-level attributes
    rg.set_attribute("acquisition_mode", run.acquisition_mode)
    rg.set_attribute("modality", "genomic_sequencing")
    rg.set_attribute("spectrum_class", 5)
    rg.set_attribute("reference_uri", run.reference_uri)
    rg.set_attribute("platform", run.platform)
    rg.set_attribute("sample_name", run.sample_name)
    rg.set_attribute("read_count", len(run.offsets))

    # Genomic index
    idx = rg.create_group("genomic_index")
    _write_uint64_dataset(idx, "offsets", run.offsets)
    _write_uint32_dataset(idx, "lengths", run.lengths)
    _write_int64_dataset(idx, "positions", run.positions)
    _write_uint8_dataset(idx, "mapping_qualities", run.mapping_qualities)
    _write_uint32_dataset(idx, "flags", run.flags)
    io.write_compound_dataset(idx, "chromosomes",
        [{"value": c} for c in run.chromosomes],
        [("value", "vlen_str")])

    # Signal channels
    sc = rg.create_group("signal_channels")
    _write_int64_channel(sc, "positions", run.positions, run.signal_compression)
    _write_uint8_channel(sc, "sequences", run.sequences, run.signal_compression)
    _write_uint8_channel(sc, "qualities", run.qualities, run.signal_compression)
    _write_uint32_channel(sc, "flags", run.flags, run.signal_compression)
    _write_uint8_channel(sc, "mapping_qualities",
                         run.mapping_qualities, run.signal_compression)
    io.write_compound_dataset(sc, "cigars",
        [{"value": c.encode("utf-8")} for c in run.cigars],
        [("value", "vlen_bytes")])
    io.write_compound_dataset(sc, "read_names",
        [{"value": n.encode("utf-8")} for n in run.read_names],
        [("value", "vlen_bytes")])
    io.write_compound_dataset(sc, "mate_info",
        [{"chrom": mc.encode("utf-8"),
          "pos": int(mp),
          "tlen": int(tl)}
         for mc, mp, tl in zip(run.mate_chromosomes,
                               run.mate_positions,
                               run.template_lengths)],
        [("chrom", "vlen_bytes"), ("pos", "int64"), ("tlen", "int32")])

    # Provenance
    if run.provenance_records:
        _write_provenance_to_group(rg, run.provenance_records)
```

### 3.3 `open()` — read `genomic_runs` alongside `ms_runs`

In `SpectralDataset.open()`, after reading `ms_runs`:

```python
self._genomic_runs: dict[str, GenomicRun] = {}
if study.has_child("genomic_runs"):
    gr_group = study.open_group("genomic_runs")
    names_csv = io.read_string_attr(gr_group, "_run_names") or ""
    for rn in names_csv.split(","):
        rn = rn.strip()
        if rn and gr_group.has_child(rn):
            self._genomic_runs[rn] = GenomicRun.open(gr_group, rn)
```

New property:

```python
@property
def genomic_runs(self) -> dict[str, GenomicRun]:
    return self._genomic_runs
```

Files without `genomic_runs/` group → empty dict (backward compat
with pre-M82 files).

---

## 4. Signal Channel I/O Helpers

For M82, genomic channels use standard zlib compression via the
existing `create_dataset` + `write` path. The rANS / base-pack /
quality-quantiser codecs are deferred to the codec milestone.

Needed helper functions in `_hdf5_io.py` (or a new
`_genomic_io.py` if cleaner):

```python
def _write_uint8_channel(
    group: StorageGroup, name: str, data: np.ndarray, compression: str
) -> None:
    """Write a UINT8 signal channel as a chunked dataset."""
    ds = group.create_dataset(name, Precision.UINT8, length=len(data),
                              chunk_size=65536,
                              compression=Compression.ZLIB if compression == "gzip"
                              else Compression.NONE,
                              compression_level=6)
    ds.write(data)

def _write_uint32_channel(
    group: StorageGroup, name: str, data: np.ndarray, compression: str
) -> None:
    ds = group.create_dataset(name, Precision.UINT32, length=len(data),
                              chunk_size=65536,
                              compression=Compression.ZLIB if compression == "gzip"
                              else Compression.NONE,
                              compression_level=6)
    ds.write(data)

def _write_int64_channel(
    group: StorageGroup, name: str, data: np.ndarray, compression: str
) -> None:
    ds = group.create_dataset(name, Precision.INT64, length=len(data),
                              chunk_size=65536,
                              compression=Compression.ZLIB if compression == "gzip"
                              else Compression.NONE,
                              compression_level=6)
    ds.write(data)
```

---

## 5. Read Path — `GenomicRun.__getitem__()`

Materialising an AlignedRead from signal channels:

```python
def __getitem__(self, i: int) -> AlignedRead:
    if i < 0:
        i += len(self)
    if not 0 <= i < len(self):
        raise IndexError(f"read index {i} out of range [0, {len(self)})")

    offset = int(self.index.offsets[i])
    length = int(self.index.lengths[i])

    # Flat channels (one value per read):
    position = int(self.index.positions[i])
    mapq = int(self.index.mapping_qualities[i])
    flag = int(self.index.flags[i])
    chrom = self.index.chromosomes[i]

    # Sequence channel: contiguous bytes [offset:offset+length]
    seq_ds = self._signal_dataset("sequences")
    seq_bytes = seq_ds.read_slice(offset, offset + length)
    sequence = "".join(chr(b) for b in seq_bytes)
    # (M82 stores one ASCII byte per base; base-packing deferred to
    #  codec milestone)

    # Quality channel: same offset/length
    qual_ds = self._signal_dataset("qualities")
    qualities = bytes(qual_ds.read_slice(offset, offset + length))

    # Compound channels (one row per read):
    sig_group = self.group.open_group("signal_channels")
    cigars = io.read_compound_dataset(sig_group, "cigars")
    cigar = cigars[i]["value"]
    if isinstance(cigar, bytes):
        cigar = cigar.decode("utf-8")

    names = io.read_compound_dataset(sig_group, "read_names")
    read_name = names[i]["value"]
    if isinstance(read_name, bytes):
        read_name = read_name.decode("utf-8")

    mates = io.read_compound_dataset(sig_group, "mate_info")
    mate = mates[i]
    mate_chrom = mate["chrom"]
    if isinstance(mate_chrom, bytes):
        mate_chrom = mate_chrom.decode("utf-8")

    return AlignedRead(
        read_name=read_name,
        chromosome=chrom,
        position=position,
        mapping_quality=mapq,
        cigar=cigar,
        sequence=sequence,
        qualities=qualities,
        flags=flag,
        mate_chromosome=mate_chrom,
        mate_position=int(mate["pos"]),
        template_length=int(mate["tlen"]),
    )
```

**Performance note:** The compound dataset reads (`cigars`,
`read_names`, `mate_info`) load the entire compound dataset on
every `__getitem__` call. This is the same pattern as
`AcquisitionRun` for now. Cache them on first access:

```python
def _load_compound_cache(self, name: str) -> list[dict]:
    if name not in self._compound_cache:
        sig = self.group.open_group("signal_channels")
        self._compound_cache[name] = io.read_compound_dataset(sig, name)
    return self._compound_cache[name]
```

---

## 6. Tests — `python/tests/test_m82_genomic_run.py`

### Helper: synthetic read generator

```python
def _make_genomic_run(
    n_reads: int = 100,
    read_length: int = 150,
    chromosomes: list[str] | None = None,
) -> WrittenGenomicRun:
    """Build a synthetic genomic run with realistic structure."""
    if chromosomes is None:
        chromosomes = ["chr1", "chr2", "chrX"]
    rng = np.random.default_rng(42)
    ...
```

### Test cases

1. **Basic round-trip (100 reads).**
   Write a WrittenGenomicRun with 100 reads across 3 chromosomes.
   Open via SpectralDataset. Access genomic_runs["run_0001"].
   Assert len == 100. Materialise reads 0, 50, 99. Verify all
   fields (position, cigar, sequence, qualities, flags, mate info,
   read name) match input.

2. **Region query.**
   Query "chr1:10000-20000". Verify only reads with chromosome ==
   "chr1" and position in [10000, 20000) are returned.

3. **Flag-based filter.**
   Query unmapped reads (flag & 0x4). Verify correct subset.
   Query reverse-strand reads (flag & 0x10). Verify correct subset.

4. **Paired-end reads.**
   100 paired reads with mate info populated. Materialise read 0.
   Verify mate_chromosome, mate_position, template_length.

5. **Large run (10,000 reads).**
   Write 10K reads, reopen, iterate all, verify count and spot-check
   reads 0, 5000, 9999.

6. **Empty run (0 reads).**
   Write/read an empty GenomicRun. Assert len == 0. Iterate yields
   nothing. region query returns [].

7. **Multi-provider round-trip.**
   Repeat test 1 on Memory and SQLite providers (compound VL_BYTES
   support required).

8. **Multi-omics file.**
   Write a file with one ms_run (5 spectra) AND one genomic_run
   (100 reads). Open via SpectralDataset. Assert ms_runs has
   "run_0001", genomic_runs has "genomic_0001". Access spectra
   from the MS run — correct. Access reads from the genomic run
   — correct. No cross-contamination.

9. **Feature flag.**
   File with genomic_runs → `"opt_genomic"` present in
   feature_flags.features. File without → absent.

10. **Backward compat.**
    Open a pre-M82 file (no genomic_runs group). Assert
    `ds.genomic_runs` is empty dict. No error.

11. **Streaming iteration.**
    Iterate through 1000 reads via `for read in genomic_run:`.
    Assert correct order (by read index) and correct count.

12. **Random-access read.**
    Write 1000 reads. Read only read 500 via `genomic_run[500]`.
    Verify fields match. Confirm sequences channel was accessed
    via hyperslab (offset/length), not full-dataset read.

---

## 7. Module Registration

### 7.1 `python/src/ttio/__init__.py`

Add imports:

```python
from .aligned_read import AlignedRead
from .genomic_index import GenomicIndex
from .genomic_run import GenomicRun
from .written_genomic_run import WrittenGenomicRun
```

Add to `__all__`.

### 7.2 `python/src/ttio/spectral_dataset.py`

Import `WrittenGenomicRun`, `GenomicRun`, `GenomicIndex`.

---

## 8. Objective-C Implementation (Normative)

### 8.1 New Files under `objc/Source/Genomics/`

Create the `Genomics/` subdirectory. Add to GNUmakefile's source list.

**`TTIOAlignedRead.h` / `.m`**

```objc
@interface TTIOAlignedRead : NSObject <NSCopying>

@property (nonatomic, readonly, copy)   NSString *readName;
@property (nonatomic, readonly, copy)   NSString *chromosome;
@property (nonatomic, readonly)         int64_t position;
@property (nonatomic, readonly)         uint8_t mappingQuality;
@property (nonatomic, readonly, copy)   NSString *cigar;
@property (nonatomic, readonly, copy)   NSString *sequence;
@property (nonatomic, readonly, copy)   NSData *qualities;
@property (nonatomic, readonly)         uint32_t flags;
@property (nonatomic, readonly, copy)   NSString *mateChromosome;
@property (nonatomic, readonly)         int64_t matePosition;
@property (nonatomic, readonly)         int32_t templateLength;

// Convenience flag accessors
- (BOOL)isMapped;
- (BOOL)isPaired;
- (BOOL)isReverse;
- (BOOL)isSecondary;
- (BOOL)isSupplementary;
- (NSUInteger)readLength;

- (instancetype)initWithReadName:(NSString *)readName
                      chromosome:(NSString *)chromosome
                        position:(int64_t)position
                  mappingQuality:(uint8_t)mappingQuality
                           cigar:(NSString *)cigar
                        sequence:(NSString *)sequence
                       qualities:(NSData *)qualities
                           flags:(uint32_t)flags
                  mateChromosome:(NSString *)mateChromosome
                    matePosition:(int64_t)matePosition
                  templateLength:(int32_t)templateLength;
@end
```

Value object — no HDF5 I/O. Materialised by `TTIOGenomicRun` from
signal channels. Follows `TTIOMassSpectrum` pattern: immutable,
`NSCopying`, overridden `-isEqual:` / `-hash`.

**`TTIOGenomicIndex.h` / `.m`**

```objc
@interface TTIOGenomicIndex : NSObject

@property (nonatomic, readonly) NSUInteger count;

// Parallel arrays (length == count)
@property (nonatomic, readonly) uint64_t *offsets;
@property (nonatomic, readonly) uint32_t *lengths;
@property (nonatomic, readonly, copy) NSArray<NSString *> *chromosomes;
@property (nonatomic, readonly) int64_t *positions;
@property (nonatomic, readonly) uint8_t *mappingQualities;
@property (nonatomic, readonly) uint32_t *flags;

- (NSArray<NSNumber *> *)indicesForRegion:(NSString *)chromosome
                                   start:(int64_t)start
                                     end:(int64_t)end;

- (NSArray<NSNumber *> *)indicesForUnmapped;

- (NSArray<NSNumber *> *)indicesForFlag:(uint32_t)flagMask;

// I/O
+ (nullable instancetype)readFromGroup:(id<TTIOStorageGroup>)group
                                 error:(NSError **)error;

- (BOOL)writeToGroup:(id<TTIOStorageGroup>)group
               error:(NSError **)error;
@end
```

Uses `TTIOStorageProtocols` (`TTIOStorageGroup` / `TTIOStorageDataset`)
for provider-agnostic I/O — same pattern as `TTIOSpectrumIndex`.

**`TTIOGenomicRun.h` / `.m`**

```objc
@interface TTIOGenomicRun : NSObject <TTIOIndexable, TTIOStreamable>

@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) TTIOAcquisitionMode acquisitionMode;
@property (nonatomic, readonly, copy) NSString *modality;
@property (nonatomic, readonly, copy) NSString *referenceUri;
@property (nonatomic, readonly, copy) NSString *platform;
@property (nonatomic, readonly, copy) NSString *sampleName;
@property (nonatomic, readonly, strong) TTIOGenomicIndex *index;

- (NSUInteger)readCount;

// Random access
- (nullable TTIOAlignedRead *)readAtIndex:(NSUInteger)idx
                                    error:(NSError **)error;

// Region query
- (NSArray<TTIOAlignedRead *> *)readsInRegion:(NSString *)chromosome
                                        start:(int64_t)start
                                          end:(int64_t)end;

// Open from existing group
+ (nullable instancetype)openFromGroup:(id<TTIOStorageGroup>)parentGroup
                                  name:(NSString *)name
                                 error:(NSError **)error;
@end
```

Internally holds a reference to the open `TTIOStorageGroup` for lazy
signal channel access. Materialises `TTIOAlignedRead` objects on
demand from signal datasets, caching compound datasets (cigars,
read_names, mate_info) after first load.

### 8.2 `TTIOSpectralDataset` Extensions

In `TTIOSpectralDataset.h` / `.m`:

- New property: `@property (nonatomic, readonly) NSDictionary<NSString *, TTIOGenomicRun *> *genomicRuns;`
- `+openAtPath:error:` reads `genomic_runs/` group alongside `ms_runs/`.
  Missing group → empty dictionary.
- `+createAtPath:...genomicRuns:...error:` accepts an `NSDictionary`
  of genomic run write data (or `nil`). Writes `genomic_runs/` group
  with `@_run_names`, signal channels, and genomic index per run.
  Adds `"opt_genomic"` to feature flags.

### 8.3 Write-side Data

For the ObjC write path, define a simple container struct or class
for the write data (equivalent to `WrittenGenomicRun`):

```objc
@interface TTIOWrittenGenomicRun : NSObject

@property (nonatomic) TTIOAcquisitionMode acquisitionMode;
@property (nonatomic, copy) NSString *referenceUri;
@property (nonatomic, copy) NSString *platform;
@property (nonatomic, copy) NSString *sampleName;

// Parallel arrays (all length == readCount)
@property (nonatomic) int64_t *positions;
@property (nonatomic) uint8_t *mappingQualities;
@property (nonatomic) uint32_t *flags;
@property (nonatomic) uint64_t *offsets;
@property (nonatomic) uint32_t *lengths;
@property (nonatomic, copy) NSArray<NSString *> *chromosomes;

// Concatenated signal buffers
@property (nonatomic) uint8_t *sequences;
@property (nonatomic) NSUInteger sequencesLength;
@property (nonatomic) uint8_t *qualities;
@property (nonatomic) NSUInteger qualitiesLength;

// Per-read variable-length fields
@property (nonatomic, copy) NSArray<NSString *> *cigars;
@property (nonatomic, copy) NSArray<NSString *> *readNames;
@property (nonatomic, copy) NSArray<NSString *> *mateChromosomes;
@property (nonatomic) int64_t *matePositions;
@property (nonatomic) int32_t *templateLengths;

@property (nonatomic) NSUInteger readCount;

@end
```

### 8.4 ObjC Tests — `objc/Tests/TestM82GenomicRun.m`

Register in `TTIOTestRunner.m` under `M82: GenomicRun + genomic
data model`. Minimum assertions:

1. 100-read round-trip via HDF5Provider. All fields correct.
2. 100-read round-trip via MemoryProvider.
3. Region query "chr1:10000-20000" returns correct subset.
4. Unmapped read filter correct.
5. Paired-end mate info round-trip.
6. Multi-omics file (1 ms_run + 1 genomic_run), both readable.
7. Empty genomic run round-trip.
8. Pre-M82 file opens with empty genomicRuns dictionary.
9. Random-access read of specific index.

Target: ≥ 40 new assertions.

---

## 9. Java Implementation

### 9.1 New Files under `java/src/main/java/global/thalion/ttio/genomics/`

Create the `genomics/` subpackage.

**`AlignedRead.java`**

```java
public record AlignedRead(
    String readName,
    String chromosome,
    long position,
    int mappingQuality,
    String cigar,
    String sequence,
    byte[] qualities,
    int flags,
    String mateChromosome,
    long matePosition,
    int templateLength
) {
    public boolean isMapped()        { return (flags & 0x4) == 0; }
    public boolean isPaired()        { return (flags & 0x1) != 0; }
    public boolean isReverse()       { return (flags & 0x10) != 0; }
    public boolean isSecondary()     { return (flags & 0x100) != 0; }
    public boolean isSupplementary() { return (flags & 0x800) != 0; }
    public int readLength()          { return sequence.length(); }
}
```

Java `record` — immutable value type. Matches Python `AlignedRead`
and ObjC `TTIOAlignedRead`.

**`GenomicIndex.java`**

```java
public final class GenomicIndex {
    private final long[] offsets;
    private final int[] lengths;
    private final List<String> chromosomes;
    private final long[] positions;
    private final byte[] mappingQualities;
    private final int[] flags;

    public int count() { return offsets.length; }

    public List<Integer> indicesForRegion(
        String chromosome, long start, long end) { ... }

    public List<Integer> indicesForUnmapped() { ... }

    public List<Integer> indicesForFlag(int flagMask) { ... }

    public static GenomicIndex readFrom(StorageGroup group) { ... }

    public void writeTo(StorageGroup group) { ... }
}
```

Uses `StorageGroup` / `StorageDataset` for provider-agnostic I/O.

**`GenomicRun.java`**

```java
public class GenomicRun implements
        global.thalion.ttio.protocols.Indexable<AlignedRead>,
        global.thalion.ttio.protocols.Streamable<AlignedRead>,
        AutoCloseable {

    private final String name;
    private final AcquisitionMode acquisitionMode;
    private final String modality;
    private final String referenceUri;
    private final String platform;
    private final String sampleName;
    private final GenomicIndex index;
    private final StorageGroup group;

    public int readCount() { return index.count(); }

    public AlignedRead readAt(int i) { ... }

    public List<AlignedRead> readsInRegion(
        String chromosome, long start, long end) { ... }

    public static GenomicRun readFrom(
        StorageGroup parent, String name) { ... }
}
```

Implements `Indexable<AlignedRead>` and `Streamable<AlignedRead>`,
mirroring `AcquisitionRun`'s conformance to `Indexable<Spectrum>`
and `Streamable<Spectrum>`.

**`WrittenGenomicRun.java`**

Simple POJO container for the write path, mirroring
`WrittenGenomicRun` in Python and `TTIOWrittenGenomicRun` in ObjC.

### 9.2 `SpectralDataset` Extensions

In `SpectralDataset.java`:

- New field: `Map<String, GenomicRun> genomicRuns`.
- New getter: `public Map<String, GenomicRun> genomicRuns()`.
- `open()`: after reading `ms_runs`, read `genomic_runs/` if present.
  Missing → empty map.
- `create()`: accept `List<WrittenGenomicRun>` parameter (nullable).
  Write `genomic_runs/` group with signal channels and index. Add
  `"opt_genomic"` to feature flags.

### 9.3 Java Tests — `java/src/test/java/global/thalion/ttio/genomics/GenomicRunTest.java`

JUnit 5 tests. Same coverage as Python test cases 1–12:

1. `roundTrip100Reads` — HDF5 provider.
2. `regionQuery` — "chr1:10000-20000".
3. `flagFilter` — unmapped + reverse-strand.
4. `pairedEndMateInfo` — mate fields.
5. `largeRun10k` — spot-check reads 0, 5000, 9999.
6. `emptyRun` — zero reads.
7. `multiProviderMemory` — MemoryProvider.
8. `multiProviderSqlite` — SqliteProvider.
9. `multiOmicsFile` — ms_run + genomic_run coexistence.
10. `featureFlagOptGenomic` — present when genomic runs exist.
11. `backwardCompat` — pre-M82 file → empty genomicRuns map.
12. `randomAccess` — read index 500 only.

Target: ≥ 12 test methods, ≥ 50 assertions.

---

## 10. Cross-Language Conformance

### 10.1 Cross-language write/read matrix

Python writes a genomic .tio fixture containing 100 reads. ObjC and
Java read it. All fields match.

ObjC writes a genomic .tio fixture. Python and Java read it. All
fields match.

Java writes a genomic .tio fixture. Python and ObjC read it. All
fields match.

This is the 3×3 matrix (writer × reader). Add to the existing
cross-language integration test harness.

### 10.2 Cross-language test fixture

Generate a reference fixture `tests/fixtures/genomic/m82_100reads.tio`
from the Python test helper. This fixture is committed to the repo
and used by ObjC and Java read-side tests to validate without
needing to run the Python writer at test time.

### 10.3 Multi-omics cross-language

One fixture with 5 MS spectra + 100 genomic reads. Python writes →
ObjC reads both modalities → Java reads both modalities. All fields
match across all three languages.

---

## 11. Documentation

### 11.1 `docs/format-spec.md` §10

Replace the M79 stub with the full genomic container layout. Include:
- Group hierarchy diagram (as shown in §1 above)
- Signal channel table (name, precision, compression, description)
- GenomicIndex column definitions
- Attribute conventions (@reference_uri, @platform, @sample_name, etc.)
- Base encoding: M82 stores one ASCII byte per base (0x41='A',
  0x43='C', 0x47='G', 0x54='T', 0x4E='N'). Base-packing (2-bit
  encoding) deferred to codec milestone.

### 11.2 `CHANGELOG.md`

Add M82 entry under `[Unreleased]`.

### 11.3 `ARCHITECTURE.md`

Add GenomicRun, AlignedRead, GenomicIndex to the Layer 3 class table.
Add `genomic_runs` to the HDF5 layout diagram.

---

## 12. Gotchas

71. **Compound VL_BYTES on non-HDF5 providers.** The cigars,
    read_names, and mate_info channels use `io.write_compound_dataset`
    which writes HDF5 compound types with variable-length members.
    Memory and SQLite providers implement compound datasets via
    `write_rows` / `read_rows` — verify these work with `vlen_bytes`
    and `vlen_str` types. If the existing compound support doesn't
    handle VL bytes natively, add it (the existing Identification
    and Quantification compounds use VL strings, so the plumbing
    should already be there).

72. **Sequence encoding for M82.** M82 stores bases as raw ASCII
    bytes (one byte per base). This is deliberately wasteful — the
    base-packing codec (2 bits per base) arrives in the codec
    milestone. Do NOT implement base packing in M82. The UINT8
    signal channel infrastructure from M79 is the foundation;
    packing is a codec transform layered on top.

73. **Chromosome strings in GenomicIndex.** The `chromosomes` field
    is a `list[str]`, not a numpy array, because chromosome names
    are variable-length strings. For the HDF5 index, store as a
    compound VL_BYTES dataset with one column ("value"). On read,
    decode bytes → str. This is the same pattern used for
    `read_names` in the signal channels.

74. **flags channel width.** The HANDOFF specifies UINT32 for flags
    (not UINT16 as in SAM spec). This is deliberate — UINT32 gives
    room for future extended flags and the M79 enum already uses
    UINT32. The SAM flags (bits 0–11) fit in the low 16 bits; the
    upper 16 bits are reserved.

75. **Offset/length semantics.** In the mass-spec pipeline,
    `offsets[i]` is an element index into the mz/intensity arrays.
    In the genomic pipeline, `offsets[i]` is a byte index into the
    `sequences` and `qualities` arrays (since each base is one byte
    in M82). `lengths[i]` is the read length in bases. The contract
    is: `sequences[offsets[i] : offsets[i] + lengths[i]]` gives
    read i's bases.

76. **`read_slice` on UINT8 datasets.** Verify that the provider's
    `read_slice(start, stop)` returns a numpy `uint8` array (not
    float64). The HDF5 provider should handle this via the dtype
    mapping added in M79; Memory and SQLite providers need to
    preserve the dtype through the slice path.

77. **ObjC memory management for raw arrays.** `TTIOGenomicIndex`
    holds raw C arrays (`uint64_t *offsets`, `int64_t *positions`,
    etc.) allocated with `calloc`. The class must own and free them
    in `dealloc`. Use the same pattern as `TTIOSpectrumIndex` (which
    holds `double *retentionTimes`, etc.). Do NOT use `NSMutableData`
    wrappers — the overhead is not worth it for index arrays that
    are read once and held for the lifetime of the run.

78. **Java `byte[]` for UINT8 reads.** Java's `byte` is signed
    (-128..127). UINT8 Phred quality scores (0..41 typical, max 93)
    and flag bits fit in the positive range, but raw base ASCII values
    (A=65, C=67, G=71, T=84, N=78) are all positive and fine. When
    reading UINT8 datasets from HDF5, the provider returns `byte[]`.
    Convert to unsigned int with `b & 0xFF` when materialising
    `AlignedRead` fields. The M79 UINT8 round-trip tests already
    validate this for the providers.

79. **Java compound dataset read for cigars/read_names/mate_info.**
    Verify that `StorageGroup.readCompoundDataset()` (or equivalent)
    handles VL bytes fields correctly. The existing Identification
    and Quantification round-trips use VL string compounds, so the
    plumbing should be there — but genomic compounds have mixed types
    (mate_info has VL bytes + int64 + int32 in the same row). Test
    this explicitly.

80. **ObjC compound dataset with mixed types.** Same concern as
    gotcha 79. The `mate_info` compound has three columns with
    different types. Verify that the ObjC compound write/read paths
    handle mixed-type rows (the existing identification compound
    is all-string, so mixed types may be a new case).

81. **Cross-language fixture byte identity.** The 3×3 cross-language
    matrix tests field-level equality, not byte-level file identity.
    Different languages may use different HDF5 chunk sizes, compression
    levels, or attribute encoding. That's fine — the contract is
    semantic equivalence of the genomic data, not byte-identical files.

---

## Acceptance Criteria

### Python
- [ ] All existing tests pass (zero regressions).
- [ ] 100-read GenomicRun round-trips through HDF5 with all fields
      correct (position, cigar, sequence, qualities, flags, mate
      info, read name, chromosome).
- [ ] 10,000-read GenomicRun round-trips correctly.
- [ ] Region query "chr1:10000-20000" returns correct subset.
- [ ] Unmapped-read filter returns correct subset.
- [ ] Paired-end mate info round-trips correctly.
- [ ] Multi-omics file: one ms_run + one genomic_run in same .tio,
      both readable independently.
- [ ] `"opt_genomic"` feature flag present when genomic_runs exist.
- [ ] Pre-M82 files open without error; `genomic_runs` is empty dict.
- [ ] Memory and SQLite providers round-trip genomic data correctly.

### Objective-C
- [ ] All existing tests pass (zero regressions).
- [ ] 100-read TTIOGenomicRun round-trips through HDF5Provider.
- [ ] 100-read round-trip through MemoryProvider.
- [ ] Region query returns correct subset.
- [ ] Unmapped-read filter correct.
- [ ] Paired-end mate info round-trip.
- [ ] Multi-omics file readable (ms_runs + genomicRuns).
- [ ] Pre-M82 file → empty genomicRuns dictionary.
- [ ] ≥ 40 new assertions in TestM82GenomicRun.m.

### Java
- [ ] All existing tests pass (zero regressions).
- [ ] 100-read GenomicRun round-trips through Hdf5Provider.
- [ ] MemoryProvider and SqliteProvider round-trip.
- [ ] Region query returns correct subset.
- [ ] Multi-omics file readable.
- [ ] Pre-M82 file → empty genomicRuns map.
- [ ] ≥ 12 test methods, ≥ 50 assertions.

### Cross-Language
- [ ] Python-written genomic .tio readable by ObjC and Java.
- [ ] ObjC-written genomic .tio readable by Python and Java.
- [ ] Java-written genomic .tio readable by Python and ObjC.
- [ ] Multi-omics cross-language fixture (MS + genomic) readable
      by all three languages.
- [ ] Reference fixture `tests/fixtures/genomic/m82_100reads.tio`
      committed and used by ObjC + Java read tests.

### Documentation
- [ ] `docs/format-spec.md` §10 complete.
- [ ] `ARCHITECTURE.md` updated with genomic classes.
- [ ] `CHANGELOG.md` M82 entry.
- [ ] CI green across all three languages.

---

## Binding Decisions

| # | Decision | Rationale |
|---|---|---|
| 70 | Genomic runs live under `/study/genomic_runs/`, not interleaved with `/study/ms_runs/`. | Clean dispatch; avoids confusing mass-spec iterators with genomic data. ms_runs readers never see genomic groups. |
| 71 | M82 stores one ASCII byte per base (no packing). Base-packing deferred to codec milestone. | Separation of concerns: M82 validates the data model and I/O plumbing; compression optimisations are a separate milestone. |
| 72 | Flags stored as UINT32 (not UINT16). | Future-proofing for extended flag bits beyond SAM's 12-bit range. |
| 73 | GenomicIndex.chromosomes is `list[str]`, stored as compound VL_BYTES. | Variable-length strings don't fit in numpy typed arrays. Compound VL_BYTES is the established pattern for variable-length per-row data. |
| 74 | All three languages (Python, ObjC, Java) ship GenomicRun in the same milestone. No single-language-first deferral for data model classes. | Language parity is a core project principle. Deferring ObjC/Java creates integration debt and risks format divergence. Codecs (rANS, base-pack) may still land Python-first since they are algorithm implementations, but the data model and I/O contract must be synchronised. |
