# Perf-Suite Repair P0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make the cross-SDK perf harness run on any checkout, make the CI perf gate actually fail on a broken/regressed run, port the v1→v2 codec benches in all three harnesses, and re-capture `tools/perf/baseline.json` → updated numbers. Perf-tooling + CI only; no SDK product code.

**Spec:** `docs/superpowers/specs/2026-06-06-perf-repair-p0-design.md`. **Analysis:** `docs/architecture/2026-06-06-perf-suite-analysis.md`.

**Run/verify (WSL):** `cd ~/TTI-O && bash tools/perf/run_perf_ci.sh` (offline/synthetic, ~3-5 min). Per-SDK: `bash tools/perf/build_and_run_{python,java,objc}_full.sh --n 10000 --peaks 16`. Set `TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so`, `JAVA_HOME=~/jdk25`. WSL: `wsl -d Ubuntu -- bash -c '<cmd>'`. Commits: `git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit ...`. If a Read shows empty (mount glitch), retry or `cat` via wsl. NOTE: editing `tools/perf/*.sh` over the `\\wsl.localhost` mount drops the +x bit — re-`chmod +x` and `git update-index --chmod=+x` before committing.

**Confirmed facts:** v1 codecs deleted in all 3 SDKs; only v2 exist (Python `name_tokenizer_v2`/`ref_diff_v2`, Java `NameTokenizerV2`/`RefDiffV2`, ObjC `TTIONameTokenizerV2`/`TTIORefDiffV2`). `name_tokenizer_v2` is a drop-in (`encode(names)`/`decode(blob)`). `ref_diff_v2` differs: Python `encode(sequences:uint8 ndarray, offsets:uint64 n+1, positions:int64, cigar_strings, reference:bytes, reference_md5:16B, reference_uri:str)`, `decode(encoded, positions, cigar_strings, reference, n_reads)`.

---

## Task 1: Infrastructure — script-relative paths + CI gate that bites

**Files:**
- Modify: `tools/perf/build_and_run_python_full.sh`, `build_and_run_java_full.sh`, `build_and_run_objc_full.sh`
- Modify: `tools/perf/run_perf_ci.sh`
- Modify: `.github/workflows/ci.yml` (perf-regression step + job name)

- [ ] **Step 1: Script-relative ROOT in all 3 wrappers.** In each `build_and_run_*_full.sh`, replace the hardcoded `ROOT="$HOME/TTI-O"` with:
```bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
```
(`${BASH_SOURCE[0]}` = the script path; `../..` from `tools/perf/` = repo root.) Leave the rest of each wrapper unchanged.

- [ ] **Step 2: `run_perf_ci.sh` — fail on missing/empty output + fix stale comment.** After the harness runs and before/at the compare, add a guard: for each SDK that ran (`run_python`/`run_objc`/`run_java`), assert its `full.json` exists and is non-empty, else `echo` an error and `exit 1`. Example, before building `new_args`:
```bash
for pair in "python:$PYTHON_OUT" "objc:$OBJC_OUT" "java:$JAVA_OUT"; do
    lang="${pair%%:*}"; dir="${pair#*:}"
    eval "ran=\$run_$lang"
    if [ "$ran" = "1" ] && [ ! -s "$dir/full.json" ]; then
        echo "[perf-ci] ERROR: $lang harness produced no $dir/full.json" >&2
        exit 1
    fi
done
```
Also fix the stale header comment ("Java is intentionally absent in v1") to state all three SDKs run and are gated.

- [ ] **Step 3: CI step — stop masking the exit code.** In `.github/workflows/ci.yml`, the perf-regression "Run perf harness…" step (~line 594-600), change the `run:` so the harness exit propagates:
```yaml
      - name: Run perf harness + compare against baseline
        shell: bash
        run: |
          chmod +x tools/perf/*.sh
          set -o pipefail
          tools/perf/run_perf_ci.sh 2>&1 | tee perf-report.md
```
(`set -o pipefail` makes the pipeline take `run_perf_ci.sh`'s non-zero exit; `shell: bash` ensures pipefail support.) Keep the "Upload perf report" step.

- [ ] **Step 4: Rename the CI job.** Change `name:` (line ~521) from "Performance regression check (Python + ObjC, push-to-main only)" to "Performance regression check (all SDKs, push-to-main only)".

- [ ] **Step 5: Restore +x + commit.** (Don't run the full harness yet — codec ports come next; the wrappers will still fail to produce JSON until Tasks 2-4. This task is the infra scaffolding.)
```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O && chmod +x tools/perf/*.sh && git add tools/perf/build_and_run_python_full.sh tools/perf/build_and_run_java_full.sh tools/perf/build_and_run_objc_full.sh tools/perf/run_perf_ci.sh .github/workflows/ci.yml && for f in tools/perf/build_and_run_python_full.sh tools/perf/build_and_run_java_full.sh tools/perf/build_and_run_objc_full.sh tools/perf/run_perf_ci.sh; do git update-index --chmod=+x $f; done && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "perf(ci): script-relative harness paths + make perf gate fail on broken/empty runs"'
```
Verify the committed wrappers are mode 100755: `git ls-files -s tools/perf/*.sh`.

---

## Task 2: Python harness v1→v2 codec port

**Files:**
- Modify: `tools/perf/profile_python_full.py`

**Context:** Imports `from ttio.codecs import name_tokenizer as _nt` (line 69) and `from ttio.codecs.ref_diff import encode as _ref_diff_encode, decode as _ref_diff_decode` (line 74). The ref_diff bench (lines 448-470) builds `sequences_rd: list[bytes]`, `cigars_rd: list[str]`, `positions_rd: sorted list[int]`, `ref_seq: bytes`, `ref_md5 = hashlib.md5(ref_seq).digest()`, and calls `_ref_diff_encode(sequences_rd, cigars_rd, positions_rd, ref_seq, ref_md5, "perf-ref")` / `_ref_diff_decode(rd_encoded, cigars_rd, positions_rd, ref_seq)`. The name-tok bench (lines 404-405) calls `_nt.encode(names)` / `_nt.decode(nt_enc)`.

- [ ] **Step 1: Read** `python/src/ttio/codecs/ref_diff_v2.py` (encode lines 77-128, decode 131+) and `name_tokenizer_v2.py` to confirm exact signatures.

- [ ] **Step 2: Update imports** (lines 69, 74):
```python
from ttio.codecs import name_tokenizer_v2 as _nt
from ttio.codecs.ref_diff_v2 import encode as _ref_diff_encode, decode as _ref_diff_decode
```
(`name_tokenizer_v2.encode/decode` match the v1 call sites — no other name-tok change needed.)

- [ ] **Step 3: Port the ref_diff bench to v2 inputs** (lines ~466-470). `ref_diff_v2.encode` needs a flat uint8 sequences array + offsets (n+1) + int64 positions + reference_uri. Replace the encode/decode calls with:
```python
    # ref_diff_v2 wants a flat uint8 sequences array + offsets(n+1).
    seq_flat = np.frombuffer(b"".join(sequences_rd), dtype=np.uint8)
    offsets_rd = np.zeros(n_reads_rd + 1, dtype=np.uint64)
    offsets_rd[1:] = np.cumsum([len(sq) for sq in sequences_rd], dtype=np.uint64)
    positions_arr = np.asarray(positions_rd, dtype=np.int64)
    t_rd_enc, rd_encoded = _timed(
        _ref_diff_encode, seq_flat, offsets_rd, positions_arr,
        cigars_rd, ref_seq, ref_md5, "synthetic://perf-ref")
    t_rd_dec, _ = _timed(
        _ref_diff_decode, rd_encoded, positions_arr, cigars_rd, ref_seq, n_reads_rd)
```
Ensure `import numpy as np` and `import hashlib` are present (hashlib already used at line 451). Keep the scenario keys (`ref_diff_encode`/`ref_diff_decode`) and the `raw_mb_rd` print unchanged.

- [ ] **Step 4: Run the Python harness alone.**
```
cd ~/TTI-O && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so bash tools/perf/build_and_run_python_full.sh --n 10000 --peaks 16
```
Expected: completes, prints the bench table including `[genomic codec] ref_diff ...` and `name_tk ...`, and writes `tools/perf/_out_python_full/full.json`. Confirm the JSON has `ref_diff_encode`/`ref_diff_decode`/`name_tokenized_encode`/`name_tokenized_decode` keys with finite values: `wsl -d Ubuntu -- bash -c "python3 -c \"import json;d=json.load(open('/home/toddw/TTI-O/tools/perf/_out_python_full/full.json'));print({k:v for k,v in d.get('results',d).items() if 'ref_diff' in str(k) or 'name_tok' in str(k)})\""` (adjust to the JSON's actual shape).

- [ ] **Step 5: Commit.**
```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O && git add tools/perf/profile_python_full.py && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "perf(python): port harness ref_diff/name_tokenizer benches to v2 codecs"'
```

---

## Task 3: Java harness v1→v2 codec port

**Files:**
- Modify: `tools/perf/ProfileHarnessFull.java`

**Context:** Lines 435/438 call `global.thalion.ttio.codecs.NameTokenizer.encode(names)`/`.decode(...)`; lines 482/487 call `global.thalion.ttio.codecs.RefDiff.encode(...)`/`.decode(...)`. Only `NameTokenizerV2`/`RefDiffV2` exist now. The harness is a standalone `.java` compiled against `java/target/classes` + `runtime-classpath.txt`.

- [ ] **Step 1: Read** `java/src/main/java/global/thalion/ttio/codecs/NameTokenizerV2.java` and `RefDiffV2.java` — confirm the static method names + signatures (esp. RefDiffV2.encode's parameters: it likely needs sequences/offsets/positions/cigars/reference/md5/uri analogous to Python, OR a different shape — match exactly). Also read `ProfileHarnessFull.java` lines ~420-490 (the codec + genomic-codec bench bodies) to see how `names`, `sequencesRd`, `cigarsRd`, `positionsRd`, `refSeq` are currently built.

- [ ] **Step 2: Port name_tokenizer** — replace `NameTokenizer.encode/decode` with `NameTokenizerV2.encode/decode` (drop-in if signatures match; adjust if V2 differs).

- [ ] **Step 3: Port ref_diff** — replace `RefDiff.encode/decode` with `RefDiffV2.encode/decode`, building whatever extra inputs V2 needs (offsets n+1, reference md5, reference URI) from the synthetic reads already constructed in the bench, mirroring the Python port. Compute the MD5 via `java.security.MessageDigest.getInstance("MD5")`. Keep the scenario keys (`ref_diff_encode`/`ref_diff_decode`, `name_tokenized_encode`/`name_tokenized_decode`) unchanged.

- [ ] **Step 4: Build + run the Java harness.** First ensure classpath: `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -q -o test-compile && (mvn -q -o dependency:build-classpath -Dmdep.outputFile=target/runtime-classpath.txt || mvn -q dependency:build-classpath -Dmdep.outputFile=target/runtime-classpath.txt)`. Then:
```
cd ~/TTI-O && JAVA_HOME=~/jdk25 bash tools/perf/build_and_run_java_full.sh --n 10000 --peaks 16
```
Expected: compiles cleanly (no `NameTokenizer`/`RefDiff` symbol errors), runs, writes `tools/perf/_out_java_full/full.json` with the codec keys populated.

- [ ] **Step 5: Commit.**
```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O && git add tools/perf/ProfileHarnessFull.java && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "perf(java): port harness ref_diff/name_tokenizer benches to v2 codecs"'
```

---

## Task 4: ObjC harness v1→v2 codec port

**Files:**
- Modify: `tools/perf/profile_objc_full.m`

**Context:** Imports `Codecs/TTIONameTokenizer.h` + `Codecs/TTIORefDiff.h` (lines 992-993, deleted); calls `TTIONameTokenizerEncode(names)`/`TTIONameTokenizerDecode(...)` (1057-1061) and `[TTIORefDiff encodeWithSequences:...]`/`[TTIORefDiff decodeData:...]` (1127-1139). Only `TTIONameTokenizerV2`/`TTIORefDiffV2` exist. The harness compiles via `build_and_run_objc_full.sh` (clang + GNUstep, links libTTIO).

- [ ] **Step 1: Read** `objc/Source/Codecs/TTIONameTokenizerV2.h` and `TTIORefDiffV2.h` — confirm the function/method names + signatures (V2 name-tokenizer: is it `TTIONameTokenizerV2Encode(...)` C funcs or a class? V2 ref-diff: the `encodeWithSequences:...` selector + what extra args it needs). Read `profile_objc_full.m` lines ~990-1145 for how `names`/`sequences`/`cigars`/`positions`/`reference` are built.

- [ ] **Step 2: Update imports** — `#import "Codecs/TTIONameTokenizerV2.h"` + `#import "Codecs/TTIORefDiffV2.h"`.

- [ ] **Step 3: Port name_tokenizer** — replace `TTIONameTokenizerEncode/Decode` with the V2 equivalents (match the V2 header's symbol names).

- [ ] **Step 4: Port ref_diff** — replace `[TTIORefDiff encodeWithSequences:...]`/`decodeData:` with the `TTIORefDiffV2` API, supplying the extra V2 inputs (offsets, reference md5 via `CC_MD5`/openssl, reference URI) built from the synthetic reads. Keep scenario keys (`name_tokenized_*`, `ref_diff_*`).

- [ ] **Step 5: Build + run the ObjC harness.**
```
cd ~/TTI-O && bash tools/perf/build_and_run_objc_full.sh --n 10000 --peaks 16
```
Expected: compiles cleanly (no `TTIONameTokenizer`/`TTIORefDiff` symbol errors), runs, writes `tools/perf/_out_objc_full/full.json` with codec keys populated.

- [ ] **Step 6: Commit.**
```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O && git add tools/perf/profile_objc_full.m && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "perf(objc): port harness ref_diff/name_tokenizer benches to v2 codecs"'
```

---

## Task 5: Re-capture baseline + numbers report

**Files:**
- Modify: `tools/perf/baseline.json`
- Create: `docs/benchmarks/2026-06-06-perf-refresh.md`

**Context:** Tasks 1-4 make all three harnesses run. Now capture fresh numbers as the new baseline and document them.

- [ ] **Step 1: Full run + capture baseline.** Ensure Java classpath exists (Task 3 Step 4). Then:
```
cd ~/TTI-O && JAVA_HOME=~/jdk25 TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so bash tools/perf/run_perf_ci.sh --update-baseline
```
This runs all three harnesses and overwrites `tools/perf/baseline.json` with current numbers. Confirm all three SDK sections are populated (no harness silently skipped).

- [ ] **Step 2: Verify the gate is clean against the new baseline.** Run `bash tools/perf/run_perf_ci.sh` (no `--update-baseline`) → expect exit 0, "no regression" (since baseline == this run, modulo run-to-run jitter; if jitter trips a metric, that's expected noise — note it).

- [ ] **Step 3: Gate-bites proof.** Temporarily rename one harness output (`mv tools/perf/_out_python_full/full.json /tmp/`) and run `bash tools/perf/run_perf_ci.sh`; confirm it now EXITS NON-ZERO (the missing-json guard from Task 1 Step 2 fires). Restore the file (re-run the python harness or move it back).

- [ ] **Step 4: Write the numbers report** `docs/benchmarks/2026-06-06-perf-refresh.md`: per-SDK table of the new `baseline.json` numbers (ms) for the key scenarios (ms.hdf5, transport.plain/compressed, encryption, codecs, codecs.genomic incl. the now-v2 ref_diff/name_tokenized, genomic write/read/random-access, streaming), with deltas vs the prior 2026-04-27/30 baseline where comparable. Note: ref_diff/name_tokenized now measure the **v2** codecs (not directly comparable to the old v1 numbers — flag this). Record the run environment (WSL2, JDK 25, single-core) and that numbers are dev-box local.

- [ ] **Step 5: Commit.**
```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O && git add tools/perf/baseline.json docs/benchmarks/2026-06-06-perf-refresh.md && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "perf: re-capture baseline on current main + refresh numbers report"'
```

---

## Final verification + landing
- [ ] `cd ~/TTI-O && JAVA_HOME=~/jdk25 TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so bash tools/perf/run_perf_ci.sh` → all 3 SDK harnesses run, compare clean (exit 0).
- [ ] Push (Windows git), open PR vs `main`. **Watch the perf-regression job specifically** — it now actually runs in CI. If it flags variance-only "regressions" (CI runner slower than the local baseline by >10%), that's the documented local-baseline caveat: re-baseline from the CI run's uploaded `full.json` artifacts (`gh run download <run> -n perf-report`, then `--update-baseline` with those, commit). If the ObjC job hangs on `setup-libarrow`, cancel + `gh run rerun --failed`. Merge once green, sync main.
- [ ] Update memory (`feedback_perf_suite_broken_ci_noop` → mark P0 fixed; note P1 next).
