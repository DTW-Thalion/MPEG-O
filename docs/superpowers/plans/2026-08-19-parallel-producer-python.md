# Parallel Producer, Phase 3 (Python) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Python import pipeline matches the other two phases: hybrid producer (shard for plain FASTQ, pipeline for gzip), numpy-vectorised boundary scanning and slice parsing, byte-sized batches, the shared byte budget on the stream writer, output byte-identical to serial, acceptance within 2x of the ObjC 50 GB number.

**Architecture:** The scanner and parser are numpy: newline positions once per window, `\n@` candidates confirmed by `+` two lines down, and a slice parser that builds the run's concatenated `sequences`/`qualities` arrays with a fancy-index gather instead of per-record joins. The fast parser assumes clean four-line records; any validation mismatch re-parses that slice with the tolerant serial parser, so stray blank lines cost speed, never correctness. Pipeline mode keeps an ordered deque of futures with pull-before-submit; shard mode runs one worker per range feeding a depth-1 `queue.Queue`, drained shard-major. No new C kernel surface: the pool's win comes from numpy releasing the GIL and the codec encode already off the interpreter.

**Tech Stack:** Python 3.11+, numpy, `concurrent.futures.ThreadPoolExecutor` via the existing `_threads.pool_context`, the existing FastqReader / GenomicStreamWriter / `_build_unaligned_run`.

**Spec:** docs/superpowers/specs/2026-08-19-parallel-producer-design.md (section 6 formula as corrected by the Phase 1 note; section 9 phase 3).

## Global Constraints

- Output bytes unchanged: serial = pipeline = shard, proven over the genomic subtree (provenance is run-varying by design).
- `TTIO_THREADS` semantics unchanged; 1 = the serial path, untouched.
- Budget default `max(1 GiB, min(threads * block_bytes * 16, physical_memory / 2))`; `TTIO_MEMORY_BUDGET` overrides; writer and producer each take half. Physical memory via `os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE")` in a try/except; on failure skip the clamp.
- `batch_bytes` default 64 MiB; `batch_reads` kept for compat, first limit cuts.
- Phase 1 and 2 lessons are constraints: the pipeline caller is submitter and consumer, so submission never blocks (window by pull-before-submit, threads + 2); shard workers may block because the consumer never submits there; shard workers catch `BaseException` and always deliver their done marker; failure drains discard rather than re-emit.
- Zero-length reads are legal FASTQ (an empty sequence line); the fast parser must group them correctly, and only stray blank separator lines trigger the serial fallback.
- Commit after every task; plain subjects; no attribution trailers.

---

### Task 1: Budget resolver and writer byte backpressure

**Files:**
- Modify: `python/src/ttio/_threads.py` (add `resolve_memory_budget(explicit, threads, block_bytes)`)
- Modify: `python/src/ttio/genomic/stream_writer.py` (ctor `memory_budget_bytes=None`; per-block estimate `raw_bytes * 4`; `_drain` also runs while in-flight estimated bytes exceed half the budget; property `max_inflight_bytes_observed`)
- Test: `python/tests/test_genomic_stream_writer.py`

**Interfaces:**
- Produces: `ttio._threads.resolve_memory_budget(explicit: int | None, threads: int, block_bytes: int) -> int`; writer keyword `memory_budget_bytes` and observable `max_inflight_bytes_observed`, matching the ObjC and Java names.

- [ ] **Step 1: Failing test** — writer with `block_reads=2000`, `memory_budget_bytes=4 * 2**20`, `threads=6` over the existing 40k synthetic run: `max_inflight_bytes_observed <= 2 * 2**20` (the writer half) and the file equals the serial writer's over the genomic subtree.
- [ ] **Step 2: Run, expect `TypeError` (unknown keyword).**
- [ ] **Step 3: Implement** (explicit > env `TTIO_MEMORY_BUDGET` > formula; raw bytes = sequences.nbytes + qualities.nbytes + offsets.nbytes * 3; drain-to-budget before submitting the next block, count window still the upper bound).
- [ ] **Step 4: test_genomic_stream_writer.py green.**
- [ ] **Step 5: Commit** `python: the stream writer stalls on a byte budget`.

### Task 2: Byte-sized batches

**Files:**
- Modify: `python/src/ttio/importers/fastq.py` (`iter_batches(..., batch_bytes=64 * 2**20)`; `stream_source` passes it through)
- Test: `python/tests/test_fasta_fastq_io.py`

**Interfaces:**
- Produces: `iter_batches(..., batch_reads=100_000, batch_bytes=64 * 2**20)`; a batch closes when either limit is reached (bytes counted as `len(seq)` per record).

- [ ] **Step 1: Failing test** — a synthetic FASTQ of 40 reads of 1000 bases with `batch_bytes=8000, batch_reads=10**9` yields 5 batches of 8 reads.
- [ ] **Step 2: Run, expect `TypeError`.**
- [ ] **Step 3: Implement** (track `pending_bases`; emit when `len(pending) >= batch_reads or pending_bases >= batch_bytes`).
- [ ] **Step 4: test green; the existing batch_reads tests untouched.**
- [ ] **Step 5: Commit** `python: fastq batches cut on bytes as well as reads`.

### Task 3: Boundary scanner

**Files:**
- Create: `python/src/ttio/importers/fastq_scanner.py`
- Test: `python/tests/test_fastq_scanner.py` (new)

**Interfaces:**
- Produces: `boundary_at_or_after(f, offset: int, file_size: int) -> int` (binary file object, returns the byte offset of the first record start at or after `offset`, or `file_size`); `confirm_candidate(buf: bytes, pos: int) -> int` (1 confirmed, 0 rejected, -1 need more bytes); window growth 1 MiB doubling to 16 MiB, then `FastqParseError`.

- [ ] **Step 1: Failing tests** — offset 0 returns 0; a candidate `@` inside a quality string is rejected (quality bytes legally contain `@`); a candidate on the window edge grows the window; a truncated final record returns `file_size`.
- [ ] **Step 2: Run, expect `ModuleNotFoundError`.**
- [ ] **Step 3: Implement** — numpy over the window: `cand = np.nonzero((a[:-1] == 10) & (a[1:] == 64))[0] + 1`; for each candidate in order, confirm by walking two newlines forward and requiring `+` (and back-checking the line before the candidate is a plus-line's qualities partner, the same two-line rule as the ObjC and Java scanners).
- [ ] **Step 4: test_fastq_scanner.py green.**
- [ ] **Step 5: Commit** `python: fastq record boundary scanner`.

### Task 4: Vectorised slice parser

**Files:**
- Create: `python/src/ttio/importers/fastq_parallel.py` (start with `parse_slice`)
- Test: `python/tests/test_fastq_parallel.py` (new)

**Interfaces:**
- Produces: `parse_slice(data: bytes) -> tuple[list[str], np.ndarray, np.ndarray, np.ndarray]` returning `(names, sequences_u8, qualities_u8_verbatim, lengths_u32)` for a slice that starts and ends on record boundaries; raises `FastqParseError` on malformed input after the serial fallback also fails. Qualities are verbatim (no Phred conversion; the producer converts after detection, as serial does).

- [ ] **Step 1: Failing tests** — a clean 3-record slice round-trips names/seq/qual; a zero-length read (empty sequence and quality lines) parses on the fast path; a slice with a stray blank line between records falls back and still parses; CRLF line endings parse; SEQ/QUAL length mismatch raises.
- [ ] **Step 2: Run, expect `ModuleNotFoundError`.**
- [ ] **Step 3: Implement** — newline positions once; line starts/ends with vectorised `\r` stripping (`ends -= (a[ends - 1] == 13)` guarded for empty lines); validate `n_lines % 4 == 0`, all line-0s start `@`, all line-2s start `+`, `seq_lens == qual_lens`; gather seq and qual bytes with the repeat/arange fancy index; names from the header lines by a per-record loop (`buf.split(maxsplit=1)`); any validation failure re-parses the slice with `FastqReader._iter_records_raw` semantics over `io.BytesIO`.
- [ ] **Step 4: test_fastq_parallel.py green.**
- [ ] **Step 5: Commit** `python: vectorised fastq slice parser`.

### Task 5: Segmenter and pipeline producer

**Files:**
- Modify: `python/src/ttio/importers/fastq_parallel.py` (add `plan_input`, `iter_batches_pipeline`)
- Modify: `python/src/ttio/importers/fastq.py` (`iter_batches` gains `threads=None`; routes to the parallel producer when the resolved count > 1; `stream_source` passes `threads` through)
- Test: `python/tests/test_fastq_parallel.py`

**Interfaces:**
- Consumes: `parse_slice`, `boundary_at_or_after`, `resolve_threads`.
- Produces: `plan_input(path, threads, batch_bytes) -> ("serial" | "pipeline", None) | ("shard", ranges)` (gzip magic or unseekable → pipeline; plain file → shard ranges on scanner boundaries near multiples of `max(batch_bytes, file_size // (threads * 4))`; threads 1 → serial). `iter_batches_pipeline(path_or_fh, ...) -> Iterator[WrittenGenomicRun]`: the caller thread reads decompressed chunks, slices them at record boundaries near `batch_bytes`, submits `parse_slice` to the pool, and pulls the head future before submitting once `len(deque) >= threads + 2`. Batches are built with the same `_build_unaligned_run` field layout (unaligned constants), Phred detected on the first emitted batch, offset-64 conversion vectorised (`qual -= 31`).

- [ ] **Step 1: Failing test** — pipeline over a gzip mixed-length fixture (200 reads, lengths 0 to 5000, including zero-length) with `threads=4, batch_bytes=32_768` equals the serial `iter_batches` output batch-for-batch in every array and name list.
- [ ] **Step 2: Run, expect `AttributeError` on the missing function.**
- [ ] **Step 3: Implement.** The last partial record of each chunk carries into the next (the scanner confirms the cut); the final slice flushes at EOF.
- [ ] **Step 4: test green with `TTIO_THREADS=1` in the suite environment forcing the pool off elsewhere (set `threads=` explicitly in the test).**
- [ ] **Step 5: Commit** `python: pipeline fastq producer`.

### Task 6: Shard producer

**Files:**
- Modify: `python/src/ttio/importers/fastq_parallel.py` (add `iter_batches_shard`)
- Test: `python/tests/test_fastq_parallel.py`

**Interfaces:**
- Consumes: `plan_input` ranges, `parse_slice`.
- Produces: `iter_batches_shard(path, ranges, ...) -> Iterator[WrittenGenomicRun]`: one pool task per range, each reading its byte range, cutting record slices near `batch_bytes`, parsing, and putting finished batches on its own `queue.Queue(maxsize=1)`; a `None` done marker always delivered in a `finally`; workers catch `BaseException` and forward it through the queue; the consumer drains shard-major and on a forwarded error drains remaining queues without emitting, then raises.
- [ ] **Step 1: Failing tests** — shard mode over a plain mixed-length fixture equals serial batch-for-batch; a sparse case (`threads=8` over a file smaller than one batch) collapses to fewer shards and still equals serial.
- [ ] **Step 2: Run, expect `AttributeError`.**
- [ ] **Step 3: Implement.** Phred detection: shard 0's first batch settles the offset before any batch is emitted (workers park parsed-verbatim batches until the consumer has set the offset from shard 0, conversion applied at emit time in the consumer, keeping detection identical to serial).
- [ ] **Step 4: test green.**
- [ ] **Step 5: Commit** `python: shard fastq producer`.

### Task 7: Bench tool, full-suite gate, acceptance

**Files:**
- Create: `python/src/ttio/tools/fastq_encode_bench.py` (args: `in out [batch_bytes [block_bytes]]`; one `[py-bench] seconds=... mb_per_s=...` line; `batch_bytes` 0 means default)
- Modify: `CHANGELOG.md`, `docs/superpowers/specs/2026-08-19-parallel-producer-design.md` (status line gains the Python phase)
- Test: the full Python suite, then the corpus run

**Interfaces:**
- Consumes: `FastqReader.stream_source(threads=...)`, `SpectralDataset` write path, `resolve_memory_budget`.

- [ ] **Step 1: Bench tool** mirroring TtioFastqEncodeBench / FastqEncodeBench.
- [ ] **Step 2: Full Python suite green** (`.venv` inside the worktree; run under `systemd-run --user --scope -p MemoryMax=26G` if it touches large fixtures).
- [ ] **Step 3: Cross-SDK identity** — bench a small real corpus slice in Python and ObjC at 64 MiB blocks; every genomic dataset byte-identical (`h5cmp.py`).
- [ ] **Step 4: Acceptance** — the 50 GB HiFi corpus at 24 threads in under 11m 20s (2x the ObjC 5m 40s), peak RSS within the budget plus fixed overhead.
- [ ] **Step 5: Docs + commit** `python: parallel fastq producer docs and bench`, then push and PR (base `parallel-producer-java`).
