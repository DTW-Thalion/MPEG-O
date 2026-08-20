# Spec: per-run sticky qualities strategy selection (task #10)

Status: DRAFT — awaiting review. Design direction (option 1) approved
2026-08-19; this spec pins the mechanism for review before planning.

## Problem

Every qualities block is fully encoded three times (V4, V5-S5, V5-S6;
smallest wins — `native/src/m94z_qual.c`, auto-tune branch). In pooled
writers the three candidates run sequentially on the block's worker
(`autotune_threads == 1`), so qualities cost ~90% of all import CPU
(perf, 3.7 GB HiFi, 24T: code_pass 65.4%, V4 15.4%, rc_cram_encode
8.9%). The winner is 100% consistent within every file measured
(50 GB HiFi 372/372 V4; NovaSeq 23/23 V4; 2x250 chr22 11/11 V4;
lowcov chr22 2/2 V5-S5). Encoding all three per block buys nothing
after the first block.

## Behavior

Decide the strategy once per genomic run, in the writer:

1. Block 0 of a run auto-tunes exactly as today (3-way, smallest wins).
2. The writer reads the winner from the encoded stream and pins it.
3. Blocks >= 1 of the same run encode only the pinned strategy.
4. `TTIO_M94Z_EXHAUSTIVE=1` (new env, read by the writers) disables
   pinning and restores today's every-block 3-way tune.

No periodic re-tune in this version. The measured evidence is 100%
within-file consistency, and a deterministic re-tune scheme costs a
synchronization point every N blocks in the parallel producer (see
Determinism). `TTIO_M94Z_EXHAUSTIVE=1` is the escape hatch; a re-tune
interval can be added later without touching the wire.

### Determinism rule

The pin comes from block 0 by block index, never from "first block
to finish". In the parallel producer, a block >= 1 that reaches its
qualities channel before block 0's verdict exists waits for it.
Timing-dependent strategy choice would break run-to-run and cross-SDK
byte identity; the wait is one-time, bounded by block 0's own encode
(sub-second on 64 MiB blocks), and workers reach it only after their
other channels.

### Compression impact

Within a file whose corpus class drifts mid-run, a later block could
have preferred a different strategy; the pinned stream is still a
valid stream and every decoder reads it unchanged. Measured cost of a
wrong pick is ~1% and only on HiFi (the near-tie corpus); the other
corpora separate V4 vs S5 by 11-15%. Output is NOT guaranteed
bytes-identical to the exhaustive tune in principle; on every corpus
measured it is identical in practice.

## Kernel changes (native/src, mirrored to python/_native)

Two small additions; wire format and all decode paths untouched.

1. New strategy hint `TTIO_M94Z_HINT_V4_AUTO` (value 7) in
   `ttio_m94z_qual_encode`: force the V4 path with V4's own internal
   preset selection (pass -1 through to `ttio_m94z_v4_encode`), even
   when `seq_in` is non-NULL. Today "V4, auto preset" is reachable
   only as hint -1 with seq_in == NULL; call sites should not have to
   drop the sequences pointer to express it. Hints 5/6 already force
   S5/S6 and need nothing.
2. New helper `int ttio_m94z_qual_stream_strategy(const uint8_t *in,
   size_t in_len)` returning 4 (V4), 5, or 6, by reading the wire
   header: byte 4 = version (V4/V5); for V5, strategy_id = body[1]
   (`fqzcomp_seqctx.c` writes `out[1] = pm->strategy_id`, body offset
   from `ttio_m94z_v5_unpack`). One C implementation instead of three
   SDK wire parsers. Errors (< 5 bytes, unknown version) return < 0.

Rejected alternative: an opaque kernel-side "tuner" object holding the
sticky state. It centralizes the logic but adds a stateful object with
locking semantics to three FFI bindings; the writers already own
per-run state and block ordering, so the state lives there.

## SDK changes (the writers' qualities encode paths)

Per-run writer state: `qual_hint`, initially -1 (auto). Block 0
encodes with -1, then `qual_hint = stream_strategy(out)` mapped
V4 -> 7, S5 -> 5, S6 -> 6. Blocks >= 1 pass `qual_hint`.
`TTIO_M94Z_EXHAUSTIVE=1` keeps `qual_hint` at -1 permanently.

- ObjC: the codec API (`TTIOFqzcompNx16Z encodeQualWithQualities:...
  strategyHint:`) already carries the hint; the pooled block writer
  gains the per-run pin plus the block->0 gate (condition variable on
  the run's writer context).
- Java: `FqzcompNx16Z.EncodeOptions.v4StrategyHint(int)` already
  exists; the stream writer gains the same pin + gate.
- Python: `codecs.fqzcomp_nx16_z.encode(..., v4_strategy_hint=)`
  already exists, but the writers dispatch through
  `CODEC_REGISTRY[FQZCOMP_NX16_Z].encode(channel, CodecContext)`
  (`_dataset_write_genomic.py:_write_qualities_fqzcomp_nx16_z`).
  `CodecContext` gains an optional `qual_strategy_hint` field the
  adapter forwards; stream_writer holds the pin.

Whole-run (non-streaming) writers encode a run's qualities in one
call and are unaffected (single encode = block 0 = full tune).

## Expected result

Blocks after the first encode qualities once instead of three times:
qualities CPU / ~3 for the run's tail, plus reduced memory-bandwidth
contention (one context-model coder per worker instead of three
in sequence). Acceptance is measured, not derived: 3.7 GB
/tmp/smoke.fastq and the 50 GB acceptance config (current baselines
126.4 MB/s and 5:11 / 153.4 MB/s at est-raw-x2), plus one lowcov run
to confirm a V5-S5 pin end-to-end.

## Tests

- Kernel: hint 7 == V4-auto byte identity vs seq_in=NULL auto path;
  stream_strategy over V4/S5/S6 streams and error cases (both
  native/tests and python/_native/tests copies).
- Per SDK: pinned run output byte-identical to exhaustive on a
  winner-consistent fixture; TTIO_M94Z_EXHAUSTIVE=1 restores today's
  behavior; V5 pin path exercised (lowcov-class fixture); parallel
  producer with >= 3 in-flight blocks produces identical bytes across
  repeated runs (determinism gate).
- Cross-SDK identity on the existing fixtures.

## Gates

Existing suites green (ObjC full 4975, Python incl. writer 9/9,
Java incl. GenomicStreamWriterTest 8/8), CHANGELOG entry, bench
numbers in the PR body.

## Open questions for review

1. Env name `TTIO_M94Z_EXHAUSTIVE` acceptable? (Reads in the writers,
   not the kernel — kernel behavior at hint -1 is unchanged.)
2. Should the `inflight-estimate` branch (est raw x2, ff42abc6) ride
   in this PR or go separately once #303-#305 land?
3. Block-0 gate: OK to make blocks >= 1 wait on block 0's qualities
   verdict (recommended), or would you rather blocks 1..k full-tune
   ungated and accept per-block deterministic picks for the first few
   blocks? (Slightly faster warmup, more code paths, still
   deterministic — the pick would be "block index < first-verdict
   index" no wait, that is timing again. It would have to be "every
   block full-tunes until its own index-ordered predecessor pinned",
   which degenerates to the gate. Recommendation stands: gate.)
