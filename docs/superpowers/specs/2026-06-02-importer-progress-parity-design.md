# ReferenceImport embed-progress parity (Python + ObjC) — Design

Date: 2026-06-02
Status: Approved (brainstorm), pending implementation plan
Scope owner: cross-language SDK parity

## Background

The three Java importers carry "future cross-language parity PR" TODOs about
progress reporting:

- `java/.../importers/FastaReader.java:44-47`
- `java/.../importers/FastqReader.java:39-43`
- `java/.../importers/BamReader.java:60-64`

A cross-language audit of the progress-sink ("progress sink") surface found
these TODOs are **largely stale**. The reader sinks they say Python/ObjC
"should grow" — `readUnaligned`, `fastq read`, `bam read` — **already exist in
all three languages** with identical `PROGRESS_INTERVAL_READS = 1000`
semantics:

- Python: `read_unaligned` (`importers/fasta.py:168`), `FastqReader.read`
  (`importers/fastq.py:143`), `BamReader.to_genomic_run`
  (`importers/bam.py:145`) — all take `progress: ProgressSinkLike | None = None`.
- ObjC: `+readUnalignedFromPath:…progress:error:` (`TTIOFastaReader.h:99`),
  `+readFromPath:…progress:error:` (`TTIOFastqReader.h:98`),
  `-toGenomicRunWithName:…progress:error:` (`TTIOBamReader.h:118`).

### The one genuine remaining gap

The per-contig progress sink on the reference **embed** path,
`ReferenceImport.writeToDataset`, is **Java-only**:

- Java: `writeToDataset(SpectralDataset, boolean overwrite, ProgressSink progress)`
  at `genomics/ReferenceImport.java:300` (`@since 1.3.0`). Fires
  `onProgress(0, total)` then per-chromosome `onProgress(doneCount, total)`
  (`:351`, `:388`). The 2-arg overload delegates via `ProgressSink.discard()`.
- Python: `write_to_dataset(self, dataset, *, overwrite=False)` at
  `genomic/reference_import.py:213` — **no `progress` parameter**. The write
  loop is `for name in sorted(self.chromosomes)` (`:298`).
- ObjC: `-writeToDataset:overwrite:error:` at `TTIOReferenceImport.h:152` —
  **no `progress` overload**.

`readReference` (reference *parsing*) has no sink in any language — by design,
out of scope.

## Goals

1. Close the real parity gap: add per-contig embed progress to Python
   `write_to_dataset` and ObjC `writeToDataset`, matching Java's emission
   semantics exactly.
2. Delete the three stale Java importer TODOs.
3. Close the minor test gap: add an ObjC test for the existing
   `TTIOBamReader …progress:` reader API (Java + Python already test it).

Non-goals: any change to `readReference`; any wire/on-disk format change;
any change to the already-shipped reader sinks.

## Design

### API shape (follows each language's existing sink convention)

- **Python** (`genomic/reference_import.py`): extend the existing method with a
  keyword-only parameter —
  `write_to_dataset(self, dataset, *, overwrite=False, progress: ProgressSinkLike | None = None)`.
  Mirrors how the reader sinks were added. `progress=None` is a no-op via the
  existing `ttio.io.progress._fire()` dispatcher. `ProgressSinkLike` /
  `_fire` import from `ttio.io.progress`.
- **ObjC** (`TTIOReferenceImport.{h,m}`): add a new overload
  `-writeToDataset:overwrite:progress:error:` alongside the existing
  `-writeToDataset:overwrite:error:`, which delegates to the new method with
  `TTIOProgressDiscard()`. `TTIOProgressBlock` from `Core/TTIOProgressSink.h`.

No change to the public API of any other method. Both additions are
backward-compatible (new optional param / new overload).

### Emission semantics (must match Java exactly)

`total` = number of chromosomes/contigs embedded. Sequence:

1. `onProgress(0, total)` once, before the embed loop.
2. After embedding contig *i* (0-indexed), `onProgress(i + 1, total)`.

The loop ends naturally at `onProgress(total, total)`. Because `done` is a pure
count, contig ordering does not affect the sequence, so all three languages
emit the identical `[(0,N), (1,N), …, (N,N)]` (N+1 callbacks). Progress is a
runtime callback only — nothing is serialized, so there is no wire/byte
contract, only a behavioral one.

### Tests

Per-language unit tests, matching the existing `*_progress` test style; no
cross-language byte harness (progress is not serialized).

- **Python**: new `python/tests/test_reference_import_progress.py` — assert the
  callback receives `(0, N)` first and `(N, N)` last with monotonic
  non-decreasing `done`; assert the count of callbacks is `N + 1`; include a
  `progress=None` safety case and (matching `test_fastq_progress.py`) both a
  bare-callable and an `on_progress` Protocol-object sink.
- **ObjC**: extend the progress test suite (`Tests/TestProgressSink*.m`) with a
  `writeToDataset:overwrite:progress:` case asserting the same sequence, plus
  the **missing** `TTIOBamReader …progress:` reader-progress case (samtools-gated
  via the existing skip pattern).
- **Java**: already covered (`FastaReaderProgressTest` exercises the
  `ReferenceImport.writeToDataset(..., sink)` path). No new Java test required.

### Cleanup

Delete the three stale Java TODO comments
(`FastaReader.java:44-47`, `FastqReader.java:39-43`, `BamReader.java:60-64`).
The reader-sink parity they describe already shipped, and once Python/ObjC
`writeToDataset` gains progress the FASTA TODO's `ReferenceImport`-parity note
is satisfied — so deletion (not rewrite) is correct.

### Versioning

The new Python/ObjC API is tagged `@since`/docstring version **v1.6.4** (the
next patch release). Additive, backward-compatible.

## Delivery

A single atomic PR: Python change + ObjC change + ObjC BAM-reader test + Java
TODO deletions + `CHANGELOG.md [Unreleased]` entry. Parity changes land
together. The "Cross-language parity (ObjC ⇄ Python ⇄ Java)" CI job exercises
it. Build/verify in WSL (`TTIO_RANS_LIB_PATH` set for Python; `JAVA_HOME=~/jdk25`
for Java; `objc/build.sh check` for ObjC), push from Windows git per the
established workflow.

## Risks / notes

- ObjC BAM reader-progress test is samtools-gated (Python/ObjC BAM readers
  shell out to samtools); use the existing `assumeTrue`/skip pattern so the
  test is a no-op when samtools is absent.
- Confirm Java's exact first/last emission during implementation (read
  `ReferenceImport.java:340-390`) so Python/ObjC match the `(0,N)…(N,N)`
  boundary callbacks precisely, including the empty-reference (`N == 0`) case.
