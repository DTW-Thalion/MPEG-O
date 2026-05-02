# M94.Z V4 candidate prototype

Stage 1 prototype harness for Task #84 — richer-context M94.Z. See
[the design spec](../../docs/superpowers/specs/2026-05-02-l2x-m94z-richer-context-stage1-design.md)
for the full design.

## How to run

```bash
TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so \
    .venv/bin/python -m tools.perf.m94z_v4_prototype.harness
```

Expected wall: ~2-5 minutes on a workstation. Five candidates are run
on `data/genomic/na12878/na12878.chr22.lean.mapped.bam`.

## Outputs

- `docs/benchmarks/2026-05-02-m94z-v4-candidates.md` — per-candidate
  compressed size, B/qual, ratio vs CRAM, encode wall, n_active,
  diagnostic stats, and the §5 decision-rule outcome.

## Smoke check (optional, before the full run)

```bash
.venv/bin/python -m tools.perf.m94z_v4_prototype.smoke
```

Runs each candidate on a 3-read × 4-quality synthetic input. Should
finish in seconds. If c0 fails, the harness wiring is broken; fix
that before chasing other failures.

## Why this is throwaway code

The candidate that wins (per spec §5) gets a Stage 2 spec + production
implementation in `python/src/ttio/codecs/`, `native/src/`, and the
language wrappers. This directory exists only to inform that decision
and is not maintained as production code.
