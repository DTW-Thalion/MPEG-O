# Parallel Producer, Phase 2 (Java) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Java import pipeline matches the ObjC phase: hybrid producer (shard for plain FASTQ, pipeline for gzip/pipes/BAM), byte-sized batches, the corrected byte budget, output byte-identical to serial, acceptance within 1.5x of the ObjC 50 GB number.

**Architecture:** The pull-model `GenomicStreamSource(Supplier<Iterator>)` keeps its shape. Pipeline mode needs no separate assembler: the iterator keeps an ArrayDeque of `Future<WrittenGenomicRun>` submitted in order and takes the head, sizing the window by pulling before submitting. Shard mode runs one long executor task per range, each feeding a per-shard `LinkedBlockingQueue` (poison-pill terminated), consumed shard-major under a shared byte-budget semaphore.

**Tech Stack:** Java 21+ (the SDK's toolchain), `Threads.PoolScope` executors, zlib via `GZIPInputStream`, the existing FastqReader / BamReader / BatchAccumulator / GenomicStreamWriter.

**Spec:** docs/superpowers/specs/2026-08-19-parallel-producer-design.md (the formula in section 6 as corrected by the Phase 1 note).

## Global Constraints

- Output bytes unchanged: serial = pipeline = shard, proven by digest tests.
- `TTIO_THREADS` semantics unchanged; 1 = the serial path.
- Budget default `max(1 GiB, min(threads * blockBytes * 16, physicalMemory / 2))`; `TTIO_MEMORY_BUDGET` overrides; writer and producer each take half. Physical memory via `com.sun.management.OperatingSystemMXBean.getTotalMemorySize()` with an `Runtime.maxMemory()*4` fallback.
- `batchBytes` default 64 MiB; `batchReads` compat, first limit cuts.
- Phase 1 lessons are constraints: the pipeline caller is submitter and consumer, so submission never blocks (window by pull-before-submit); shard workers may block on the budget semaphore because the consumer never submits there; failure drains discard rather than re-emit; no slot-counter captures in lambdas that freeze values.
- Commit after every task; plain subjects; no attribution trailers.

---

### Task 1: Budget resolver and writer byte backpressure

**Files:**
- Modify: `java/src/main/java/global/thalion/ttio/Threads.java` (`resolveMemoryBudget(Long explicit, int threads, long blockBytes)`)
- Modify: `java/src/main/java/global/thalion/ttio/genomics/GenomicStreamWriter.java` (options `memoryBudgetBytes`; in-flight estimate `raw*4`; drain while over half; `maxInFlightBytesObserved`)
- Test: `java/src/test/java/global/thalion/ttio/genomics/GenomicStreamWriterTest.java`

**Interfaces:**
- Produces: `Threads.resolveMemoryBudget`, writer option + observable, matching the ObjC names.

- [ ] **Step 1: Failing test** — writer with blockReads 2000, budget 4 MiB, threads 6 over the 40k synthetic run: `maxInFlightBytesObserved <= 4 MiB` and the file equals the serial writer's (the existing byte-identity harness).
- [ ] **Step 2: Run, expect compile failure.**
- [ ] **Step 3: Implement** (explicit > env `TTIO_MEMORY_BUDGET` > formula; estimate = (sequences + qualities + offsets*3) * 4; drain loop biased to the count window as upper bound).
- [ ] **Step 4: GenomicStreamWriterTest green.**
- [ ] **Step 5: Commit** `java: the stream writer stalls on a byte budget`.

### Task 2: Byte-sized batches

**Files:**
- Modify: `java/src/main/java/global/thalion/ttio/importers/FastqReader.java` (`iterBatches(..., long batchBytes)`, `stream(..., long batchBytes)`; old signatures forward with 0)
- Test: `java/src/test/java/global/thalion/ttio/FastaFastqIoTest.java`

- [ ] **Step 1: Failing test** — 100 reads x 1 MiB, batchBytes 8 MiB: 25 batches of at most 4 reads concatenating to the whole.
- [ ] **Step 2-4: fail, implement (cut when pending seq+qual bytes cross), green.**
- [ ] **Step 5: Commit** `java: FASTQ batches cut by bytes`.

### Task 3: Record boundary scanner

**Files:**
- Create: `java/src/main/java/global/thalion/ttio/importers/FastqRecordScanner.java` (`long boundaryAtOrAfter(FileChannel ch, long offset, long length)`; window 1 MiB doubling to 16 MiB; rule: `\n@` confirmed by `+` two lines down)
- Test: `java/src/test/java/global/thalion/ttio/importers/FastqRecordScannerTest.java`

- [ ] **Step 1: Failing tests** — the five ObjC cases (offset 0, `@` in quality rejected, mid-record, after-last, truncated) ported.
- [ ] **Step 2-4: fail, implement, green.**
- [ ] **Step 5: Commit** `java: FASTQ record boundary scanner`.

### Task 4: Pipeline producer

**Files:**
- Create: `java/src/main/java/global/thalion/ttio/importers/FastqParallelProducer.java` (`static Iterator<WrittenGenomicRun> pipeline(Path, String sample, int batchReads, long batchBytes, int threads, ProgressSink)`)
- Modify: `FastqReader.stream(...)` (routes through the producer when `Threads.resolve(null) > 1`)
- Test: `java/src/test/java/global/thalion/ttio/importers/FastqParallelProducerTest.java`

**Interfaces:**
- The iterator slices whole records off the (possibly GZIP) stream on the calling thread, submits slice-parse lambdas to a `Threads.pool` scope opened for the iteration, keeps at most `threads + 2` futures in an ArrayDeque, and `next()` takes the head; Phred detected from the first slice on the caller. Parse errors surface as the iterator's RuntimeException carrying the cause; the underlying scope closes from a finally when the iterator is exhausted or abandoned (implement `AutoCloseable` and close from the stream source's drain).

- [ ] **Step 1: Failing test** — gzip 20k x 4 KiB fixture: threads-6 write equals TTIO_THREADS=1 write by full-run digest and spot reads.
- [ ] **Step 2-4: fail, implement, green.**
- [ ] **Step 5: Commit** `java: pipeline-mode parallel FASTQ producer`.

### Task 5: Shard mode

**Files:**
- Create: `java/src/main/java/global/thalion/ttio/importers/InputSegmenter.java` (shard iff seekable regular non-gzip)
- Modify: `FastqParallelProducer.java` (`shard(...)`: per-range tasks, per-shard queues, budget semaphore acquired by workers per parked batch estimate, released on consume; consumer drains shard-major)
- Test: `FastqParallelProducerTest.java`

- [ ] **Step 1: Failing tests** — mixed-length (30k, 100 KiB every 500) and sparse-shard (2 x 200 KiB) digests equal serial.
- [ ] **Step 2-4: fail, implement, green.**
- [ ] **Step 5: Commit** `java: shard-mode parallel FASTQ producer`.

### Task 6: BAM parsing on the pool

**Files:**
- Modify: `java/src/main/java/global/thalion/ttio/importers/BamReader.java` (header lines on the caller into the shared accumulator; record-line slices parsed by per-slice `BatchAccumulator`s seeded from header state, futures windowed as in Task 4; failure drain discards)
- Test: existing BamReader tests (they run with default threads) + a digest identity test threads-6 vs 1.

- [ ] **Step 1-4: failing digest test, implement, green (including the consumer-stop contract test).**
- [ ] **Step 5: Commit** `java: SAM field parsing moves to the pool`.

### Task 7: Bench + acceptance + docs

**Files:**
- Create: `java/src/main/java/global/thalion/ttio/tools/FastqEncodeBench.java` (main: `<in> <out.tio> [batchBytes [blockBytes]]`, one `[java-bench]` line: bytes, wall, MB/s, peak RSS via MemoryMXBean)
- Modify: `CHANGELOG.md`, spec status note.

- [ ] **Step 1: Bench on the 3.7 GB smoke; sanity.**
- [ ] **Step 2: Acceptance** — the 50 GB HiFi corpus at 24 threads, 64 MiB blocks, 20 GB budget: wall within 1.5x of the ObjC 5m 40s (<= 8m 30s), peak within the budget + slack, output subtree equals the ObjC/serial file's genomic subtree.
- [ ] **Step 3: Full Java suite green; Python/ObjC suites untouched but run once.**
- [ ] **Step 4: CHANGELOG with the measured numbers; commit; push; PR (five-part, under 200 words, audits).**

## Self-review

- Spec sections 2/4/5 map to Tasks 3-6; section 6 to Tasks 1-2; section 8 to Task 7. The Phase 1 lesson list is in Global Constraints. Names mirror ObjC: resolveMemoryBudget, memoryBudgetBytes, maxInFlightBytesObserved, batchBytes, FastqRecordScanner, InputSegmenter, FastqParallelProducer.
- No placeholders; fixtures and assertions specified per task.
