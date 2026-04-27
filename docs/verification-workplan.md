# Verification & Performance Testing Workplan (V-series)

> **Status:** DRAFT for review (2026-04-27). Separate from `WORKPLAN.md`
> (the milestone plan). V-series milestones are verification debt
> repayments and instrumentation upgrades that cut across already-shipped
> milestones (M1–M88.1). They do NOT add user-visible features.

---

## 1. Audit summary

A deep audit of the verification and performance testing infrastructure
across Python (1047 tests), ObjC (~2597 assertions across 70 files),
and Java (543 tests) found the suite **production-quality on
serialisation, encryption, signatures, and per-language unit coverage**
but identified **eight actionable gaps**:

### Confirmed gaps

1. **No coverage instrumentation in any language.** pytest-cov absent
   from `pyproject.toml`; JaCoCo absent from `pom.xml`; gcov not wired
   into ObjC `build.sh`. Coverage % is unknown for all three.
2. **No performance regression detection in CI.** `tools/perf/` has
   excellent profile harnesses (Python/ObjC/Java/raw-C, single-fn +
   multi-fn variants) and a thorough `ANALYSIS.md`, but baselines are
   not persisted across commits and CI does not compare against them.
3. **Stress suite is Python-only.** `python/tests/stress/` covers cloud,
   concurrency, and 100 GB-scale files. ObjC and Java have no stress
   suites; failures under load (lock contention, GC pressure, cache
   eviction) would surface only in production.
4. **No property-based / fuzz / mutation testing.** The codec parsers
   (rANS, BASE_PACK, NAME_TOKENIZED, QUALITY_BINNED), JCAMP-DX
   (DIF/PAC/SQZ), and BAM/CRAM SAM-text intermediaries all have
   parser/decoder code paths that rely on hand-curated fixtures.
   Hypothesis (Python) and jqwik (Java) are not present.
5. **Edge cases unverified:** missing `samtools` on PATH (BAM/CRAM
   importers raise lazily but the error UX isn't tested), malformed
   HDF5 chunk headers, truncated CRAM blocks, partial JCAMP-DX
   compressed payloads.
6. **No CRAM cross-language read parity at the CLI layer.** *(NOTE: this
   was flagged by the audit but actually shipped as M88.1 today —
   `bam_dump --reference` + 6-test cross-language harness. Removed
   from the workplan.)*
7. **No persistent perf baseline storage.** `tools/perf/_out_*`
   directories exist locally but are gitignored; ANALYSIS.md hardcodes
   numbers from one run. A regression that doubled write latency would
   only be detected by the next person running profiles by hand.
8. **CI does not collect coverage or perf metrics.** `.github/workflows/ci.yml`
   runs the test suites but does not publish coverage reports or
   benchmark deltas to PR comments.

### Audit corrections (where the agent overreached)

The audit report contained three claims I'm walking back before
committing to work:

* **"M89-M91 SHIPPED" — wrong.** Per `WORKPLAN.md`, Phase 6
  (M89 transport, M90 encryption/anon, M91 multi-omics) and Phase 7
  (M92 benchmarking) are pending. The agent appears to have
  hallucinated this from the per-milestone test file enumeration.
* **"No cross-language codec round-trip (M83–M86)" — overstated.**
  `test_m86_genomic_codec_wiring.py` test #11 is "cross-language
  fixture verification (4 fixtures × byte-exact)". Codec WIRE FORMAT
  parity IS verified across languages via the .tio byte-exact
  fixtures from M86 phases A/B/C/D/E/F. The actual remaining gap is
  a CODEC-LAYER round-trip CLI (encode in Python, raw bytes →
  decode in Java) which is belt-and-suspenders, not foundational.
* **"No byte-exact HDF5 round-trip for non-encryption features" —
  misleading.** Field-level equality at the API layer is the correct
  contract for HDF5; byte-exact .tio comparison is reserved for
  fixtures where all three languages agree on the same encoder
  output (e.g., the M86 codec fixtures and the M21 LZ4 fixtures).
  Demanding it everywhere would over-constrain the spec.

### Things that are good

* Cross-language harnesses exist for M87 BAM, M88 BAM/CRAM round-trip,
  M88.1 BAM+CRAM dump, per-AU encryption, signatures, Raman/IR.
* CI runs all three test suites on every push/PR (Python 3.11 + 3.12
  matrix), plus a `cross-compat` job that re-builds ObjC and Java for
  parity checks.
* `tools/perf/` is mature: 9 build scripts, raw-C floor benchmark,
  per-function breakdown harness, `ANALYSIS.md` documenting
  optimisation rationale.
* `conformance/` directory holds hand-curated JCAMP-DX, mzTab, and
  2D-COS fixtures.

---

## 2. V-series milestones

Each V-milestone is a discrete unit of work with its own scope, files
to touch, acceptance criteria, and effort estimate. They can be done
in any order except where blockers are noted.

### V1 — Coverage instrumentation (3 languages)

**Effort:** S (3-5 days)  **Blocks:** V2 (perf baseline benefits from
knowing what code is exercised).

**Scope:** Wire coverage tooling into each language's build/test
toolchain. Publish % to CI. Set a minimum threshold (no enforced
floor in V1; just visibility).

**Files:**
* `python/pyproject.toml` — add `pytest-cov` to `[project.optional-dependencies] test`. Add `[tool.coverage.run]` config (`source = ["src/ttio"]`, `omit = ["*/tests/*"]`).
* `java/pom.xml` — add `org.jacoco:jacoco-maven-plugin` with `prepare-agent` + `report` goals.
* `objc/build.sh` — add an opt-in `--coverage` flag that invokes `clang -fprofile-instr-generate -fcoverage-mapping` and runs `llvm-profdata` + `llvm-cov export` after tests.
* `.github/workflows/ci.yml` — extend `python-test`, `java-test`, `objc-build-test` jobs to upload coverage XML/HTML as artifacts.

**Acceptance:**
* Python `pytest --cov=src/ttio --cov-report=term --cov-report=xml` reports a coverage % and writes `coverage.xml`.
* Java `mvn verify` produces `target/site/jacoco/jacoco.xml` and a per-package HTML report.
* ObjC `./build.sh --coverage check` produces `objc/coverage/coverage.lcov` (LCOV format for Codecov compatibility).
* CI uploads all three as artifacts; PR comments NOT enforced in V1.

**Deferred:** Coverage thresholds (V1.1 if desired); Codecov.io integration.

---

### V2 — CI performance baseline + regression detection

**Effort:** M (1 week)  **Blocks:** none.

**Scope:** Persist `tools/perf/profile_*_full` baselines per commit;
detect ≥10% regressions automatically; surface deltas as PR comments.

**Files:**
* `tools/perf/baseline.json` — new, committed; the canonical baseline (one entry per benchmark × language). Updated by maintainers when an intentional regression is accepted.
* `tools/perf/compare_baseline.py` — new; reads the most recent run output, diffs against `baseline.json`, prints a Markdown table, exits non-zero on ≥10% regression.
* `tools/perf/run_perf_ci.sh` — new; thin wrapper that runs `build_and_run_python_full.sh`, `build_and_run_java_full.sh`, `build_and_run_objc_full.sh` in sequence, then invokes `compare_baseline.py`.
* `.github/workflows/ci.yml` — add a `perf-regression` job that runs `tools/perf/run_perf_ci.sh` on push to main only (not on every PR — perf runs are slow and noisy on shared runners). On regression, opens a draft PR-style issue.

**Acceptance:**
* Running `tools/perf/run_perf_ci.sh` locally produces a Markdown delta report against `baseline.json`.
* CI job triggers on push-to-main; on ≥10% regression in any of the 10 benchmarked functions × 3 languages, the job fails and posts a comment.
* `baseline.json` is human-editable; maintainers can update it after intentional optimisation/regression with a one-line PR.

**Deferred:** Per-PR perf runs (too slow for shared CI without dedicated runners); GitHub Actions matrix to fan out per-language perf in parallel (possible but not essential at this scale).

---

### V3 — Document the cross-language coverage matrix

**Effort:** S (2-3 days)  **Blocks:** V4-V9 (clearer scope when the matrix is explicit).

**Scope:** Produce a single `docs/cross-language-matrix.md` document
that lists every cross-language harness, what it covers, and what it
explicitly doesn't. Keep it manually curated but updated as a
required step for new milestones (add a checklist item to the
HANDOFF template).

**Files:**
* `docs/cross-language-matrix.md` — new. Table: feature × {Py↔ObjC, Py↔Java, ObjC↔Java, 3-way} × {byte-exact, field-equal, none}. One row per feature/milestone. Footnote each "none" entry with rationale (out of scope, deferred, or acknowledged debt).
* `HANDOFF.md` template addendum (in a future milestone) — checklist item: "Updated docs/cross-language-matrix.md? (yes / N/A — does not add cross-language behaviour)".

**Acceptance:**
* The matrix exists, is hand-verified against current test files, and is referenced from `README.md` under §Testing.

---

### V4 — Edge case hardening (3 languages)

**Effort:** M (1 week per language; can parallelise = 1 week wall time).

**Scope:** Add tests for the failure modes the audit flagged as
unverified. Each language gets a small dedicated test file.

**Files (per language):**
* Python: `python/tests/test_v4_edge_cases.py` — pytest cases for:
  - `samtools` not on PATH → `BamReader().to_genomic_run()` raises with install-hint message containing "apt"/"brew"/"conda"
  - `samtools` exits non-zero (e.g., malformed BAM) → wrapper raises with stderr captured in message
  - Reference FASTA missing for CramReader → `FileNotFoundError` with the offending path
  - Truncated HDF5 file (last 1 KB chopped) → `Hdf5Reader` raises `Hdf5ParseError` (not `OSError`)
  - JCAMP-DX SQZ payload with corrupted run-length sentinel → `JcampDxParseError` with line/column info
* ObjC: `objc/Tests/TestV4EdgeCases.m` — analogues using `NSError**` out-params and `NSException` boundaries
* Java: `java/src/test/java/global/thalion/ttio/V4EdgeCasesTest.java` — analogues using JUnit `assertThrows`

**Acceptance:**
* All three languages have ≥10 edge-case tests in their suite.
* Per-language test count delta documented in CHANGELOG (V-series gets its own Unreleased entry).
* No production code changes unless an edge case reveals a bug — in which case fix the bug and add the test that catches it.

---

### V5 — Property-based testing for codecs and parsers

**Effort:** M-L (2 weeks).

**Scope:** Introduce property-based testing for the highest-risk
parsing surfaces. Python first (hypothesis is mature); Java second
(jqwik). ObjC has no good property-test library — defer.

**Files:**
* `python/tests/test_v5_codec_properties.py` — hypothesis-driven:
  - For any byte sequence ≤ 1 MB, `RansOrder0.encode(s)` is decodable via `RansOrder0.decode` and recovers `s` exactly
  - Same for RansOrder1, BASE_PACK (constrained to ACGT alphabet), NAME_TOKENIZED (constrained to printable ASCII)
  - For any int64 array with values in `[-2^31, 2^31)`, LE-byte serialisation round-trips
  - QUALITY_BINNED encode→decode lossy bound: `|original - decoded| ≤ bin_width / 2`
* `python/tests/test_v5_jcamp_properties.py` — hypothesis-driven JCAMP-DX 5.01 fuzz:
  - Generate plausible LDR sequences; verify `JcampDxReader` either parses cleanly or raises `JcampDxParseError` (never `IndexError`/`KeyError`)
* `java/src/test/java/global/thalion/ttio/V5CodecPropertiesTest.java` — jqwik analogues for the 4 codecs and JCAMP
* `python/pyproject.toml`, `java/pom.xml` — add `hypothesis` / `net.jqwik:jqwik-engine` to test deps

**Acceptance:**
* Each property runs ≥500 generated examples without flake (hypothesis defaults).
* Any genuine bugs surfaced get tracked as separate fix issues; do NOT block V5 acceptance on unrelated bug fixes.
* CI runs the property tests on every PR (default 200 examples to keep CI under 2 min total).

---

### V6 — ObjC + Java stress suite ports

**Effort:** L (2-3 weeks). Can parallelise across languages.

**Scope:** Mirror the Python `tests/stress/` suite into ObjC and Java.
Concurrent reads, large file write/read, and (where applicable)
provider/cloud equivalents.

**Files:**
* ObjC: `objc/Tests/TestV6Concurrency.m` (NSOperationQueue with 10 parallel `TTIOSpectralDataset` reads), `objc/Tests/TestV6LargeFile.m` (write 10M-spectrum .tio in chunks via the streaming writer if it exists, or batch otherwise)
* Java: `java/src/test/java/global/thalion/ttio/stress/V6ConcurrencyTest.java`, `V6LargeFileTest.java`. Use JUnit `@Tag("stress")` so they only run with `-Dgroups=stress` (i.e., scheduled CI, not push/PR).
* `.github/workflows/ci.yml` — extend the nightly schedule to also run ObjC and Java stress jobs (currently nightly only runs Python).

**Acceptance:**
* Each language's stress suite has ≥3 tests that exercise concurrency and ≥1 that exercises 10M+-element scale.
* All three nightly schedules pass on their first run after V6 lands.
* No regressions in push/PR runtime (stress remains nightly-only, gated behind `@pytest.mark.stress` / JUnit tag / GNUstep test selector).

---

### V7 — Codec-layer round-trip cross-language CLIs

**Effort:** S (1 week). **Belt-and-suspenders; lower priority.**

**Scope:** Add small per-language CLIs that take raw bytes on stdin,
encode/decode via a named codec, and emit raw bytes on stdout. Use
them in a Python harness that pipes Python-encoded bytes to
ObjC/Java decoders and vice versa, asserting round-trip equality.

**Note:** This is partially redundant with M86 fixture-byte-exactness
verification. Justified ONLY if a future milestone introduces a
codec where in-band file fixtures don't exercise all encoder edge
cases (e.g., a codec with optional metadata sidecars).

**Files:**
* Python: `python/src/ttio/codecs/cli.py` — `python -m ttio.codecs.cli encode rans_order0 < input > output`
* ObjC: `objc/Tools/TtioCodec.m`
* Java: `java/src/main/java/global/thalion/ttio/codecs/CodecCli.java`
* Harness: `python/tests/integration/test_v7_codec_cross_language.py` — for each of {rans_order0, rans_order1, base_pack, name_tokenized, quality_binned}, generate a sample input, encode in language A, decode in language B (× 6 ordered pairs), assert match.

**Acceptance:**
* All 5 codecs × 6 language-pairs (3-choose-2 × 2 directions) round-trip.
* Default sample inputs are small (≤ 64 KB) to keep CI fast.

**Hold on this until V1-V6 land**; reassess then whether the implicit
M86 fixture coverage is actually sufficient.

---

### V8 — HDF5 corruption / partial-write recovery

**Effort:** M (1-2 weeks).

**Scope:** Verify graceful failure on corrupted/truncated HDF5 files
and document the recovery story (or lack thereof).

**Files:**
* `python/tests/test_v8_hdf5_corruption.py` — generate truncated `.tio` files (last N KB chopped at chunk boundaries), verify reader raises `Hdf5ParseError` with file offset info, not `OSError`/`SystemError`/segfault. Same for header corruption (zero out superblock).
* `objc/Tests/TestV8HDF5Corruption.m` — same scenarios; verify `[TTIOFile openWithPath:error:]` returns `nil` + `NSError` rather than crashing.
* `java/src/test/java/global/thalion/ttio/V8HDF5CorruptionTest.java` — same; verify `Hdf5ReadException` not `IOError` or NPE.
* `docs/recovery-and-resilience.md` — new; documents what guarantees TTI-O makes about partial writes, fsync behaviour, and any per-format recovery hints (e.g., "lost trailing chunk → all preceding chunks still readable").

**Acceptance:**
* Each language has ≥6 corruption scenarios tested (truncation at: superblock, group header, chunk header, mid-chunk; plus zero-byte file; plus 1-byte file).
* The recovery doc accurately reflects what each language does.
* If any language segfaults or hangs on corrupted input, that's a P0 bug — fix before V8 acceptance.

---

### V9 — Provider-specific edge cases

**Effort:** M (1-2 weeks). Python only (ObjC/Java have read-only support for non-HDF5 providers).

**Scope:** Stress the Python providers (Memory, SQLite, Zarr) at their
boundaries.

**Files:**
* `python/tests/test_v9_sqlite_edge.py` — transaction rollback on partial write; lock timeout under contention; BLOB size > 1 GB.
* `python/tests/test_v9_zarr_edge.py` — concurrent chunk writes from multiple processes; v2 → v3 metadata migration; large-array consolidation.
* `python/tests/test_v9_memory_edge.py` — heap-exhaustion graceful degradation; Python `MemoryError` propagates cleanly.

**Acceptance:**
* Each provider has ≥3 edge-case tests passing.
* Failures (if any) trigger spec-doc updates documenting the limit (e.g., "SQLite BLOB > 1 GB is not supported by sqlite3 stdlib; use HDF5 for very large channels").

---

## 3. Recommended sequencing

Phase A (foundational, parallelisable, week 1):
* V1 (coverage) ‖ V3 (matrix doc) — both small, both unblock everything else.

Phase B (instrumentation + correctness, weeks 2-3):
* V2 (perf CI) — needs V1 to know what's exercised, but actually independent. Can run in parallel with V4.
* V4 (edge cases × 3 languages) — straightforward, no blockers.

Phase C (deep verification, weeks 4-6):
* V5 (property-based testing) — bigger lift, but landed early it'll surface bugs that earlier phases would have to re-test.
* V8 (HDF5 corruption recovery) — medium lift; could find segfault bugs that V5 wouldn't.

Phase D (scale + completeness, weeks 7-8):
* V6 (ObjC + Java stress) — biggest single time investment; do last so we know which scale scenarios actually matter from V1 coverage data.
* V9 (Python provider edge cases) — narrow scope; useful but not on critical path.

Phase E (deferred indefinitely):
* V7 (codec-layer cross-language CLIs) — wait until M86 implicit coverage proves insufficient. May never be needed.

**Total estimated time:** 6-8 weeks if mostly sequential, 4-5 weeks if
phases A and B are aggressively parallelised.

## 4. Out-of-scope

These were considered and intentionally excluded:

* **Mutation testing (pitest, mutmut).** Useful but adds significant CI time; revisit after V5 once we have hypothesis baseline.
* **End-to-end workflow tests** (multi-omics integration scenarios). These belong with M91 as feature work, not as verification debt.
* **Cross-OS testing** (Windows, macOS). Repo is Linux-first per the existing convention; adding Windows CI is a separate decision (probably not worth it for a research-focused tool).
* **Browser/JS bindings.** Not in scope for the multi-language reference impl.
* **Coverage threshold enforcement.** V1 publishes %; thresholds are a follow-up V1.1 once we know typical numbers.
* **Continuous fuzzing infrastructure** (OSS-Fuzz, ClusterFuzz). V5's hypothesis/jqwik tests run in CI but aren't continuous fuzzing. If the tool gets significant user adoption, revisit.

## 5. Audit findings table (full)

| # | Gap | Severity | V-milestone | Notes |
|---|---|---|---|---|
| 1 | No coverage instrumentation | High | V1 | Foundation for V2/V4. |
| 2 | No perf regression detection in CI | High | V2 | Existing harnesses are good; just need persistence + CI. |
| 3 | Stress suite is Python-only | Medium | V6 | ObjC/Java behaviour under load is unknown. |
| 4 | No property-based / fuzz testing | Medium-High | V5 | Codec parsers are highest-risk surface. |
| 5 | Edge cases unverified (samtools, malformed, etc.) | Medium | V4 | UX-visible failure modes today. |
| 6 | CRAM cross-language CLI parity | (shipped) | M88.1 | Closed today; removed from this plan. |
| 7 | No persistent perf baseline | High | V2 | Same as #2. |
| 8 | CI doesn't collect coverage/perf metrics | High | V1+V2 | Same as #1+#2. |
| 9 | HDF5 corruption recovery untested | Medium | V8 | P0 if any language segfaults. |
| 10 | Provider edge cases (Python) | Low-Medium | V9 | Narrow scope; SQLite/Zarr/Memory boundaries. |
| 11 | Cross-language matrix not documented | Low | V3 | Doc-only; low effort, high clarity. |
| 12 | Codec-layer cross-language CLIs absent | Low | V7 (deferred) | Already covered implicitly by M86 fixtures. |

---

*This plan is a draft. Once approved, V-series milestones will be
worked in the recommended sequence with HANDOFF specs per milestone
(same pattern as M-series). V-series CHANGELOG entries go under
their own `[Unreleased] — V-series verification debt` section,
separate from M-series milestone entries.*
