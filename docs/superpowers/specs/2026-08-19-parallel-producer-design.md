# Parallel Producer Design

Date: 2026-08-19. Status: Phase 1 (ObjC) implemented; acceptance met
(50 GB HiFi in 5m 40s at 24 threads with 64 MiB blocks and a 20 GB
budget; 6m 02s on this 31 GB box's defaults, which the RAM clamp
bounds; identity proven serial = pipeline = shard).

## 1. Problem and measurements

The streaming importers are producer-bound. All parsing, batch
building and block assembly run on the caller's thread while the
block-parallel codec pool (v1.9) waits for blocks:

| configuration | input | wall | rate | peak RSS |
| --- | --- | --- | --- | --- |
| ObjC serial | 3.7 GB HiFi FASTQ | 154 s | 23.0 MB/s | - |
| ObjC 24 threads, v1.9 | 3.7 GB | 82 s | 43-45 MB/s | 21.8 GB |
| ObjC 24 threads, batch + pool fixes | 50 GB | 13m 12s | 60.3 MB/s | 4.3 GB |

(32-core box, `TTIO_THREADS` = cores - 8 = 24. The 21.8 GB peak was
the read-count batch policy and the missing per-record autorelease
draining, both fixed before this design; the 60.3 MB/s row is the
baseline this design starts from.)

24 threads deliver 1.6x over serial. Per-core codec rates put the
pool's aggregate capacity near 1 GB/s (FQZCOMP qualities, the slowest
codec, 30-50 MB/s per core; rANS sequences ~140 MB/s per core), so
the producer feeds the pool at about a twentieth of what it can eat.

Target: a 119 GB FASTQ encodes in well under one hour on CPU with the
default thread count; the acceptance number in section 8 corresponds
to about 15 minutes. GPU is not required and is not part of this
design.

## 2. Architecture

Four components slot in front of the existing stream writers. The
writers keep their role and their file format; nothing in this design
changes a byte of output.

* **InputSegmenter** — classifies the input. Seekable and
  uncompressed: shard mode. Anything else (gzip streams, pipes, the
  samtools BAM pipe): pipeline mode. The caller never chooses a mode;
  the segmenter does.
* **RecordScanner** — finds record boundaries inside a byte range of
  a plain FASTQ file (section 4).
* **ParserPool** — workers that turn raw byte slices into parsed
  record batches (names, packed sequence and quality buffers,
  offsets, lengths).
* **OrderedAssembler** — releases parsed batches to the writer
  strictly in file order, whatever order the workers finish in, under
  the byte budget of section 6.

## 3. The ordering invariant (byte identity)

blocks_v1 block boundaries are a deterministic function of the record
stream (reads and bytes accumulated per block). Every mode delivers
records to the writer in exact file order, so the block cuts, the
codec inputs and therefore the output file are byte for byte the
serial producer's. This is the same invariant the block-parallel
writers established in v1.9, extended to the producer: **serial,
pipeline and shard produce identical genomic bytes.** The tests of
section 8 enforce it directly.

## 4. Shard mode (plain FASTQ)

The file is split into T byte ranges (T = the resolved thread count).
Each scanner aligns its range start to the next record boundary and
parses to the first boundary at or after its range end, so every
record belongs to exactly one shard.

Boundary rule: a candidate is a `\n@` (or offset 0 starting with
`@`). Because `@` (Phred 31) legally appears anywhere in a quality
string, a candidate is confirmed only when the line two lines below
starts with `+`; the scanner walks forward candidate by candidate
until one confirms. Records are the 4-line unwrapped form, the only
form the readers accept today.

Workers emit batches tagged `(shard, sequence)`; the assembler
releases them in that order. A shard that runs far ahead parks its
batches against the byte budget, so shard skew costs memory only up
to the budget, never more.

BAM does not shard in ObjC: its records arrive through a sequential
samtools pipe, which is pipeline mode by definition.

## 5. Pipeline mode (gzip, pipes, BAM)

One reader thread does the sequential work that cannot be split:
reading or inflating bytes, and the cheap newline scan that slices
complete records out of the rolling buffer. It hands byte slices of
whole records (a batch-bytes worth at a time) to the ParserPool;
assembly is as in shard mode with a single shard. The reader thread's
scan runs at a few hundred MB/s, which bounds this mode at roughly
3-5x serial; that bound is why shard mode exists.

For BAM, the reader thread owns the samtools pipe and the line
slicing; the per-line SAM field parsing (today the dominant cost,
inside the sequential accumulator) moves to the pool: workers parse a
slice of complete SAM lines each into partial column arrays, and the
assembler concatenates them in order into batches.

## 6. Memory model

* **Batches are sized by bytes, not reads.** `batchBytes` (default
  64 MiB of decoded sequence + quality bytes) replaces read counts as
  the primary knob. `batchReads` stays as a compatibility override;
  when both are set, whichever limit is hit first cuts the batch.
  (Read-count batching was the 21.8 GB peak: 100 000 HiFi reads is
  3.7 GB per batch.)
* **One byte budget bounds the whole pipeline.** Default
  `max(1 GiB, min(threads x blockBytes x 16, physical memory / 2))`:
  a block in flight costs about eight blockBytes once codec workspace
  counts, the writer takes half the budget, so sixteen per thread
  admits about one block per thread. (The x4 first written here
  double-counted the workspace against the in-flight estimate and
  capped concurrency at threads/4 whatever the block size; the
  Phase 1 acceptance run caught it.) The
  `TTIO_MEMORY_BUDGET` environment variable (bytes) overrides it. Two
  consumers share it: the writer stalls block submission while its
  in-flight estimate exceeds the budget (replacing the v1.9
  threads + 1 block-count window, which was unbounded in bytes), and
  the assembler stalls producers while parked parsed batches exceed
  half the budget (the writer takes the other half).
* The per-record autorelease discipline of the batch importers
  applies to every new loop.

## 7. Threading

One shared pool serves parse and encode tasks; work-stealing balances
the phases and no second knob is introduced. `TTIO_THREADS` keeps its
meaning and default (cores - 8, floor 1; 1 = the serial path,
bypassing every component above). The FQZCOMP auto-tune stand-down
keys off the same pool as in v1.9.

## 8. Verification and acceptance

* **Byte identity:** serial = pipeline = shard on a synthetic
  long-read run and a real corpus slice, compared over the genomic
  subtree (the container's provenance stamp is run-varying by
  design).
* **Boundary scanner unit tests:** `@` inside quality strings, a
  candidate on a range edge, a truncated final record, offset 0.
* **Performance acceptance:** the 50 GB HiFi corpus encodes in under
  6 minutes at 24 threads (>= 150 MB/s; the pre-design baseline is
  13m 12s). Implies roughly 15 minutes for 119 GB.
* **Memory acceptance:** peak RSS within the default byte budget plus
  fixed overhead on the same corpus.
* **Regression tracking:** the throwaway bench tool becomes
  `TtioFastqEncodeBench` (repo tool, one `[obj-bench]` line) so the
  number is watched.
* Full SDK suites green; the cross-language cells are untouched
  because the file format is unchanged.

## 9. Phasing

1. **ObjC** — full hybrid, writer byte budget, BAM pipeline parsing,
   bench tool. (The production runtime; the 119 GB target is judged
   here.)
2. **Java** — same architecture on the SDK's executors.
3. **Python** — pipeline mode plus shard mode with numpy-vectorised
   boundary scanning and field parsing; no new C kernel surface.

Each phase is its own plan and lands green before the next starts.
