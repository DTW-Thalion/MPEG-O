# P3.8 — `SpectrumKind` enum + factory (replace stringly dispatch) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Replace the stringly-typed `spectrum_class` dispatch (`if spectrum_class == "TTIOIRSpectrum"` / `switch (spectrumClassOverride)` / `[s isEqualToString:@"..."]`) with a `SpectrumKind` enum + dispatch on the enum, in Python/Java/ObjC. The persisted `@spectrum_class` string stays the source of truth (written verbatim) — **no `.tio`/wire/transport change**.

**Architecture:** Per SDK: add a `SpectrumKind` enum keyed to the existing persisted strings; add a boundary mapper `from_persisted(str) -> kind` (absent → MASS per v0.1 fallback; unrecognized → UNKNOWN); add a derived `kind` accessor on the run; replace the string-comparison dispatch with enum dispatch. The stored `spectrum_class` string field is RETAINED and emitted verbatim on write, so round-trip is byte-exact even for unknown/future strings. The transport `*_TO_WIRE` string→int map is a SEPARATE existing mapping and is OUT OF SCOPE (untouched). 3 PRs (Python → Java → ObjC), each its own branch off main, CI-green, merged before the next.

**Tech Stack:** Python 3.12/pytest; Java 22/Maven/JUnit (jacoco ≥0.84); ObjC/GNUstep/ctest. Spec: `docs/superpowers/specs/2026-06-05-p3-8-spectrum-kind-enum-design.md`.

**Environment / commands:**
- Python: `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest <args> -q` (`.venv/bin/python` for scripts).
- Java: `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -B test` / `verify`.
- ObjC: `cd ~/TTI-O/objc && ./build.sh check`.
- Commit: `git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit`.
- Push from Windows git; **always `git fetch` before `reset --hard origin/main`**; after merge, branch fresh off main. After each implementer runs, the controller verifies the commit base + scope and `reset --hard HEAD` clears any stale-working-tree gremlin. Local cross-language tests fail on the known JDK 21-vs-22 env issue — CI is the gate.
- Branch `p3-8-spectrum-kind-enum` is created (carries spec + plan + PR-1).

**Verified facts:**
- Persisted vocabulary (HDF5 `@spectrum_class`, dispatched on): `TTIOMassSpectrum`, `TTIONMRSpectrum`, `TTIOIRSpectrum`, `TTIORamanSpectrum`, `TTIOUVVisSpectrum`, `TTIOFreeInductionDecay`, `TTIOMSImagePixel` (+ `TTIONMR2DSpectrum` appears in the transport wire map). Absent → `TTIOMassSpectrum` (v0.1 fallback, `format-spec.md:154`).
- Enum homes: Python `python/src/ttio/enums.py` (IntEnums; `ImageKind`/`SpectralAxisKind` are recent precedents). Java `java/.../Enums.java` (nested public enums; `ImageKind` precedent). ObjC `NS_ENUM` (P2.5 added `TTIOImageKind`/`TTIOSpectralAxisKind` — follow that file/style).
- Python dispatch: `acquisition_run.py:726-754` (`if self.spectrum_class == "TTIONMRSpectrum"` … returns `NMRSpectrum`/`IRSpectrum`/`RamanSpectrum`/`UVVisSpectrum`/`MassSpectrum` with per-kind kwargs). `spectrum_class` read at `acquisition_run.py:394`. Write at `spectral_dataset.py:1181` (`write_fixed_string_attr(g, "spectrum_class", run.spectrum_class)`).
- Java dispatch: `AcquisitionRun.java:303` `switch (spectrumClassOverride)` (IR/Raman/UVVis cases) + `"TTIOIRSpectrum".equals(...)` chains at `:596` and `:696`. Selection: `exporters/RunSelection.java` (`spectrumClassName().equals("TTIONMRSpectrum")`).
- ObjC dispatch: `Run/TTIOAcquisitionRun.m:340-359` and `:1003-1033` (`[_spectrumClassName isEqualToString:@"..."]` chains).
- Transport wire (OUT OF SCOPE): `transport/_common.py:_SPECTRUM_CLASS_TO_WIRE`; ObjC `TTIOEncryptedTransport.m:620-623` ladders; Java equivalents. DO NOT TOUCH.

**Hard invariants (every PR):** No `.tio`/wire/transport change; `@spectrum_class` emitted verbatim from the stored string. No public API-shape change (the string field/accessor stays; the enum is additive). Round-trip byte-exact incl. unknown. Dispatch results identical to the old string comparisons. Cross-language conformance + suites green.

---

### Task 1 (PR-1): Python — `SpectrumKind` enum + enum dispatch

**Files:**
- Modify: `python/src/ttio/enums.py` (add `SpectrumKind`)
- Modify: `python/src/ttio/acquisition_run.py` (add `kind`; convert dispatch)
- Test: `python/tests/test_p3_8_spectrum_kind.py` (new)

- [ ] **Step 1: Baseline.** `...pytest -q 2>&1 | grep -E "^FAILED" | sed 's|::.*||' | sort -u` (record the JDK/xlang env set) and `...pytest tests/test_acquisition*.py tests/test_spectrum*.py tests/test_value_classes.py -q` (record green). Also confirm which spectrum-class round-trip tests exist: `ls tests | grep -iE "spectrum|raman|ir_|uvvis|nmr|fid"`.
- [ ] **Step 2: Study** `enums.py` (the `ImageKind` IntEnum pattern) and `acquisition_run.py:394` (read of `spectrum_class`) + `:726-754` (the dispatch chain) + the `spectrum_class` field declaration. Confirm `MassSpectrum`/`NMRSpectrum`/`IRSpectrum`/`RamanSpectrum`/`UVVisSpectrum` classes + their kwargs.
- [ ] **Step 3: Write the failing test** `tests/test_p3_8_spectrum_kind.py`:
```python
"""P3.8: SpectrumKind enum maps to/from the persisted spectrum_class strings."""
import pytest
from ttio.enums import SpectrumKind


def test_known_strings_round_trip():
    for s in [
        "TTIOMassSpectrum", "TTIONMRSpectrum", "TTIOIRSpectrum",
        "TTIORamanSpectrum", "TTIOUVVisSpectrum", "TTIOFreeInductionDecay",
        "TTIOMSImagePixel",
    ]:
        k = SpectrumKind.from_persisted(s)
        assert k is not SpectrumKind.UNKNOWN
        assert k.persisted == s  # byte-exact write-back of known values


def test_absent_defaults_to_mass():
    assert SpectrumKind.from_persisted(None) is SpectrumKind.MASS
    assert SpectrumKind.from_persisted("") is SpectrumKind.MASS


def test_unknown_is_unknown():
    assert SpectrumKind.from_persisted("TTIOFutureSpectrum") is SpectrumKind.UNKNOWN
```
Run → FAILS (no `SpectrumKind`).
- [ ] **Step 4: Add `SpectrumKind`** to `enums.py`. Mirror the `ImageKind` precedent but add the string mapping. Suggested shape (adapt to the file's style):
```python
class SpectrumKind(Enum):
    """Discriminator for a spectrum run's concrete type, derived from the
    persisted ``@spectrum_class`` string (which remains the on-disk source
    of truth — this enum is an in-code dispatch key, P3.8)."""
    MASS = "TTIOMassSpectrum"
    NMR = "TTIONMRSpectrum"
    NMR_2D = "TTIONMR2DSpectrum"
    IR = "TTIOIRSpectrum"
    RAMAN = "TTIORamanSpectrum"
    UVVIS = "TTIOUVVisSpectrum"
    FREE_INDUCTION_DECAY = "TTIOFreeInductionDecay"
    MS_IMAGE_PIXEL = "TTIOMSImagePixel"
    UNKNOWN = ""

    @property
    def persisted(self) -> str:
        return self.value

    @classmethod
    def from_persisted(cls, s: "str | None") -> "SpectrumKind":
        if not s:
            return cls.MASS  # v0.1 fallback (format-spec §3)
        for k in cls:
            if k is not cls.UNKNOWN and k.value == s:
                return k
        return cls.UNKNOWN
```
(Use `from enum import Enum` — a string-valued `Enum`, not `IntEnum`, since the natural key is the string. If the file convention strongly prefers IntEnum + a side dict, do that instead; either way `from_persisted`/`persisted` are the contract the test pins. NOTE: only include members that are actually persisted/dispatched — if `TTIONMR2DSpectrum` isn't dispatched in the Python AcquisitionRun path, you may still include it for completeness since it's in the wire vocabulary; keep `UNKNOWN` for forward-compat.)
- [ ] **Step 5: Run the new test** → 3 pass.
- [ ] **Step 6: Add a derived `kind` accessor + convert dispatch** in `acquisition_run.py`. Keep the `spectrum_class` string field exactly as-is (it stays the source of truth; the writer at `spectral_dataset.py:1181` is unchanged). Add e.g. a cached property `kind` → `SpectrumKind.from_persisted(self.spectrum_class)`. Replace the `:726-754` chain's conditions from `self.spectrum_class == "TTIONMRSpectrum"` to `self.kind is SpectrumKind.NMR` (resp. IR/RAMAN/UVVIS), keeping each branch's construction body verbatim; the trailing `return MassSpectrum(...)` stays the default (covers MASS + UNKNOWN + anything else, preserving today's behavior). Do NOT change the kwargs/branch bodies.
- [ ] **Step 7: Dispatch-equivalence test** — extend `test_p3_8_spectrum_kind.py` with a test that builds (or opens) a run for each of MS/NMR/IR/Raman/UVVis and asserts the materialized spectrum is the expected concrete class (`isinstance(spec, IRSpectrum)` etc.), proving enum dispatch matches the old behavior. Study an existing spectrum-roundtrip test for the cheapest fixture (e.g. `test_spectrum*.py` / a Raman/IR test). If full fixtures are heavy, at minimum assert `AcquisitionRun(...).kind` for each `spectrum_class` value.
- [ ] **Step 8: Round-trip byte-exact test** — write a run with `spectrum_class="TTIOFutureSpectrum"` (unknown) to a `.tio`, reopen, assert `ds...spectrum_class == "TTIOFutureSpectrum"` (the unknown string is preserved verbatim — the field is never normalized through the enum). Use the existing write/open helpers (study `test_acquisition*.py`).
- [ ] **Step 9: Full suite + coverage.** `...pytest -q 2>&1 | tail -3` → failure set == Step 1 (JDK/xlang env only). `...pytest --cov=ttio --ignore=tests/conformance --ignore=tests/integration --ignore=tests/validation -q 2>&1 | grep -i TOTAL` (≥84 on CI).
- [ ] **Step 10: CHANGELOG + commit.** CHANGELOG `### Changed`: `spectrum_class` dispatch now goes through a `SpectrumKind` enum; the persisted `@spectrum_class` string is unchanged (still the source of truth, written verbatim). No wire/API-shape change. (OO-assessment P3.8.) Commit `refactor(p3.8): SpectrumKind enum + enum dispatch (Python)`.

---

### Task 2 (PR-2): Java — `SpectrumKind` enum + enum dispatch

**Files:**
- Modify: `java/src/main/java/global/thalion/ttio/Enums.java` (add nested `SpectrumKind`)
- Modify: `java/src/main/java/global/thalion/ttio/AcquisitionRun.java` (convert dispatch)
- Modify (opportunistic): `java/.../exporters/RunSelection.java`
- Test: `java/src/test/java/global/thalion/ttio/SpectrumKindTest.java` (new)

- [ ] **Step 1: Baseline.** `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -B test 2>&1 | tail -6` → BUILD SUCCESS + "Tests run: N".
- [ ] **Step 2: Study** `Enums.java` (the `ImageKind` nested-enum pattern) + `AcquisitionRun.java:303` switch + `:596`/`:696` equals chains + `spectrumClassName()`/`spectrumClassOverride` fields.
- [ ] **Step 3: Write the failing test** `SpectrumKindTest.java` (package `global.thalion.ttio`):
```java
package global.thalion.ttio;
import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.Test;

class SpectrumKindTest {
    @Test void knownStringsRoundTrip() {
        for (String s : new String[]{
            "TTIOMassSpectrum","TTIONMRSpectrum","TTIOIRSpectrum",
            "TTIORamanSpectrum","TTIOUVVisSpectrum","TTIOFreeInductionDecay",
            "TTIOMSImagePixel"}) {
            Enums.SpectrumKind k = Enums.SpectrumKind.fromPersisted(s);
            assertNotEquals(Enums.SpectrumKind.UNKNOWN, k);
            assertEquals(s, k.persisted());
        }
    }
    @Test void absentDefaultsToMass() {
        assertEquals(Enums.SpectrumKind.MASS, Enums.SpectrumKind.fromPersisted(null));
        assertEquals(Enums.SpectrumKind.MASS, Enums.SpectrumKind.fromPersisted(""));
    }
    @Test void unknownIsUnknown() {
        assertEquals(Enums.SpectrumKind.UNKNOWN,
            Enums.SpectrumKind.fromPersisted("TTIOFutureSpectrum"));
    }
}
```
Run `JAVA_HOME=~/jdk25 mvn -o -B test -Dtest=SpectrumKindTest 2>&1 | tail -10` → FAILS (no `SpectrumKind`).
- [ ] **Step 4: Add `SpectrumKind`** as a nested `public enum` in `Enums.java`, each member carrying its persisted string, with `String persisted()` and `static SpectrumKind fromPersisted(String s)` (null/empty → `MASS`; unrecognized → `UNKNOWN`). Members: MASS, NMR, NMR_2D, IR, RAMAN, UVVIS, FREE_INDUCTION_DECAY, MS_IMAGE_PIXEL, UNKNOWN. Follow the `ImageKind` style in the same file.
- [ ] **Step 5: Run** `-Dtest=SpectrumKindTest` → 3 pass.
- [ ] **Step 6: Convert dispatch** in `AcquisitionRun.java`. Keep the stored `spectrumClassName`/`spectrumClassOverride` strings (source of truth; write paths unchanged). Compute a `SpectrumKind` from the relevant string and switch on it: `switch (spectrumClassOverride)` (`:303`) → resolve `Enums.SpectrumKind k = Enums.SpectrumKind.fromPersisted(spectrumClassOverride)` then `switch (k) { case IR -> ...; case RAMAN -> ...; case UVVIS -> ...; default -> {} }` keeping each case body verbatim. Convert the `"TTIOIRSpectrum".equals(...)` chains at `:596`/`:696` to `k == Enums.SpectrumKind.IR` etc. (compute `k` once at the top of each method). Do NOT alter branch bodies.
- [ ] **Step 7: Opportunistic** — `RunSelection.java`'s `spectrumClassName().equals("TTIONMRSpectrum")` → `Enums.SpectrumKind.fromPersisted(r.spectrumClassName()) == Enums.SpectrumKind.NMR`. Only if it reads cleanly; the `NMR_SPECTRUM_CLASS` constant + javadoc reference may stay.
- [ ] **Step 8: Compile + test** `JAVA_HOME=~/jdk25 mvn -o -B test 2>&1 | tail -8` → BUILD SUCCESS, "Tests run" = baseline + new, 0 failures.
- [ ] **Step 9: Full verify (jacoco)** `JAVA_HOME=~/jdk25 mvn -o -B verify 2>&1 | tail -12` → BUILD SUCCESS, "All coverage checks have been met" (≥0.84).
- [ ] **Step 10: CHANGELOG + commit** `refactor(p3.8): SpectrumKind enum + enum dispatch (Java)`.

---

### Task 3 (PR-3): ObjC — `TTIOSpectrumKind` enum + enum dispatch

**Files:**
- Create/Modify: the ObjC enums header (where `TTIOImageKind` lives, from P2.5 — find via `grep -rn "TTIOImageKind" objc/Source --include=*.h`) — add `TTIOSpectrumKind` + a string↔kind helper.
- Modify: `objc/Source/Run/TTIOAcquisitionRun.m` (convert dispatch)
- Modify (opportunistic): `objc/Source/Export/TTIORunSelection.m`, `TTIOMzMLWriter.m`
- Build registration: if a new `.h`/`.m` is added, register in `objc/Source/GNUmakefile` (both header + OBJC_FILES lists as applicable).
- Test: add to the ObjC test runner (study `TTIOTestRunner.m` + an existing enum/value test for the pattern).

- [ ] **Step 1: Baseline.** `cd ~/TTI-O/objc && ./build.sh check 2>&1 | tail -15` → clean build + test-runner pass count.
- [ ] **Step 2: Study** where `TTIOImageKind` (P2.5) is declared + how its string mapping (if any) is done; `Run/TTIOAcquisitionRun.m:340-359` and `:1003-1033` (`[_spectrumClassName isEqualToString:@"..."]`); the `_spectrumClassName` ivar (source of truth — keep). Decide: a `TTIOSpectrumKind NS_ENUM` + two C helpers `TTIOSpectrumKind TTIOSpectrumKindFromPersisted(NSString *)` and `NSString *TTIOSpectrumKindPersisted(TTIOSpectrumKind)` in the enums header/.m (mirror any existing kind-string helper).
- [ ] **Step 3: Add the enum + helpers.** `typedef NS_ENUM(NSInteger, TTIOSpectrumKind) { TTIOSpectrumKindMass, TTIOSpectrumKindNMR, TTIOSpectrumKindNMR2D, TTIOSpectrumKindIR, TTIOSpectrumKindRaman, TTIOSpectrumKindUVVis, TTIOSpectrumKindFreeInductionDecay, TTIOSpectrumKindMSImagePixel, TTIOSpectrumKindUnknown };` + `TTIOSpectrumKindFromPersisted` (nil/empty → Mass; unrecognized → Unknown) + `TTIOSpectrumKindPersisted` (kind → canonical string). Define the string table once.
- [ ] **Step 4: Write a test** (in `TTIOTestRunner.m` style): for each persisted string, `TTIOSpectrumKindFromPersisted(s)` is the expected member and `TTIOSpectrumKindPersisted(kind)` round-trips to the same string; nil/empty → Mass; `@"TTIOFutureSpectrum"` → Unknown. Register the test fn (extern + call) per the triple-surface convention. Run `./build.sh check` → confirm the new test runs + FAILS before impl (or write it alongside impl and confirm it passes).
- [ ] **Step 5: Convert dispatch** in `TTIOAcquisitionRun.m`. Keep `_spectrumClassName` (source of truth). At `:340-359` and `:1003-1033`, compute `TTIOSpectrumKind k = TTIOSpectrumKindFromPersisted(_spectrumClassName)` once, then replace `[_spectrumClassName isEqualToString:@"TTIOIRSpectrum"]` with `k == TTIOSpectrumKindIR` etc., keeping each branch body verbatim. Do NOT touch the transport `isEqualToString → wireClass` ladders in `TTIOEncryptedTransport.m`/`TTIOTransportReader.m` (out of scope — wire).
- [ ] **Step 6: Opportunistic** — `TTIORunSelection.m` / `TTIOMzMLWriter.m` `isEqualToString:@"TTIO...Spectrum"` → the enum, if clean.
- [ ] **Step 7: Register** any new files in `objc/Source/GNUmakefile` (and `Tests/GNUmakefile` if a test source is added). Build: `./build.sh check 2>&1 | tail -20` → clean build, test-runner pass count = baseline + new tests, no failures.
- [ ] **Step 8: CHANGELOG + commit** `refactor(p3.8): TTIOSpectrumKind enum + enum dispatch (ObjC)`.

---

## Final review
After PR-3: confirm across the series — NO `.tio`/wire/transport change (the transport `*_TO_WIRE` maps untouched; `@spectrum_class` written verbatim); the persisted string field retained in all 3 SDKs; dispatch equivalence + round-trip fidelity tests present; CHANGELOG coherent. Then `superpowers:finishing-a-development-branch`.

## Self-review notes (author)
- **Spec coverage:** Task 1/2/3 = Python/Java/ObjC enum+dispatch (spec's 3-SDK scope). Each retains the persisted string as source of truth (spec's core constraint) + the round-trip & dispatch-equivalence fences (spec's fidelity gate). Transport wire + genomic explicitly excluded (spec out-of-scope).
- **No wire change:** every task keeps the write path emitting the stored string verbatim; the unknown-string round-trip test is the byte-exact fence; transport maps untouched.
- **Risk:** lowest of the P3.x items — pure in-code dispatch swap, string field unchanged. The only care is enumerating the exact persisted vocabulary per SDK (Step 2) + keeping branch bodies verbatim (Steps 6).
- **No placeholders:** enum code + tests + exact dispatch sites (file:line) given; branch bodies are "keep verbatim, change only the condition".
- **Consistency:** `from_persisted`/`persisted` (Python), `fromPersisted`/`persisted()` (Java), `TTIOSpectrumKindFromPersisted`/`TTIOSpectrumKindPersisted` (ObjC) are the per-SDK boundary names used consistently in each task + its test.
