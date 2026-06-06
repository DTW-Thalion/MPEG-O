# TTI-O Coverage-Testing Analysis & Recommendations — 2026-06-06

Analysis of the three-SDK coverage setup (Python / Java / ObjC) at `main`
(`b15d657b`, post-v1.7.0), measuring current numbers, gate mechanics, exclusions,
and blind spots — then prioritized recommendations. Numbers are point-in-time;
re-verify before acting.

## 1. Current state

| SDK | Line | Branch | Gate | Branch gated? |
|-----|-----:|-------:|------|---------------|
| **Python** | ~88% (2029/16573 missed) | ~83.5% (852/5168 partial) | `--cov-fail-under=84` (combined = **85%**) | ✅ (`branch=true`) |
| **Java** | **84.3%** (17095/20278) | **67.7%** (7026/10377) | jacoco `BUNDLE LINE COVEREDRATIO ≥ 0.84` | ❌ (line only) |
| **ObjC** | ~83.9%* (36823/43874) | n/a | **none** — `--coverage` emits lcov + uploads, never fails | ❌ |

\* ObjC number is from a **stale** `coverage/coverage.lcov` (Apr-27, pre-v1.7.0) and
is **polluted by system headers** (`/usr/GNUstep/.../Foundation/*.h` instrumented at
0–19%); `llvm-profdata`/`llvm-cov` aren't on the local PATH (CI only), so it couldn't
be freshly measured here.

**Margins are thin:** Java 84.3% vs the 84.0% gate; Python 85% vs 84%. A small
regression trips either.

## 2. Findings

### F1 — Branch coverage is the real weak spot (esp. Java)
Java line is 84.3% but **branch is only 67.7%** — a 16-point gap, and the gate
ignores branches entirely. Roughly a third of Java conditionals are never exercised
both ways. Python measures branches (`branch=true`, ~83.5%); ObjC measures neither.
Line-only gates pass code whose error/edge branches are untested.

### F2 — The fqzcomp codec is the single biggest *logic* gap (both langs)
`fqzcomp_nx16_z` is the lowest substantial module in two SDKs: **Python 28%**
(417/607 missed), **Java 19%** (`codecs.FqzcompNx16Z`, 497/613 missed). This is
real, testable codec logic (the pure-language reference encoder/decoder), not glue —
the highest-value place to add tests.

### F3 — CLI tools / probes read as 0–50% everywhere (subprocess-blind)
The coverage tools don't credit code run in a **subprocess**, and the CLIs are
tested by spawning the built binary:
- **Java 0%**: `NmrMLProbe`, `TransportEncodeCli`, `MzMLProbe`, `FastaImportBench`;
  + `PerAUCli` 51%, `RefDiffV2Cli` 57%.
- **ObjC 0–24%**: `Tools/Ttio{Sign,Simulator,TransportServer,TransportEncode,ToMzML,
  JcampDxDump}.m`, `MakeFixtures.m`.
- **Python 44–73%**: `tools/{transport_server,transport_encode,ttio_pqc,ttio_verify}_cli.py`.
These are cheap to recover by invoking `main()` **in-process** (already a recorded
lesson: JaCoCo/llvm are blind to subprocess CLI runs).

### F4 — External-tool importers are half-covered
Bruker/Thermo/Waters readers sit ~47–59% (Python `importers/{bruker_tdf,thermo_raw,
waters_masslynx}.py`; Java `{BrukerTDFReader,ThermoRawReader,WatersMassLynxReader}`)
because they shell out to vendor tooling / are partial stubs. Lower-value (needs
fixtures or mocked subprocess), but the parse/validate paths are unit-testable.

### F5 — ObjC has no gate + a polluted measurement scope
CI runs `build.sh --coverage check` and uploads the lcov but **never fails on a
threshold** — ObjC coverage is informational only. The lcov also instruments system
Foundation headers, so the headline % is meaningless without scoping to `objc/Source`.

### F6 — Gate *shape* lets gaps hide
- Java uses a single **BUNDLE** aggregate: a few large well-covered classes mask the
  0%/19% outliers (F2/F3). No per-class or per-package floor.
- Python's `--cov-fail-under` is also a single total. 101 modules are <100%; nothing
  stops one dropping to 20% as long as the total holds.

### F7 — Legitimate-but-large exclusions
Both Python `omit` and Java `<excludes>` (30 patterns) drop the **workbench live-
daemon clients** (`workbench/{transport,_http,jobs,pipeline,session_proxy,containers,
sessions/*Client}` + CLI). Defensible (meaningful coverage needs a live
`tti-workbench-server`), but it removes a real chunk of networking code from the
denominator. Live-daemon integration tests are tracked (W1–W5 progress docs) but
unlanded.

### F8 — Native + cross-language code is outside coverage
The C rANS library and the Cython `_fqzcomp_nx16` extension have no coverage at all
(only the pure-Python fallback is measured). Cross-language conformance/parity suites
exercise a lot of code but their coverage is only counted on CI (locally the JDK-env
xlang failures contribute nothing).

## 3. Recommendations (prioritized)

### High value, low effort
- **R1 — In-process `main()` tests for the CLI tools (F3).** Convert the 0%/low CLI
  coverage by invoking each tool's `main()`/entry in-process (capture argv + stdout)
  instead of (or in addition to) the subprocess smoke. Targets: the 4 Java 0% tools,
  the ObjC `Tools/*`, the Python `tools/*_cli`. The logic already works (smokes pass);
  this just makes coverage *see* it. Big % jump for little code.
- **R2 — Fix ObjC measurement + add a gate (F5).** Scope the lcov to `objc/Source`
  (drop `/usr/GNUstep/...` system headers), then add a CI line-rate threshold so ObjC
  is gated like the others. Cheap, closes the "one SDK ungated" hole.

### High value, medium effort
- **R3 — Test the fqzcomp codec (F2).** Add round-trip + edge-case unit tests for the
  pure-language `fqzcomp_nx16_z` encoder/decoder in Python and Java (quality models,
  renorm boundaries, empty/short inputs). Biggest single coverage + correctness win;
  ~600 lines of real codec logic per language currently dark.
- **R4 — Add a BRANCH gate to Java (F1).** Add a jacoco `BRANCH COVEREDRATIO` limit.
  Set the initial floor at the current ~0.67 to stop regressions, then ratchet up as
  R1/R3 land. Consider the same for ObjC once R2 is in.

### Structural / longer-term
- **R5 — Per-class/package floor (F6).** Add a jacoco `CLASS`-element rule (e.g. no
  class below 0.50, excluding the documented live-daemon set) so outliers can't hide
  behind the bundle aggregate. Python equivalent: a small CI check that fails if any
  measured module drops below a floor.
- **R6 — Ratchet the gates (margins).** After R1/R3 raise the numbers, bump the gates
  (e.g. 0.84 → 0.87 line) and prefer a *never-decrease* ratchet over a fixed constant
  so coverage can't silently erode back to the floor.
- **R7 — Land the deferred live-daemon integration tests (F7)** to un-exclude the
  workbench clients (Python `omit` + Java `<excludes>`). Bigger effort (daemon in CI);
  do after the cheaper wins.
- **R8 — (Optional) native coverage (F8).** gcov/llvm-cov on the C rANS lib + the
  Cython extension if the codec paths warrant it. Low priority.

## 4. Suggested sequencing
1. **R1 + R2** (cheap, high-yield: CLI in-process tests + ObjC scope/gate) — likely
   lifts Java/ObjC several points and closes the ungated hole.
2. **R3** (fqzcomp tests) — the biggest real logic gap, both langs.
3. **R4** (Java branch gate at a no-regression floor) — locks in the branch story.
4. **R5 + R6** (per-class floor + ratchet) — prevent future erosion.
5. **R7 / R8** as capacity allows.

Each is independently shippable as its own PR; R1–R4 are the high-ROI core.
