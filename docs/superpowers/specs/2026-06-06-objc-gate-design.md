# ObjC Coverage Gate — Enforce + Scope (R2) — Design

**Date:** 2026-06-06
**Origin:** `docs/architecture/2026-06-06-coverage-analysis.md` recommendation R2 (finding F5).
**Scope:** Make the ObjC coverage threshold CI-enforcing (not advisory), scope the lcov to
the shippable TTI-O code, recalibrate the threshold, and close the silent escape hatches
that would let a broken/tool-less runner falsely pass. Script + CI config only; no
production `.m`/`.h` or test change.

## Problem (F5)
`objc/build.sh --coverage` defines an 82% line threshold (`TTIO_COV_MIN`, `exit 1` below
it), but CI runs that step with `continue-on-error: true` (`.github/workflows/ci.yml`), so
it is **advisory** — a coverage regression cannot fail CI. Also, the lcov is exported with
no path filter, so the gated % is polluted by system/3rd-party headers
(`/usr/...`, liboqs, GNUstep makefile headers, libobjc2) and by test `.m` sources. And
`build.sh --coverage` silently `exit 0`s when llvm tools / profraws / the test binary are
missing — so once enforcing, a tool-less runner would falsely pass.

## How the gate computes (verified)
`build.sh` produces `coverage/coverage.lcov` via one `llvm-cov export` (line ~149-151:
positional `Tests/obj/TTIOTests` + `-object` for `Source/obj/libTTIO.so*` and every
`Tools/obj/*`, `-format=lcov`). The threshold check (line ~163-178) computes `cov_pct` by
summing `LH:`/`LF:` from **that same lcov**. So scoping the export auto-applies to the
gated number — one edit covers both the artifact and the gate. (llvm-cov is 18.1.3; it does
**not** support negative-lookahead regex — use a positive drop pattern.)

## Changes

### 1. Scope the lcov (`objc/build.sh`, the `llvm-cov export`)
Add a positive `-ignore-filename-regex` dropping system/3rd-party + test sources, keeping
**`objc/Source` + `objc/Tools`** (the shippable code, incl. the Tools coverage R1 added):
```bash
"$LLVM_COV" export "$primary" "${rest[@]}" \
    -instr-profile="$here/coverage/coverage.profdata" \
    -ignore-filename-regex='(^/usr/)|(/_oqs/)|(/Makefiles/)|(libobjc2)|(/objc/Tests/)' \
    -format=lcov > "$here/coverage/coverage.lcov"
```
Test `.m` files are dropped because they are ~fully covered by definition and would inflate
the number. The implementer must **validate the dropped set** against a real lcov (confirm
only `objc/Source` + `objc/Tools` `SF:` records remain) since the GNUstep prefix may vary
(`/usr/local/...` vs `/usr/GNUstep/...`; the `(/Makefiles/)` clause catches both).

### 2. Recalibrate the threshold
Scoping moves the ratio (removing low-coverage system headers raises it; removing
high-coverage test files lowers it — net unknown). Procedure: after scoping, run
`./build.sh --coverage check` once to read the new scoped `cov_pct`, then set the default
`TTIO_COV_MIN` (the `:-82` fallback) to **~1pt below that measured baseline** — a
no-regression floor (same convention as R4). Update the inline comment with the measured
baseline + date. Do not keep 82 blindly (it was calibrated against the unscoped denominator).

### 3. Close the silent escape hatches
Under `--coverage`, change the `exit 0` paths that currently mask failure to **`exit 1`**
with a clear message:
- llvm tools not found (`find_llvm_tool` failure),
- no `.profraw` files found,
- test binary absent.
So an enforcing gate fails loudly instead of silently passing on a broken runner. (CI
installs `llvm` via apt, so the normal path is unaffected; plain `./build.sh check` —
without `--coverage` — is untouched and keeps its own behavior.)

### 4. Make the CI step enforcing (`.github/workflows/ci.yml`, ObjC job)
- Remove `continue-on-error: true` from the "Coverage build (opt-in)" step (~line 101).
- Update the preceding comment (~lines 94-98) that justifies non-enforcement.
- Rename the step to reflect it's now a gate (e.g. "Coverage gate (ObjC)").
- Keep the `apt-get install llvm` (now load-bearing) and the separate "Upload coverage"
  step (`if: always()`).

## Invariants & verification
- **Script + CI config only** — no `objc/Source` / `objc/Tools` / `objc/Tests` code change.
- Plain `./build.sh check` (the other ObjC CI step) behavior unchanged.
- `./build.sh --coverage check` passes at the recalibrated floor locally.
- Gate-bites proof: a throwaway `TTIO_COV_MIN=<baseline+2>` run FAILS; revert.
- Escape-hatch proof: a throwaway run with llvm tools hidden (e.g. `PATH` without llvm /
  temporarily rename) FAILS instead of exit 0 — or at minimum confirm the new `exit 1`
  branches by reading them and a targeted simulation.
- CI: the ObjC job's coverage step now fails the build on a coverage regression. (Heads-up:
  the ObjC CI job is the slow one and recently hung on the flaky `setup-libarrow` apt
  fetch — unrelated to this change, but a re-run may be needed; see
  [[feedback_libarrow_dev_ubuntu_apt_source]].)

## Success criteria
ObjC coverage is a real CI gate: `coverage.lcov` contains only `objc/Source` + `objc/Tools`
records, `TTIO_COV_MIN` reflects the scoped baseline (~1pt buffer), the silent passes are
closed, and `continue-on-error` is gone. `./build.sh --coverage check` green locally and
demonstrably fails below floor / on missing tooling. One PR.

## Out of scope (tracked separately)
R5 (per-class/package floor), R6 (ratchet line/branch gates up), R7/R8 (live-daemon +
native coverage). Writing new ObjC tests to raise coverage is future — R2 only locks in +
scopes the current level.
