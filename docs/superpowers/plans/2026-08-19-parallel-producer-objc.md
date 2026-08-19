# Parallel Producer, Phase 1 (ObjC) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The ObjC import pipeline becomes codec-bound: hybrid producer (shard mode for plain FASTQ, pipeline mode for gzip/pipes/BAM), byte-sized batches, one byte budget, 50 GB HiFi in under 6 minutes at 24 threads with unchanged output bytes.

**Architecture:** InputSegmenter -> RecordScanner -> ParserPool -> OrderedAssembler in front of TTIOGenomicStreamWriter; one shared thread pool for parse and encode; ordering makes the output byte-identical to serial by construction.

**Tech Stack:** Objective-C (gnustep-2.x runtime), NSOperationQueue via TTIOThreadPool, zlib, the existing TTIOFastqReader / TTIOBamReader / TTIOGenomicStreamSource / TTIOGenomicStreamWriter.

**Spec:** docs/superpowers/specs/2026-08-19-parallel-producer-design.md

## Global Constraints

- Output bytes unchanged: serial = pipeline = shard over the genomic subtree, every task that touches the data path proves it.
- `TTIO_THREADS` semantics unchanged (unset/0 = cores - 8, floor 1; 1 = serial path bypassing all new components).
- Byte budget default `max(1 GiB, threads * blockBytes * 4)`; `TTIO_MEMORY_BUDGET` (bytes) overrides; writer and assembler each take half.
- `batchBytes` default 64 MiB (decoded seq + qual bytes); `batchReads` remains as a compat override, first limit hit cuts the batch.
- Every new loop drains an autoreleasepool per iteration; NSError crosses a pool in a strong local.
- No public API removed; new knobs are additive.
- Commit after every task; plain subjects; no attribution trailers.

---

### Task 1: Writer byte-budget backpressure

**Files:**
- Modify: `objc/Source/Genomics/TTIOGenomicStreamWriter.h` (options: `memoryBudgetBytes`; readonly `memoryBudgetBytes` on the writer)
- Modify: `objc/Source/Genomics/TTIOGenomicStreamWriter.m`
- Modify: `objc/Source/Core/TTIOThreads.h/.m` (budget resolver)
- Test: `objc/Tests/TestGenomicStreamWriter.m`

**Interfaces:**
- Produces: `+[TTIOThreads resolveMemoryBudget:(NSNumber *)explicit threads:(NSUInteger)t blockBytes:(unsigned long long)bb]` returning bytes; `TTIOGenomicStreamWriterOptions.memoryBudgetBytes` (0 = default); `TTIOInFlightBlock.estimatedBytes`.
- Consumes: the v1.9 `_drainUntil:` machinery.

- [ ] **Step 1: Failing test** — in the Threads set: a writer with `blockBytes` 8 MiB, `memoryBudgetBytes` 64 MiB and threads 24 never holds more than `32 MiB / (8 MiB * 4)`-ish blocks: append a 40-block synthetic run and assert `w.maxInFlightBytesObserved <= 32 * 1024 * 1024` (add that readonly observable) and that the file equals the serial writer's (gswCollect maps).
- [ ] **Step 2: Run, expect failure** (`resolveMemoryBudget` unknown selector).
- [ ] **Step 3: Implement** — `resolveMemoryBudget`: explicit > 0 wins, else `TTIO_MEMORY_BUDGET` env parsed as unsigned long long, else `MAX(1 GiB, t * bb * 4)`. Writer: estimate a block's bytes as `sequencesData.length + qualitiesData.length + names/cigars ~ offsetsData.length * 3`, multiply by 4 for workspace; account on submit, release on write; `_drainUntil:` gains a byte condition: drain while `inflightBytes > budget/2` OR the v1.9 count condition (count stays as a hard upper bound). Track `maxInFlightBytesObserved`.
- [ ] **Step 4: Suite subset green** (`Threads` set + streaming writer tests).
- [ ] **Step 5: Commit** `objc: the stream writer stalls on a byte budget, not a block count`.

### Task 2: Byte-sized batches

**Files:**
- Modify: `objc/Source/Import/TTIOFastqReader.h/.m` (`batchBytes` on iterBatches/stream entry points; plumb both limits)
- Modify: `objc/Source/Import/TTIOGenomicStreamSource.h/.m` (carry `batchBytes`)
- Test: `objc/Tests/TestStreamingImporters.m`

**Interfaces:**
- Produces: `+iterBatchesFromPath:...batchReads:batchBytes:...` (old selector forwards with `batchBytes:0` = 64 MiB default); `+streamFromPath:...batchBytes:`.

- [ ] **Step 1: Failing test** — synthetic FASTQ of 100 reads x 1 MiB: `batchBytes` 8 MiB yields batches of at most 8 reads each and they concatenate to the eager run.
- [ ] **Step 2: Run, expect failure.**
- [ ] **Step 3: Implement** — in the batch loop, cut when `pendingSeqBytes + pendingQualBytes >= batchBytes` or the read count hits `batchReads`; defaults 64 MiB / NSUIntegerMax.
- [ ] **Step 4: Streaming importer tests green.**
- [ ] **Step 5: Commit** `objc: FASTQ batches cut by bytes`.

### Task 3: RecordScanner

**Files:**
- Create: `objc/Source/Import/TTIOFastqRecordScanner.h/.m`
- Modify: `objc/Source/GNUmakefile`
- Test: `objc/Tests/TestFastqRecordScanner.m` (+ runner registration)

**Interfaces:**
- Produces: `+ (long long)boundaryAtOrAfter:(long long)offset inFile:(NSFileHandle *)fh fileLength:(long long)len` returning the byte offset of the first record start >= offset (or len), and `+ (BOOL)validateCandidate:(NSData *)window` for tests. Boundary rule per spec section 4: `\n@` (or offset 0) confirmed by `+` two lines down; scan forward candidate by candidate reading a bounded window (1 MiB, doubled up to 16 MiB for pathological quality lines).

- [ ] **Step 1: Failing tests** — offset 0; a `@` first-in-quality-line candidate that must be rejected; a candidate straddling the window edge; a truncated final record (boundary = len); CRLF input rejected the same way the reader rejects it today.
- [ ] **Step 2: Run, expect link failure.**
- [ ] **Step 3: Implement** (pure function of the window bytes; no parsing).
- [ ] **Step 4: Tests green.**
- [ ] **Step 5: Commit** `objc: FASTQ record boundary scanner`.

### Task 4: OrderedAssembler + pipeline mode

**Files:**
- Create: `objc/Source/Import/TTIOOrderedBatchAssembler.h/.m` (generic: `submitSlot:(NSUInteger)seq producer:^TTIOWrittenGenomicRun *(NSError **)` on the shared pool; `nextBatch:(NSError **)` blocks in order; byte-parking cap = budget/2)
- Create: `objc/Source/Import/TTIOFastqParallelProducer.h/.m` (pipeline mode: reader thread inflate + line slice -> pool parse -> assembler)
- Modify: `objc/Source/Import/TTIOFastqReader.m` (`streamFromPath:` routes through the producer when threads > 1)
- Modify: `objc/Source/GNUmakefile`
- Test: `objc/Tests/TestStreamingImporters.m`

**Interfaces:**
- Produces: `TTIOFastqParallelProducer` exposing the same `TTIOGenomicBatchProducer` block shape `TTIOGenomicStreamSource` already consumes, so `writeIntoStudy:` is untouched.
- Consumes: Task 2 batch limits, Task 1 budget, `TTIOThreadPool`.

- [ ] **Step 1: Failing test** — a gzip synthetic FASTQ (20k reads x 4 KiB): `streamFromPath` with threads 6 writes a .tio whose genomic subtree equals the serial (threads 1) write; batches observed > 1.
- [ ] **Step 2: Run, expect failure.**
- [ ] **Step 3: Implement** — reader thread: rolling buffer, slice at the last complete record before `batchBytes`, hand `(seq, slice)` to the pool; worker parses slice with the existing record parser into a batch; assembler releases in seq order; errors propagate through the assembler; autoreleasepool per slice on both sides.
- [ ] **Step 4: Identity + suite subset green.**
- [ ] **Step 5: Commit** `objc: pipeline-mode parallel FASTQ producer`.

### Task 5: Shard mode

**Files:**
- Create: `objc/Source/Import/TTIOInputSegmenter.h/.m` (`+modeForPath:` -> shard | pipeline; shard iff seekable regular file and not gzip magic)
- Modify: `objc/Source/Import/TTIOFastqParallelProducer.m` (shard mode: T ranges via Task 3 boundaries, one scanner+parser per range, `(shard, seq)` ordering into the assembler)
- Test: `objc/Tests/TestStreamingImporters.m`

- [ ] **Step 1: Failing test** — plain synthetic FASTQ (30k reads, mixed lengths 100 B - 100 KiB): shard (threads 6) subtree equals pipeline equals serial; a second fixture sized so one shard is empty.
- [ ] **Step 2: Run, expect failure.**
- [ ] **Step 3: Implement** — global order = shard-major (all of shard 0's batches, then shard 1's...); the assembler's parking cap makes skew safe; a shard's parser stops at the first boundary >= its range end.
- [ ] **Step 4: Identity tests green.**
- [ ] **Step 5: Commit** `objc: shard-mode parallel FASTQ producer`.

### Task 6: BAM pipeline parsing on the pool

**Files:**
- Modify: `objc/Source/Import/TTIOBamReader.m` (the chunk loop hands slices of complete SAM lines to pool workers; workers run a per-slice accumulator; sequential concatenation preserves order)
- Test: `objc/Tests/TestStreamingImporters.m` (BAM fixture identity threads 6 vs 1), existing BAM tests.

- [ ] **Step 1: Failing test** — the M87 BAM fixture imported with threads 6 equals threads 1 over the genomic subtree.
- [ ] **Step 2: Run, expect failure** (no threaded path yet: test asserts `importer used > 1 parse worker` via a counter hook).
- [ ] **Step 3: Implement** — the accumulator's per-line field parse is already independent per line; give each worker its own accumulator over its slice, then merge arrays in slice order on the reader thread. Header lines stay on the reader thread.
- [ ] **Step 4: BAM tests green.**
- [ ] **Step 5: Commit** `objc: SAM field parsing moves to the pool`.

### Task 7: Bench tool

**Files:**
- Create: `objc/Tools/TtioFastqEncodeBench.m` (from the throwaway s78/fq_bench.m: args `<in> <out.tio> [batchBytes]`, one `[obj-bench]` line with wall, MB/s, peak RSS via getrusage)
- Modify: `objc/Tools/GNUmakefile`

- [ ] **Step 1: Build; run on a 100 MB synthetic; line format checked by eye.**
- [ ] **Step 2: Commit** `objc: FASTQ encode bench tool`.

### Task 8: Acceptance, docs, suites

**Files:**
- Modify: `CHANGELOG.md`, `docs/superpowers/specs/...` (status note), README notes where the old knobs are described.

- [ ] **Step 1: Acceptance runs** — 50 GB HiFi at 24 threads: wall < 6 min, peak RSS <= default budget + 1 GiB, output subtree equals the serial reference (spot: the 3.7 GB smoke serial file). Record numbers.
- [ ] **Step 2: Full ObjC suite green; Python/Java suites green (untouched, but run).**
- [ ] **Step 3: CHANGELOG entry with the measured numbers; docstrings for the new knobs.**
- [ ] **Step 4: Commit** `docs: the parallel producer, its knobs and the measured run`; push; PR (five-part body under 200 words; audits).

## Self-review

- Spec section 2 components: Tasks 3 (scanner), 4 (assembler + pipeline + segmenter consumer), 5 (segmenter + shard). Section 4 boundary rule: Task 3. Section 5 BAM: Task 6. Section 6 memory: Tasks 1-2. Section 7 pool: reused, no task. Section 8 acceptance: Task 8; bench: Task 7.
- Names used consistently: TTIOFastqRecordScanner, TTIOOrderedBatchAssembler, TTIOFastqParallelProducer, TTIOInputSegmenter, memoryBudgetBytes, batchBytes.
- No placeholders; every code step names its anchor points; tests specified with fixtures and assertions.
