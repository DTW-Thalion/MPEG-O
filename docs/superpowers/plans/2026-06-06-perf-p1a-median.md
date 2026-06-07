# Perf P1a — Median-of-N Gate Robustness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`).

**Goal:** Op-level median-of-N timing in all three perf harnesses (default `--reps 5`), then re-baseline and tighten the regression gate from 50% to ~15%. Perf-tooling only.

**Spec:** `docs/superpowers/specs/2026-06-06-perf-p1a-median-design.md`.

**Run/verify (WSL):** `cd ~/TTI-O`; Python `TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so bash tools/perf/build_and_run_python_full.sh --n 10000 --peaks 16`; Java `JAVA_HOME=~/jdk25 bash tools/perf/build_and_run_java_full.sh --n 10000 --peaks 16`; ObjC `bash tools/perf/build_and_run_objc_full.sh --n 10000 --peaks 16`; all three + compare: `JAVA_HOME=~/jdk25 TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so bash tools/perf/run_perf_ci.sh`. WSL: `wsl -d Ubuntu -- bash -c '<cmd>'`. Commits: `git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit ...`. Editing `tools/perf/*.sh` over the mount drops +x — re-chmod + `git update-index --chmod=+x`. If a Read shows empty, retry or `cat` via wsl.

**CRITICAL repeatability rule (all 3):** the median runs the timed op N times. Pure ops (encode/decode, read) repeat safely. **Mutating ops (file writes, in-place encrypt) must re-target a fresh output per rep or operate on a copy** — otherwise running N times collides/accumulates. For each refactored site, confirm the op is rep-safe; if a site genuinely can't repeat cheaply, leave it single-iteration with a `// reps=1: <reason>` comment.

---

## Task 1: Python median-of-N (`tools/perf/profile_python_full.py`)

**Context:** `_timed(fn, *args, **kwargs)` (lines 115-119) wraps every timed op (`gc.collect()` + `perf_counter` around one `fn` call). All benches call it. Enhance it once.

- [ ] **Step 1: Add a `--reps` flag + module global.** Find the argparse setup (the `--n`/`--peaks`/`--json`/`--out` flags) and add `--reps` (type=int, default=5). Store it where `_timed` can read it (a module global `_REPS`, set from args in `main()` before benches run; default 5).

- [ ] **Step 2: Enhance `_timed` to median-of-N:**
```python
_REPS = 5  # module default; overridden by --reps in main()

def _timed(fn, *args, **kwargs):
    """Run fn once (warmup, discarded) then _REPS times; return (median_seconds, last_result)."""
    fn(*args, **kwargs)  # warmup, discarded
    times = []
    result = None
    for _ in range(_REPS):
        gc.collect()
        t0 = time.perf_counter()
        result = fn(*args, **kwargs)
        times.append(time.perf_counter() - t0)
    times.sort()
    return times[len(times) // 2], result
```
In `main()`, set `global _REPS; _REPS = args.reps` after parsing.

- [ ] **Step 3: Audit repeatability.** Grep every `_timed(` call. For each, confirm `fn` is safe to run N+1 times with the SAME args (encode/decode/read = yes). For any WRITE/mutating call (e.g. a `.tio` write to a fixed path, in-place encrypt), make it rep-safe: wrap in a lambda that writes to a fresh temp path per call, OR if it truncates-on-write (HDF5 create) it's fine — verify. Fix any that would collide. (Most `_timed` calls in this harness are codec encode/decode + reads, which are pure.)

- [ ] **Step 4: Run + sanity.** `cd ~/TTI-O && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so bash tools/perf/build_and_run_python_full.sh --n 10000 --peaks 16` → completes, writes `_out_python_full/full.json` with finite numbers. Also confirm `--reps 1` still works (single iteration). Report a couple of metrics.

- [ ] **Step 5: Commit.**
```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O && git add tools/perf/profile_python_full.py && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "perf(python): median-of-N op timing in harness (--reps, default 5)"'
```

---

## Task 2: Java median-of-N (`tools/perf/ProfileHarnessFull.java`)

**Context:** No central timing helper — ~15 inline `long s = System.nanoTime(); <op>; <metric> = (System.nanoTime()-s)/1e6;` sites (grep `System.nanoTime()`). A startup HotSpot warmup already exists (~line 759) — keep it.

- [ ] **Step 1: Add `--reps` parsing** (default 5) alongside the existing `--n`/`--peaks` flags; store in a field/var `REPS` accessible to the benches.

- [ ] **Step 2: Add the helper:**
```java
/** Run op once (warmup, discarded) then REPS times; return the median elapsed milliseconds. */
static double timedMedianMs(int reps, Runnable op) {
    op.run(); // warmup, discarded
    double[] ms = new double[reps];
    for (int i = 0; i < reps; i++) {
        long s = System.nanoTime();
        op.run();
        ms[i] = (System.nanoTime() - s) / 1e6;
    }
    java.util.Arrays.sort(ms);
    return ms[ms.length / 2];
}
```

- [ ] **Step 3: Refactor each inline timing site** (`grep -n "System.nanoTime()" tools/perf/ProfileHarnessFull.java`) to `<metric> = timedMedianMs(REPS, () -> <op>);`. The op lambda must capture only effectively-final locals — extract setup (data building) OUTSIDE the lambda (it already is; the inline sites time just the op). For checked exceptions inside a lambda, wrap in a try/catch→RuntimeException (mirror the harness's existing style). **Repeatability:** any write/mutating op timed in a lambda must re-target a fresh path per call or be truncate-safe — verify each; leave genuinely-non-repeatable ones at reps=1 with a comment.

- [ ] **Step 4: Build + run.** `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -q -o test-compile` (ensure classes), then `cd ~/TTI-O && JAVA_HOME=~/jdk25 bash tools/perf/build_and_run_java_full.sh --n 10000 --peaks 16` → compiles clean, writes `_out_java_full/full.json` with finite numbers. Confirm `--reps 1` works. Report a couple of metrics.

- [ ] **Step 5: Commit.**
```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O && git add tools/perf/ProfileHarnessFull.java && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "perf(java): median-of-N op timing in harness (--reps, default 5)"'
```

---

## Task 3: ObjC median-of-N (`tools/perf/profile_objc_full.m`)

**Context:** `nowSeconds()` helper (line 53) + `putSeconds(dict,key,secs)` (line 255); ~15 inline `double t0 = nowSeconds(); <op>; putSeconds(out, @"key", nowSeconds()-t0);` sites (grep `nowSeconds()`).

- [ ] **Step 1: Add `--reps` parsing** (default 5) alongside the existing flags; store in a var `gReps` (file-scope) accessible to the benches.

- [ ] **Step 2: Add the helper (after `nowSeconds`):**
```objc
/* Run op once (warmup, discarded) then `reps` times; return the median elapsed seconds. */
static double timedMedian(int reps, void (^op)(void)) {
    op();  // warmup, discarded
    double *t = malloc(sizeof(double) * reps);
    for (int i = 0; i < reps; i++) {
        double t0 = nowSeconds();
        op();
        t[i] = nowSeconds() - t0;
    }
    for (int i = 0; i < reps; i++)        /* simple insertion sort */
        for (int j = i + 1; j < reps; j++)
            if (t[j] < t[i]) { double tmp = t[i]; t[i] = t[j]; t[j] = tmp; }
    double med = t[reps / 2];
    free(t);
    return med;
}
```

- [ ] **Step 3: Refactor each inline timing site** (`grep -n "nowSeconds()" tools/perf/profile_objc_full.m`) from `double t0 = nowSeconds(); <op>; putSeconds(out,@"k",nowSeconds()-t0);` to `putSeconds(out, @"k", timedMedian(gReps, ^{ <op>; }));`. Blocks capture by value; under ARC ensure captured objects stay valid. **Repeatability:** writes/mutating ops in a block must re-target a fresh path per rep or be overwrite-safe — verify; leave non-repeatable ones at reps=1 with a comment. Keep the `nowSeconds`/`putSeconds` helpers.

- [ ] **Step 4: Build + run.** `cd ~/TTI-O && bash tools/perf/build_and_run_objc_full.sh --n 10000 --peaks 16` → compiles + links clean, writes `_out_objc_full/full.json` with finite numbers (all benches incl. encryption). Confirm `--reps 1` works. Report a couple of metrics.

- [ ] **Step 5: Commit.**
```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O && git add tools/perf/profile_objc_full.m && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "perf(objc): median-of-N op timing in harness (--reps, default 5)"'
```

---

## Task 4: Re-baseline, measure drift, tighten threshold, report

**Files:** `tools/perf/baseline.json`; `docs/benchmarks/2026-06-06-perf-refresh.md` (append a P1a section) or a new `docs/benchmarks/2026-06-06-perf-median.md`.

- [ ] **Step 1: Re-capture baseline (median).**
```
cd ~/TTI-O && JAVA_HOME=~/jdk25 TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so bash tools/perf/run_perf_ci.sh --update-baseline
```
Confirm all 3 SDK sections populated (0 null beyond known).

- [ ] **Step 2: Measure post-median drift.** Run `bash tools/perf/run_perf_ci.sh` (no update) TWICE more against the new baseline; record the MAX abs % drift any metric showed across the runs (the compare output's delta column; ignore the `*_mb` size metrics — they're not timings and compare ms-converts them, so exclude them from the drift assessment). This is the empirical residual variance after median-of-5.

- [ ] **Step 3: Set the threshold.** Edit `tools/perf/baseline.json` `_meta.regression_threshold_pct`: set to **15** if the Step-2 max timing drift is comfortably <15; else set to ~2× the observed drift (rounded up) and note the deviation. Update the `_meta.notes` to record median-of-5 + the measured drift + the new threshold (replace the P0 "widened to 50%" note).

- [ ] **Step 4: Confirm the gate is clean + still bites.** `bash tools/perf/run_perf_ci.sh` → exit 0 (within the new threshold; verify via if/then/else to dodge the `$?`-through-wsl artifact: `wsl -d Ubuntu -- bash -c 'cd ~/TTI-O && JAVA_HOME=~/jdk25 TTIO_RANS_LIB_PATH=... bash tools/perf/run_perf_ci.sh >/dev/null 2>&1 && echo CLEAN || echo FAIL'`). Gate-bites: `python3 tools/perf/compare_baseline.py --baseline tools/perf/baseline.json --new tools/perf/_out_python_full/full.json:python --threshold 0.001` inside an if/then/else → confirms non-zero on a trivially-tight threshold.

- [ ] **Step 5: Write the report** — median-based numbers, the measured post-median drift, the new threshold, and that the gate now meaningfully detects regressions. Note `--reps 5` default + `--reps 1` for the old behavior.

- [ ] **Step 6: Commit.**
```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O && git add tools/perf/baseline.json docs/benchmarks/2026-06-06-perf-median.md && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "perf: re-baseline with median-of-5; tighten gate threshold 50%->~15%"'
```

---

## Final verification + landing
- [ ] All 3 harnesses run with `--reps 5` (default) and `--reps 1`; `run_perf_ci.sh` clean against the median baseline at the new threshold; gate still bites on a forced regression.
- [ ] Push (Windows git), open PR vs `main`. The `perf-regression` job runs push-to-main only; the local-baseline CI-calibration caveat still applies (re-baseline from CI artifacts if the first post-merge run flags env variance). Merge once green, sync main.
- [ ] Update memory (`feedback_perf_suite_broken_ci_noop`): P1a done — median-of-5, threshold ~15%; remaining P1b–e.
