# TTI-O Performance-Suite Analysis & Verification — 2026-06-06

Analysis of the performance testing suites across all three SDKs (Python / Java / ObjC) at
`main` (`80422888`), assessing end-to-end coverage and the validity of current numbers.
Triggered by: "large number of changes since the last performance tests — do we have proper
coverage of end-to-end functions, and we need updated numbers."

> **Headline: the perf suite is currently BROKEN and the CI perf gate is a silent no-op.**
> The *design* coverage is broad, but the harness no longer runs (hardcoded paths in CI;
> import-rot against the v2 codecs locally), and the regression gate reports green while
> executing nothing. There are **no trustworthy current numbers** — the last real data is
> the baseline from **2026-04-27/04-30**, which can no longer be reproduced against current
> code. Repair is required before updated numbers can be produced.

## 1. Infrastructure overview
- **Central cross-SDK harness** `tools/perf/`: `profile_{python,java,objc}_full` (15 identical
  scenarios each) → JSON; `compare_baseline.py` diffs each SDK's run against its section of
  `tools/perf/baseline.json` at a ±10% threshold; `run_perf_ci.sh` orchestrates all three.
- **CI `perf-regression` job** (`.github/workflows/ci.yml:520`): runs `run_perf_ci.sh` on
  **push-to-main only**; gates **all three** SDKs (the "Python + ObjC" name and the
  `run_perf_ci.sh` "Java absent" comment are both stale — Java was wired in via the P2
  follow-up).
- **Monthly full-corpus stress** (`ci.yml:292`, cron 1st-of-month): Python real-BAM
  benchmarks (`test_production_corpus_benchmark.py`, `test_fasta_fastq_benchmark.py`) —
  informational, skips if the corpus isn't on disk, no baseline comparison.
- **Per-SDK extras:** Python `tests/perf/` (`test_m94z_throughput`, `test_m95_throughput`,
  marker-gated) + `tests/stress/`; Java `Benchmark.java` (transport per-AU+bulk JSON),
  `FastaImportBench`, opt-in JUnit benches; ObjC `TtioBenchmark`/`TtioFastqBench`/
  `TtioTransportEncodeBench` tools + `TestM94ZFqzcompPerf` + `TestStress` `[obj-bench]` prints.

## 2. Critical findings — the suite does not run

### F-PERF-1 — the CI perf-regression gate is a silent no-op
The job step is `tools/perf/run_perf_ci.sh | tee perf-report.md` (`ci.yml:600`). `run_perf_ci.sh`
runs `set -euo pipefail`, so a failing leg aborts it with a non-zero exit — but piping to
`tee` makes the **pipeline's** exit status that of `tee` (0), and GitHub Actions' default
`run:` shell does **not** enable `pipefail`, so the step (and job) reports **success**
regardless. Evidence from the latest main run (`27075934272`, job `79913615491`):
```
[perf-ci] running Python harness...
[run] python3 /home/runner/TTI-O/tools/perf/profile_python_full.py ...
python3: can't open file '/home/runner/TTI-O/tools/perf/profile_python_full.py': [Errno 2] No such file or directory
```
…and the uploaded `perf-report.md` artifact is **275 bytes** (just the banner line). The job
has been green while measuring nothing.

### F-PERF-2 — hardcoded `$HOME/TTI-O` path breaks the harness in CI
`tools/perf/build_and_run_python_full.sh:13` hardcodes `ROOT="$HOME/TTI-O"` (the ObjC/Java
wrappers do the same). On the dev box `$HOME/TTI-O` = `/home/toddw/TTI-O` (correct); in CI
`$HOME` = `/home/runner` but the checkout is at `/home/runner/work/TTI-O/TTI-O`, so the
script path resolves to a nonexistent file → "No such file or directory". The harness can
**never** find itself in CI. Fix: derive the root from the script location
(`here="$(cd "$(dirname "$0")"/../.. && pwd)"`) or `git rev-parse --show-toplevel`.

### F-PERF-3 — harness import-rot: references removed v1 codecs
Even with the right path (the dev box), `profile_python_full.py` fails to import:
```
ImportError: cannot import name 'name_tokenizer' from 'ttio.codecs'
```
It imports the v1 codecs that were **removed** in favor of v2:
- `from ttio.codecs import name_tokenizer` → now `name_tokenizer_v2` (codec id 8 → 15).
- `from ttio.codecs.ref_diff import encode, decode` → now `ref_diff_v2` (codec id 9; **different
  API — needs an embedded reference**).
The Java (`ProfileHarnessFull.java`) and ObjC (`profile_objc_full.m`) harnesses bench the same
v1 `REF_DIFF`/`NAME_TOKENIZED` scenarios and very likely share this rot (to confirm during
repair). Net: the harness is un-runnable on current `main` without porting these benches to
the v2 codec APIs.

### F-PERF-4 — baseline is stale and now un-reproducible
`tools/perf/baseline.json` `_meta.generated_at` = **2026-04-27** (genomic/streaming added
**2026-04-30**). Because of F-PERF-2/3 it cannot be re-captured against current code without
repair, so it is frozen pre-codec-registry. Perf-affecting changes landed since and are
**not** reflected: #217 (vectorize DELTA_RANS + cache signal-channels handle, Python), #218
(vectorize GenomicIndex region/flag queries, Java/ObjC), #202 (vectorize region queries),
#209–#211 (codec **registry** dispatch layer, all 3 SDKs), #230 (transport split into
reader/writer/common), #242 (fqzcomp dead-code removal), #199/#200 (encrypted-read metadata).

## 3. End-to-end coverage assessment (design intent, once repaired)
The harness *design* is broad and genuinely end-to-end, not micro-ops only:

| Capability | Covered? | SDKs | Notes |
|------------|----------|------|-------|
| `.tio` write (create + HDF5) | ✅ | all 3 | + Memory/SQLite/Zarr (ObjC: HDF5 only; others `null`) |
| `.tio` read / iterate | ✅ | all 3 | + genomic random-access p50/p99 |
| Transport encode/decode | ✅ | all 3 | plain + compressed; Java/ObjC also per-AU + bulk |
| Per-AU + bulk encryption | ✅ | all 3 | AES-256-GCM, two sizes |
| Codec throughput | ⚠️ | all 3 | rANS, BASE_PACK, QUALITY_BINNED, DELTA_RANS, fqzcomp V4, **+ the broken v1 REF_DIFF/NAME_TOKENIZED** |
| Streaming, JCAMP, HMAC sign | ✅ | all 3 | |
| **Real-format import** (FASTA/FASTQ/BAM/CRAM/mzML/nmrML/imzML/Bruker) | ❌ | — | **mzML/nmrML/imzML/Bruker: none anywhere.** BAM only Python-only + skip-gated + ungated monthly. FASTA/FASTQ only manual/opt-in tools, not in the gate. CRAM: none |
| **PQC sign/verify** (ML-DSA-87) | ❌ | — | only HMAC-SHA256 benchmarked |
| **`mate_info_v2` codec** | ❌ | — | not isolated in any SDK |
| **`name_tokenizer_v2` / `ref_diff_v2`** | ❌ (gate) | — | only v1 in the harness (broken); v2 via standalone CLIs only |
| **Chained real pipeline** (BAM → .tio → .tis → read) | ❌ | — | the BAM E2E and the transport bench never connect |
| **Cross-SDK perf parity** | ❌ | — | each SDK only diffs vs its own baseline |

So even after repair, the **coverage gaps** are: real-format import perf (esp. mzML/nmrML/
Bruker, and BAM in a gated cross-SDK way), PQC, mate_info_v2, the v2 name/ref codecs in the
gate, a chained real-data pipeline, and cross-SDK parity.

## 4. Recommendations (prioritized)

### P0 — make the suite run and re-baseline (required for "updated numbers")
- **R-PERF-1:** Fix the hardcoded `$HOME/TTI-O` in all three `build_and_run_*_full.sh` —
  derive the repo root from the script location.
- **R-PERF-2:** Remove the exit-masking in CI — drop the `| tee` (or set `shell: bash` with
  `pipefail`, or `set -o pipefail`) so a failing/empty perf run actually fails the job. Add a
  guard that fails if any expected `full.json` is missing/empty.
- **R-PERF-3:** Port the broken v1 codec benches to v2 across all three harnesses
  (`name_tokenizer` → `name_tokenizer_v2`; `ref_diff` → `ref_diff_v2`, supplying the reference
  the v2 API needs). Confirm/repair the Java + ObjC harnesses likewise.
- **R-PERF-4:** Re-capture `tools/perf/baseline.json` on current `main`
  (`run_perf_ci.sh --update-baseline`) → the updated numbers, and refresh
  `docs/benchmarks/` with a new comprehensive report.

### P1 — close the coverage gaps
- **R-PERF-5:** Add gated cross-SDK **real-format import** benches — at minimum BAM (already
  have corpora) and mzML/nmrML; consider a chained "BAM → .tio → .tis → read" pipeline.
- **R-PERF-6:** Add **PQC sign/verify** (ML-DSA-87) and **`mate_info_v2`** throughput benches.
- **R-PERF-7:** Add a **cross-SDK perf-parity** check (compare SDK-vs-SDK, not just
  SDK-vs-own-baseline) for the shared scenarios.

### P2 — hygiene
- **R-PERF-8:** Rename the CI job (drop "Python + ObjC") and the stale `run_perf_ci.sh`
  comment; both already gate Java.
- **R-PERF-9:** Consider a fast perf **smoke on PRs** (a 1-2 scenario subset) so gross
  regressions are caught before merge, not only post-merge on main.
- **R-PERF-10:** Restore the executable bit on `tools/perf/*.sh` (lost on `\\wsl.localhost`
  checkouts) — CI already `chmod +x`es them, but local runs need it.

## 5. How to get updated numbers (after P0 repair)
Fully offline / synthetic, ~3–5 min:
```bash
cd ~/TTI-O
(cd java && JAVA_HOME=~/jdk25 mvn -q test-compile \
   && mvn -q dependency:build-classpath -Dmdep.outputFile=target/runtime-classpath.txt)
bash tools/perf/run_perf_ci.sh                 # diff vs baseline
bash tools/perf/run_perf_ci.sh --update-baseline   # accept new numbers
```
Prereqs: Python `.venv` + `TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so`;
Java JDK + `jarhdf5.jar` + HDF5 JNI; ObjC GNUstep + built `libTTIO`. The monthly real-BAM
corpus is the only piece needing downloaded data.

## 6. Bottom line
- **Coverage of end-to-end functions:** the harness *design* covers the core spectral +
  genomic pipelines end-to-end across all three SDKs, but with real gaps (real-format import,
  PQC, mate_info_v2, cross-SDK parity).
- **Updated numbers:** **not currently obtainable** — the harness is broken (hardcoded CI
  path + v1-codec import rot) and the CI gate has been silently passing while running nothing.
  Producing trustworthy updated numbers requires the P0 repair first.
