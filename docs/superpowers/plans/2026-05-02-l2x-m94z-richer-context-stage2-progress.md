# L2.X Stage 2 (V4 CRAM port) — progress + handoff

> **For agentic workers picking this up in a fresh session:** read this
> doc first, then jump to the "How to resume" section below. The full
> implementation plan is at
> `docs/superpowers/plans/2026-05-02-l2x-m94z-richer-context-stage2.md`
> (HEAD `9be92f5`). The spec is at
> `docs/superpowers/specs/2026-05-02-l2x-m94z-richer-context-stage2-design.md`
> (HEAD `5b84553`). This progress doc covers what's been done and what
> needs care on resume.

## Status (2026-05-02 evening, paused for context budget)

5 / 15 tasks complete. Phase 0 + Phase 1 done; Phase 2 has the API
header but no implementation yet.

| Task | Phase | Status | Commit | Notes |
|---|---|---|---|---|
| 1 | P0 sanity check | ✅ done | `184c198` | htscodecs hits 0.398 B/qual on PacBio HiFi → PROCEED-WITH-KNOWN-LIMITATION |
| 2 | P1 RC skeleton | ✅ done | `ccf760d` | Skeleton matches plan; build clean |
| 3 | P1 RC bodies | ✅ done | `9836d42` | Implementer caught + fixed two plan bugs (see below) |
| 4 | **P1 byte-equality gate** | ✅ **PASSED** | `abc17a1` | rc_cram byte-identical to htscodecs `c_range_coder.h` on 1M-sym flat-freq (both 1,048,581 bytes) |
| 5 | P2 fqzcomp_qual.h API | ✅ done | `416bf6f` | Header verbatim from plan §Task 5 |
| 6 | P2 strategy-1 impl | ⏳ pending | — | THE substantive port. Read htscodecs/fqzcomp_qual.c carefully |
| 7 | P2 byte-equality gate | ⏳ pending | — | chr22 strategy=1 vs htscodecs --strategy=1 |
| 8 | P3 auto-tune + 5 presets | ⏳ pending | — | Add histogram-analysis pass + preset table |
| 9 | P3 byte-equality gate | ⏳ pending | — | All 4 corpora, auto-tune mode |
| 10 | P4 m94z_v4_wire | ⏳ pending | — | Outer V4 framing wraps CRAM body |
| 11 | P4 Python ctypes V4 | ⏳ pending | — | _encode_v4_native + V4-default dispatch |
| 12 | P4 Python tests | ⏳ pending | — | ~10 V4 dispatch tests |
| 13 | P5 integration test | ⏳ pending | — | Cross-corpus byte-exact via Python |
| 14 | P5 results doc | ⏳ pending | — | docs/benchmarks/2026-05-02-m94z-v4-stage2-results.md |
| 15 | P5 docs + WORKPLAN + push | ⏳ pending | — | Final commit + push |

## Phase 0 outcome (`/home/toddw/p0_outcome.md`)

- htscodecs SHA: `7dd27f4b2bfe0ffdce413337972b3ad68550c3bf` (2026-03-11)
- PacBio HiFi corpus: `data/genomic/hg002_pacbio/hg002_pacbio.subset.bam`
  (14,284 reads, 264,190,341 qualities, mean 18.5 kb)
- htscodecs B/qual on PacBio HiFi: **0.3982**
- Decision: **PROCEED-WITH-KNOWN-LIMITATION**. CRAM 3.1's auto-tune does
  not save PacBio HiFi (the working hypothesis was falsified).
  PacBio HiFi qualities cluster at Q60+ with insufficient
  context-exploitable structure for fqzcomp's adaptive model. The V4
  port still wins on Illumina substantially.

The Phase 5 results doc (Task 14) must acknowledge this: V4 on PacBio
HiFi will land at ~0.40 B/qual (matching htscodecs); not better than
V3 baseline c0 (0.415). V4 is justified by Illumina wins, not PacBio.

## Plan-template bugs caught and fixed in Task 3

The Task 3 implementer subagent caught two real bugs in the original
plan template's `rc_cram.c` skeleton. Both are now fixed in the
committed code — but if anyone re-runs Task 2 or 3 from the plan
verbatim, they'll re-introduce the bugs. The plan should be patched.

### Bug 1: `rc_cram_decoder_init` byte indexing was wrong

**Plan template said:**
```c
d->code = ((uint32_t)in[1] << 24)
        | ((uint32_t)in[2] << 16)
        | ((uint32_t)in[3] <<  8)
        | ((uint32_t)in[4]);
d->in_pos = 5;
```

**htscodecs's `RC_StartDecode` actually does** `DO(5)` shift-accumulate
from `in[0..4]` (skipping the byte-1 offset). The fixed version reads
all 5 bytes starting from `in[0]`.

### Bug 2: missing `cache` and `ff_num` fields on encoder struct

The plan template's `rc_cram_encoder` had only `low`, `range`, `carry`,
`out`, `out_pos`, `out_cap`, `err`. The CRAM RC uses a deferred
byte-emit scheme (Subbotin carry-propagation) which requires:

```c
uint32_t ff_num;   /* pending 0xFF byte count */
uint32_t cache;    /* top byte of low pending emit */
```

The Task 3 implementer added these fields and the corresponding
`shift_low` helper that handles the carry-propagation. Task 2's
struct definition is now wrong; if anyone re-runs Task 2, they need
to use the corrected struct.

**For the plan to be re-runnable cleanly,** `2026-05-02-l2x-m94z-richer-context-stage2.md`
Task 2 Step 1 should patch the `rc_cram.h` template and Task 3
Step 1 should patch the `rc_cram_decoder_init`. Not blocking Task 6,
but worth fixing before Stage 2 work resumes.

## How to resume Task 6 (the substantive port)

The next session should:

1. **Read the existing rc_cram.{h,c}** (HEAD `abc17a1`) to understand
   the working API. Don't follow the plan template for these files —
   the committed code is correct.
2. **Read the plan's Task 6** (`docs/superpowers/plans/2026-05-02-l2x-m94z-richer-context-stage2.md`,
   approx line 870-1000). The skeleton there is approximately right;
   any deviations from htscodecs are bugs.
3. **Read htscodecs side-by-side** at
   `tools/perf/htscodecs/htscodecs/fqzcomp_qual.c`. The relevant
   functions are `fqzcomp_qual_compress` and `fqzcomp_qual_uncompress`.
   For Task 6 the implementer hardcodes strategy 1 (HiSeq); auto-tune
   comes in Task 8.
4. **Use the same byte-equality gate pattern** as Phase 1: encode with
   our port + htscodecs (with `--strategy=1`), `cmp` the bytes.
5. **Watch for the same kinds of plan bugs.** The plan was written
   from spec + intuition; htscodecs is the authoritative reference.

The Phase 2 gate test (Task 7) requires the chr22 corpus extracted to
flat byte files. The plan's `extract_chr22_inputs.py` script handles
this.

## Critical environment notes (cooked in to every shell call)

- All shell via `wsl -d Ubuntu -- bash -c '...'` — never run things
  Windows-side that touch WSL paths.
- All paths absolute (`/home/toddw/TTI-O/...`); `$PWD` does NOT
  survive nested `wsl bash -c` (per `feedback_pwd_mangling_in_nested_wsl`).
- After every Edit/Write through `\\wsl.localhost\Ubuntu\...`, strip
  CRLF: `sed -i $'s/\r$//' <file>` and verify
  `tr -cd $'\r' < <file> | wc -c` returns `0`. Per
  `feedback_crlf_on_wsl_clones`.
- Commits use `git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit ...`
  per `feedback_git_commit_identity_msys`.
- Don't push until Task 15. Push via Windows git per
  `feedback_git_push_via_windows`:
  `"/c/Program Files/Git/bin/git.exe" -C "//wsl.localhost/Ubuntu/home/toddw/TTI-O" push origin main`.

## htscodecs vendoring

`tools/perf/htscodecs/` is gitignored; the test-time vendoring is at
SHA `7dd27f4b2bfe0ffdce413337972b3ad68550c3bf` (2026-03-11). If a
fresh checkout doesn't have it, run:

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/tools/perf && git clone --depth 1 https://github.com/samtools/htscodecs.git htscodecs && cd htscodecs && autoreconf -i && ./configure && make -j4'
```

The CRAM RC implementation lives in `tools/perf/htscodecs/htscodecs/c_range_coder.h`
(header-only; no library link needed for that part). The full
`fqzcomp_qual` lives in `tools/perf/htscodecs/htscodecs/fqzcomp_qual.c`.

## Working tree state (as of pause)

- Branch: `main`
- HEAD: `416bf6f` (Task 5 fqzcomp_qual.h scaffolded)
- Working tree clean
- `data/genomic/` corpora (chr22 + WES + HG002 Illumina + HG002 PacBio
  HiFi) are ready and verified by Stage 1 prototype runs
- `native/_build/libttio_rans.so` is built and includes `rc_cram.c`
  (the V4 RC primitives live in the library now)

## Open concerns / risks for resumption

1. **Task 6 is the heaviest port** — ~600 lines of C mirroring
   htscodecs `fqzcomp_qual_compress`. Budget 30-60 min of subagent
   time. The Phase 2 byte-equality gate (Task 7) is the test that
   catches port bugs.
2. **Auto-tune (Task 8) inherits Task 6's correctness.** If Task 6
   has a subtle deviation, Task 8 inherits it; both gates (P2 + P3)
   must pass. Don't skip phases.
3. **PacBio HiFi expectations are calibrated low.** The Phase 5
   results doc must explain that V4 on PacBio HiFi only matches V3
   baseline (~0.40 B/qual) because the auto-tune doesn't help on
   that platform. This is not a bug; it's the empirically-verified
   ceiling.
4. **The plan template has two known bugs** (see "Plan-template bugs
   caught" above). Fix them in Task 6 / Task 7's setup, or ignore
   the plan's specific code blocks and follow htscodecs + the
   committed `rc_cram.{h,c}`.

## Memory updates pending (write on resume)

When Stage 2 fully ships (Task 15), update:
- `project_tti_o_v1_2_codecs.md` — add Stage 2 V4 outcome with per-corpus
  B/qual numbers
- `MEMORY.md` index — V4-shipped status
- WORKPLAN Task #84 — Stage 2 done, Stage 3 (Java/ObjC) pending
