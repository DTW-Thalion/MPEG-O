# P3.11 — Encapsulation parity — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Close three encapsulation gaps (Python `Run` Provisional→Stable; Python `SignalArray.data` read-only zero-copy view; Java `SignalArray.asX()` defensive clone), bringing Python+Java in line with ObjC (already compliant). No `.tio`/wire/API-shape change — only return-value immutability semantics.

**Architecture:** Two PRs — PR-1 Python, PR-2 Java — each its own branch off main, CI-green, merged before the next. Spec: `docs/superpowers/specs/2026-06-05-p3-11-encapsulation-parity-design.md`.

**Tech Stack:** Python 3.12 / pytest; Java 22 / Maven / JUnit (jacoco ≥0.84).

**Environment / commands:**
- Python: `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest <args> -q` (use `.venv/bin/python` for scripts).
- Java: `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -B test` (fast) / `verify` (jacoco gate).
- Commit: `git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit`.
- Push from Windows git: `"/c/Program Files/Git/bin/git.exe" -C //wsl.localhost/Ubuntu/home/toddw/TTI-O push -u origin <branch>`.
- Branch `p3-11-encapsulation-parity` is created (carries the spec + plan + PR-1). PR-2 branches fresh off main after PR-1 merges. **Always `git fetch` before `reset --hard origin/main`.** Local cross-language tests fail on the known JDK 21-vs-22 env issue — CI is the gate; confirm no PURE-language regressions.

**Verified facts:**
- `python/src/ttio/signal_array.py`: `@dataclass(slots=True)` (NOT frozen), no existing `__post_init__`. Fields: `data: np.ndarray` (line 44), `encoding` (46), `cv_params` (47). `from_numpy` (85) returns `cls(data=np.ascontiguousarray(array), ...)` (lines 117-118).
- Direct `SignalArray(data=...)` constructions: `importers/import_result.py:110-111` (passes caller arrays directly, no copy), `acquisition_run.py:853-854` (passes `.copy()`).
- Internal `.data` access in codec/transport: ONLY reads — `transport/encrypted.py:947-949` slice `ch.data[:12]`/`[12:28]`/`[28:]` (read). No in-place writes found in `src/`.
- `python/src/ttio/protocols/run.py:17`: `API status: Provisional (Phase 1 abstraction polish, post-M91).` `Run` is `@runtime_checkable` Protocol.
- Java `SignalArray.java`: `asDoubles()` (~:102) `if (buffer instanceof double[] d) return d;` + `throw new ClassCastException(...)`; same shape for `asFloats`/`asInts`/`asLongs`. `buffer()` (~:84) returns raw `buffer` (documented escape — LEAVE).

**Hard invariants:** No `.tio`/wire/API-shape change. `asDoubles()` still returns `double[]`; `sa.data` still an `np.ndarray`. Only mutation-through-returned-array is closed. Cross-language conformance + suites green.

---

### Task 1 (PR-1): Python — `Run` Stable + read-only `SignalArray.data`

**Files:**
- Modify: `python/src/ttio/protocols/run.py`
- Modify: `python/src/ttio/signal_array.py`
- Test: `python/tests/test_p3_11_signal_array_readonly.py` (new)

- [ ] **Step 1: Baseline.** `...pytest tests/test_value_classes.py tests/test_signal_array*.py tests/test_spectrum*.py tests/test_run_protocol.py -q` (adjust globs to real filenames via `ls tests | grep -iE "signal|spectrum|run_protocol|value"`). Record green count. Also full-suite baseline failure set: `...pytest -q 2>&1 | grep -E "^FAILED" | sed 's|::.*||' | sort -u` (the known JDK/xlang env set).

- [ ] **Step 2: Write the failing test** `tests/test_p3_11_signal_array_readonly.py`:
```python
"""P3.11: SignalArray.data is a read-only (writeable=False) zero-copy view."""
import numpy as np
import pytest
from ttio.signal_array import SignalArray


def test_from_numpy_data_is_read_only():
    sa = SignalArray.from_numpy(np.arange(8, dtype="<f8"))
    assert sa.data.flags.writeable is False
    with pytest.raises(ValueError):
        sa.data[0] = 99.0


def test_direct_construction_data_is_read_only():
    sa = SignalArray(data=np.arange(4, dtype="<f8"))
    assert sa.data.flags.writeable is False
    with pytest.raises(ValueError):
        sa.data[1] = 1.0


def test_freeze_does_not_freeze_caller_array():
    src = np.arange(5, dtype="<f8")
    SignalArray(data=src)
    # constructing a SignalArray must not freeze the caller's own array
    src[0] = 42.0  # must NOT raise
    assert src[0] == 42.0


def test_values_preserved():
    src = np.array([1.5, 2.5, 3.5], dtype="<f8")
    sa = SignalArray.from_numpy(src)
    assert np.array_equal(sa.data, src)
```
Run it → FAILS (data currently writeable).

- [ ] **Step 3: Study** `signal_array.py` — confirm `slots=True`, the field order, and that `from_numpy` is the only classmethod constructor. Confirm no `__post_init__` exists.

- [ ] **Step 4: Implement the freeze** in `signal_array.py`. Add a `__post_init__` after the fields:
```python
def __post_init__(self) -> None:
    # P3.11: store `data` as a zero-copy read-only view so callers
    # cannot mutate this value object in place. A view (not a copy)
    # preserves zero-copy; a caller retaining the source array keeps
    # its own writeable flag (we freeze our view, not their array).
    arr = np.ascontiguousarray(self.data)
    if arr is self.data:
        arr = arr.view()
    arr.flags.writeable = False
    self.data = arr
```
(`slots=True` + non-frozen → plain `self.data = arr` works.) Update the `data` field docstring (~line 21/44) to note it is read-only. Optionally simplify `from_numpy` to `cls(data=array, ...)` (drop its now-redundant `np.ascontiguousarray`, since `__post_init__` handles contiguity) — only if it stays a behavior-preserving simplification; otherwise leave it (the double call is a harmless no-op).

- [ ] **Step 5: Run the new test** → all 4 pass. Then the Step-1 baseline set → still green.

- [ ] **Step 6: Audit internal mutation.** `grep -rn "\.data\[" python/src/ttio --include=*.py | grep -vE "test|\.data\[[^]]*\]\s*$|=\s*[a-z]" ` is noisy — instead grep for WRITES: `grep -rn "\.data\[.*\]\s*=\|\.data\s*+=\|\.data\s*\*=\|out=.*\.data\|\.data\.sort(\|\.data\.fill(" python/src/ttio --include=*.py`. Expected: none (the only `.data[...]` hits are read-slices in `transport/encrypted.py`). If any WRITE to a SignalArray's `.data` exists, refactor that site to build the ndarray fully BEFORE constructing the SignalArray (or operate on a local copy). Re-run the relevant suite.

- [ ] **Step 7: Promote `Run` to Stable.** In `protocols/run.py`, change line 17 `API status: Provisional (Phase 1 abstraction polish, post-M91).` → `API status: Stable.`. Grep for other "provisional" wording about Run: `grep -rni "run.*provisional\|provisional.*run" python/src docs --include=*.py --include=*.md` and update any that describe the `Run` protocol as provisional/unenforced (it is `@runtime_checkable`). Confirm the Protocol's declared methods all exist on `AcquisitionRun` + `GenomicRun` (quick check so "Stable" is honest).

- [ ] **Step 8: (Secondary, opportunistic)** `grep -rn "return self\._\?[a-z_]*\b" python/src/ttio/genomic_run.py python/src/ttio/acquisition_run.py` + image-cube accessors — identify any PUBLIC accessor returning a raw internal `np.ndarray` aliased to state. For a clearly-safe case, apply the same `writeable=False` view. If risky/ambiguous, SKIP and note it in the PR description as a follow-up — do NOT expand scope.

- [ ] **Step 9: Full suite + coverage.** `...pytest -q 2>&1 | tail -3` → only the known JDK/xlang env failures (same set as Step 1). Fix any pure-Python regression (most likely a test that mutated `sa.data` — update it to not mutate, since that was the anti-pattern). `...pytest --cov=ttio --ignore=tests/conformance --ignore=tests/integration --ignore=tests/validation -q 2>&1 | grep -i TOTAL` → report % (≥84 on CI).

- [ ] **Step 10: CHANGELOG + commit.** CHANGELOG `## [Unreleased]` `### Changed`: `SignalArray.data` is now a read-only zero-copy view (`flags.writeable=False`); the `Run` protocol is promoted from Provisional to Stable. No wire/API-shape change. (OO-assessment P3.11.) Commit `refactor(p3.11): read-only SignalArray.data view + promote Run to Stable (Python)`.

---

### Task 2 (PR-2): Java — `SignalArray.asX()` defensive clone

**Files:**
- Modify: `java/src/main/java/global/thalion/ttio/SignalArray.java`
- Test: `java/src/test/java/global/thalion/ttio/SignalArrayEncapsulationTest.java` (new)

- [ ] **Step 1: Baseline.** `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -B test 2>&1 | tail -8` → BUILD SUCCESS + "Tests run: N, Failures: 0". Record N.

- [ ] **Step 2: Write the failing test** `SignalArrayEncapsulationTest.java` (package `global.thalion.ttio`):
```java
package global.thalion.ttio;

import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.Test;

class SignalArrayEncapsulationTest {
    @Test void asDoublesReturnsDefensiveCopy() {
        SignalArray sa = SignalArray.ofDoubles(new double[]{1.0, 2.0, 3.0});
        double[] a = sa.asDoubles();
        a[0] = 999.0;
        assertEquals(1.0, sa.asDoubles()[0], 0.0,
            "mutating the returned array must not affect the SignalArray");
    }

    @Test void asFloatsReturnsDefensiveCopy() {
        SignalArray sa = SignalArray.ofFloats(new float[]{1.0f, 2.0f});
        float[] a = sa.asFloats();
        a[0] = 9.0f;
        assertEquals(1.0f, sa.asFloats()[0], 0.0f);
    }
}
```
(Confirm `SignalArray.ofDoubles`/`ofFloats` exist — seen in `ValueClassesTest`. If `ofInts`/`ofLongs` exist, add analogous cases.) Run: `JAVA_HOME=~/jdk25 mvn -o -B test -Dtest=SignalArrayEncapsulationTest 2>&1 | tail -10` → FAILS (currently returns the backing array, so the mutation leaks).

- [ ] **Step 3: Implement the clone.** In `SignalArray.java`, change the four typed accessors' return to clone the matched branch only:
```java
public double[] asDoubles() {
    if (buffer instanceof double[] d) return d.clone();
    throw new ClassCastException("buffer is not double[]");
}
public float[] asFloats() {
    if (buffer instanceof float[] f) return f.clone();
    throw new ClassCastException("buffer is not float[]");
}
public int[] asInts() {
    if (buffer instanceof int[] i) return i.clone();
    throw new ClassCastException("buffer is not int[]");
}
public long[] asLongs() {
    if (buffer instanceof long[] l) return l.clone();
    throw new ClassCastException("buffer is not long[]");
}
```
Leave `buffer()` unchanged. Update each accessor's javadoc `@return` to "a defensive copy of the backing array as double[]" (etc.).

- [ ] **Step 4: Run** `JAVA_HOME=~/jdk25 mvn -o -B test -Dtest='SignalArrayEncapsulationTest,ValueClassesTest,C2cValueClassesGapsTest' 2>&1 | tail -10` → all green (round-trips still pass; new encapsulation test passes).

- [ ] **Step 5: Full verify (jacoco gate)** `JAVA_HOME=~/jdk25 mvn -o -B verify 2>&1 | tail -12` → BUILD SUCCESS, "All coverage checks have been met" (≥0.84), identical "Tests run" to Step 1 + the new tests.

- [ ] **Step 6: CHANGELOG + commit.** CHANGELOG `### Changed`: Java `SignalArray.asDoubles()/asFloats()/asInts()/asLongs()` now return a defensive copy (no longer leak the backing array); `buffer()` remains the documented raw accessor. (OO-assessment P3.11.) Commit `refactor(p3.11): SignalArray.asX() returns a defensive copy (Java)`.

---

## Final review
After PR-2: confirm no `.tio`/wire/API-shape change across both PRs; ObjC untouched (already compliant); CHANGELOG coherent. Then `superpowers:finishing-a-development-branch`.

## Self-review notes (author)
- **Spec coverage:** Task 1 covers spec actions 1 (`Run` Stable, Step 7) + 2 (read-only `data`, Steps 2-6) + secondary sweep (Step 8); Task 2 covers action 3 (Java clone). ObjC out-of-scope (unchanged).
- **Risk:** the Python internal-mutation audit (Step 6) is the only real risk; investigation already found NO internal `.data` writes (only read-slices in encrypted.py), so it should be clean — Step 6 verifies + the suite catches any miss. The freeze-the-view-not-the-caller's-array subtlety is fenced by `test_freeze_does_not_freeze_caller_array`.
- **No placeholders:** all code shown; exact commands + expected outputs given.
- **Type consistency:** `__post_init__` matches `slots=True` non-frozen (plain assignment); Java clones only the matched `instanceof` branch (return type unchanged).
