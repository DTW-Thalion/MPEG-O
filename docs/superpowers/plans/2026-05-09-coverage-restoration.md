# Coverage Restoration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore Java JaCoCo BUNDLE LINE coveredratio and Python `--cov-fail-under` from the temporarily-lowered **0.76** floors back to ~**0.84** by writing targeted tests for code that recent feature work added without coverage. No threshold raises without backing tests.

**Architecture:** Two parallel tracks (Python + Java), each ordered by uncovered-line yield. Each task adds a focused test file, verifies the resulting coverage delta, and commits. Once both tracks complete, raise both gates back to 0.84 in a final lockstep PR.

**Tech Stack:** pytest + coverage.py (Python), JUnit 5 + JaCoCo 0.8.12 (Java). No new dependencies.

---

## Context: where the drift came from

The bundle aggregate dropped during the 2026-05-08 feature push:
- **PRs #41/#42** (Phase 10/11 Transport download + upload): new Python `client.py` + `codec.py` + `encrypted.py` and Java `TransportReader`/`TransportWriter`/`TransportClient` shipped without targeted unit tests. Cross-language conformance covers happy paths but leaves error branches and parameter variants uncovered.
- **PR #35** (HDF5 1.14 + Java 21 FFM): `Hdf5CompoundIO` got a VL_BYTES rewrite via `VlBytesFFM.java`. FFM code is hard to unit-test, and the existing compound-IO tests don't exercise VL_BYTES schemas.
- **PR #44** (liboqs defensive `_oqs()` catch): added `(RuntimeError, OSError)` then PR #46 broadened to `(..., AttributeError)`. The catch tuple's branches are exercised only when liboqs is missing/mismatched — environments that aren't a default `pytest -m "not slow and not perf and not integration"` run.
- **PR #47** (perf-mark on throughput tests): `test_14_throughput_pure_acgt_10mb` and `test_13_throughput` were the only callers of some decoder paths under the default `-m 'not perf'` filter.
- **CLI tools at 0%**: 6 Java tools.* classes (PQCTool, Benchmark, DumpIdentifications, TtioVerify, TtioWriteGenomicFixture, ProvenanceJsonParse) sum to ~560 uncovered lines that no test ever exercises. Same pattern likely on the Python side under `ttio/tools/` (16 CLI modules).

## Concrete current numbers

Run locally on `main` at `51a2975` (PR #49):

**Java:** Bundle line coverage **0.7703** (12,447 / 16,158).
- To hit 0.84 → need to cover **~1,126 more lines** (84% × 16,158 = 13,573).

**Python:** Default-filter pytest coverage **76.95%** (per the failing CI run on commit `bdf8466`).
- Exact line counts to be regenerated as the first step of this plan.

---

## Track P — Python (target: 76.95% → 84%)

### Task P.0: Generate fresh coverage baseline

**Files:**
- Run only: `cd python && rm -f .coverage && pytest -v --tb=short --cov=src/ttio --cov-report=term-missing --cov-report=html`

- [ ] **Step 1: Clean stale `.coverage`** (current file references a deleted source path).

```
rm -f python/.coverage python/htmlcov
```

- [ ] **Step 2: Run pytest with coverage**

```
cd python
pytest -v --tb=short --cov=src/ttio --cov-report=term-missing --cov-report=html
```

Expected: ~76.95% aggregate; tests all pass (PR #49 bumped --cov-fail-under to 76 so this won't fail).

- [ ] **Step 3: Snapshot worst-covered files**

```
python -m coverage report --skip-covered --sort=miss --skip-empty 2>&1 | head -40
```

Save output. Confirm the candidates below are still the dominant gaps. Adjust task ordering if reality differs.

- [ ] **Step 4: No commit** — this task is investigative only.

---

### Task P.1: Cover `ttio.transport.client` + `ttio.transport.codec` + `ttio.transport.encrypted`

**Files:**
- Test: `python/tests/test_transport_client_unit.py` (new)
- Test: `python/tests/test_transport_codec_unit.py` (new)
- Test: `python/tests/test_transport_encrypted_unit.py` (new)

**Why:** These three modules shipped in PRs #41/#42 with cross-language conformance coverage only. Error branches, malformed input handling, and parameter variants are uncovered. Each module is small (≤200 lines) — a single focused test file per module hits >80% on each.

- [ ] **Step 1: Read the source for each module.**

```
cat python/src/ttio/transport/{client,codec,encrypted}.py
```

Identify the **public surface** (exported names in `__all__` or class/function defs at top level). For each, list:
- Happy-path input
- Error branches (`raise X`, `if invalid: ...`)
- Optional-parameter variants

- [ ] **Step 2: Write `test_transport_codec_unit.py` first** (smallest module).

For each public function in `codec.py`:
- A happy-path round-trip (encode → decode → assert equal)
- One malformed-input test asserting the right exception type
- One edge-case test (empty input, max-size input, etc.)

Run the new test:
```
pytest tests/test_transport_codec_unit.py -v
```

Expected: all pass.

- [ ] **Step 3: Verify coverage delta on `transport/codec.py`**

```
coverage report --include="*/transport/codec.py"
```

Expected: ≥80%. If not, examine the `Missing` column and add targeted tests.

- [ ] **Step 4: Write `test_transport_encrypted_unit.py`** (similar pattern).

Same shape as Step 2; commit and verify.

- [ ] **Step 5: Write `test_transport_client_unit.py`**

Mock the WebSocket layer (use `unittest.mock` or a fake server fixture). Cover:
- `client.fetch_packets(filters=None)` happy path
- `client.fetch_packets({"ms_level": 2})` filter variant
- `client.stream_to_file(out, filters)` materialization
- Error branches (connection refused, malformed packet stream)

- [ ] **Step 6: Commit**

```
git add python/tests/test_transport_*.py
git commit -m "test(python): unit-test ttio.transport modules for coverage restoration"
```

---

### Task P.2: Cover `ttio.pqc` defensive `_oqs()` branches

**Files:**
- Test: `python/tests/test_pqc_unit.py` (new or extend existing `test_milestone49_pqc.py`)

**Why:** `_oqs()` catches `(RuntimeError, OSError, AttributeError)` to gracefully degrade when liboqs is missing or ABI-mismatched. The defensive branches were the explicit fix in PR #44 + PR #46 but no test exercises them. Each `except` line is uncovered.

- [ ] **Step 1: Use `unittest.mock` to inject failures.**

```python
def test_oqs_handles_runtime_error(monkeypatch):
    import ttio.pqc as pqc
    def fake_import(name, *a, **kw):
        if name == "oqs":
            raise RuntimeError("No oqs shared libraries found")
        return __builtins__.__import__(name, *a, **kw)
    monkeypatch.setattr("builtins.__import__", fake_import)
    with pytest.raises(pqc.PQCUnavailableError, match="liboqs"):
        pqc._oqs()
```

Repeat for `OSError`, `AttributeError`, `ImportError`. 4 tests total.

- [ ] **Step 2: Run + verify**

```
pytest tests/test_pqc_unit.py -v
coverage report --include="*/pqc.py"
```

Expected: pqc.py to ≥85% (the remaining gap is real liboqs API calls under `is_available() == True`).

- [ ] **Step 3: Commit**

---

### Task P.3: Cover `ttio.tools.*` CLI modules

**Files:**
- Test: `python/tests/test_cli_smoke.py` (new) — extends the existing `test_c1_cli_mains.py` pattern

**Why:** `tests/test_c1_cli_mains.py` covers `python -m <cli>` exit codes for "no args" only. The CLIs themselves have argument parsing, file I/O, and error handling that's never exercised — same pattern as Java's tools/ at 0%.

- [ ] **Step 1: For each CLI in `python/src/ttio/tools/*_cli.py`**, run with realistic args.

Pattern (use `subprocess.run` with `--help` first to learn the args, then a real invocation):

```python
def test_dump_identifications_smoke(tmp_path):
    fixture = "tests/fixtures/m82_100reads.tio"
    result = subprocess.run(
        [sys.executable, "-m", "ttio.tools.dump_identifications", fixture],
        capture_output=True, text=True
    )
    assert result.returncode == 0
    assert result.stdout  # produced output
```

Cover at minimum: `dump_identifications`, `per_au_cli`, `simulator_cli`, `transport_encode_cli`, `transport_decode_cli`, `fasta_{import,export}_cli`, `fastq_{import,export}_cli`. Skip `ttio_pqc_cli` and `ttio_sign_cli`/`ttio_verify_cli` if liboqs absent (use existing `pqc.is_available()` gate).

- [ ] **Step 2: Verify per-file coverage**

```
coverage report --include="*/tools/*"
```

Expected: each tool ≥60%.

- [ ] **Step 3: Commit**

---

### Task P.4: Cover decoder paths previously exercised by perf-marked tests

**Files:**
- Test: `python/tests/test_codec_decode_paths.py` (new)

**Why:** When PR #47 marked `test_14_throughput_pure_acgt_10mb` and `test_13_throughput` as `@pytest.mark.perf`, the decoder paths in `ttio/codecs/base_pack.py` and `ttio/codecs/quality.py` lost their only default-suite caller for some branches. Recover with targeted small-input tests that don't have throughput assertions.

- [ ] **Step 1: Read the perf tests** to understand which API paths they exercised.

```
sed -n '320,345p' python/tests/test_m84_base_pack.py
sed -n '318,345p' python/tests/test_m85_quality.py
```

- [ ] **Step 2: Write equivalent small-input tests without throughput assertions.**

```python
def test_base_pack_decode_small_input():
    from ttio.codecs.base_pack import encode, decode
    data = b"ACGT" * 64  # 256 bytes — small, fast, deterministic
    enc = encode(data)
    assert decode(enc) == data

def test_quality_decode_small_input():
    from ttio.codecs.quality import encode, decode
    data = bytes(b % 41 for b in range(1024))
    enc = encode(data)
    # quality is lossy; assert binned-equivalence using existing helper
```

- [ ] **Step 3: Verify coverage**

```
coverage report --include="*/codecs/base_pack.py" --include="*/codecs/quality.py"
```

- [ ] **Step 4: Commit**

---

### Task P.5: Verify aggregate ≥84% and bump gates

**Files:**
- Modify: `python/pyproject.toml` (`[tool.coverage.report]` `fail_under`)
- Modify: `.github/workflows/ci.yml` (`--cov-fail-under` flag)

- [ ] **Step 1: Run full coverage**

```
coverage report
```

If aggregate ≥84% — proceed to step 2. If 80–84% — add ≥80% targeted tests on next-worst file (likely `ttio/_hdf5_io.py` or `ttio/codecs/fqzcomp_nx16_z.py`). If <80% — back to P.1–P.4 to see what under-delivered.

- [ ] **Step 2: Bump gates in lockstep**

Edit `python/pyproject.toml`:
```diff
-fail_under = 76
+fail_under = 84
```

Edit `.github/workflows/ci.yml`:
```diff
-        run: pytest -v --tb=short --cov=src/ttio --cov-report=term --cov-report=xml --cov-report=html --cov-fail-under=76
+        run: pytest -v --tb=short --cov=src/ttio --cov-report=term --cov-report=xml --cov-report=html --cov-fail-under=84
```

Update the comment block in pyproject.toml to remove the "lowered post-#48" note.

- [ ] **Step 3: Run `pytest --cov` locally** to confirm gate passes.

- [ ] **Step 4: Commit**

```
git commit -m "test(python): restore coverage gate to 84% — backed by targeted tests for transport/, pqc/, tools/, codecs/"
```

---

## Track J — Java (target: 77.03% → 84%)

### Task J.1: Cover `tools.*` CLI classes (0% coverage, ~560 lines)

**Files:**
- Test: `java/src/test/java/global/thalion/ttio/tools/CliSmokeTest.java` (new — single class with one test method per CLI)

**Why:** Six classes at 0% coverage:
- `PQCTool` (201 lines) — gate via Bouncy Castle availability
- `ProvenanceJsonParse` (96 lines)
- `Benchmark` (77 lines)
- `DumpIdentifications` (75 lines)
- `TtioVerify` (61 lines)
- `TtioWriteGenomicFixture` (50 lines)

Total: 560 uncovered. Each is a `main(String[])` entry point — a smoke test with realistic args via `Runtime.exec` lights up parsing + happy path. Pattern: `CliSubprocessRunner` test util introduced in Java 21 SecurityManager refactor.

- [ ] **Step 1: Read existing `CliSubprocessRunner`** (added during the Java 21 SecurityManager refactor; should be in `java/src/test/java/global/thalion/ttio/test/util/`).

Confirm its API (likely `runMain(Class<?>, String...) → ProcessResult`).

- [ ] **Step 2: Write `CliSmokeTest`** with one method per tool:

```java
@Test
void dumpIdentifications_runsAgainstFixture(@TempDir Path tmp) throws Exception {
    Path fixture = Path.of("src/test/resources/ttio/m82_100reads.tio");
    var result = CliSubprocessRunner.runMain(
        DumpIdentifications.class,
        fixture.toString()
    );
    assertEquals(0, result.exitCode());
    assertFalse(result.stdout().isBlank());
}
```

Repeat for the other 5 tools. Each method covers ~50–200 lines of CLI dispatch + arg parsing + happy-path call.

- [ ] **Step 3: Run targeted**

```
mvn -B test -Dtest=CliSmokeTest -Dhdf5.jar=/usr/local/lib/jarhdf5.jar
```

- [ ] **Step 4: Verify coverage delta**

```
mvn -B test jacoco:report -Dhdf5.jar=/usr/local/lib/jarhdf5.jar
# Check target/site/jacoco/global.thalion.ttio.tools/index.html
```

Expected: tools.* aggregate ≥60%.

- [ ] **Step 5: Commit**

---

### Task J.2: Cover `transport.TransportReader` + `TransportWriter`

**Files:**
- Test: `java/src/test/java/global/thalion/ttio/transport/TransportReaderUnitTest.java` (new)
- Test: `java/src/test/java/global/thalion/ttio/transport/TransportWriterUnitTest.java` (new)

**Why:** PR #41/#42 added these as part of Phase 10/11. `TransportClientTest` (now skip-when-Python-missing) is the only existing coverage. Reader: 70 missed of 202 (65.3%). Writer: 68 missed of 327 (79.2%).

- [ ] **Step 1: Read both classes** to map public surface.

- [ ] **Step 2: Build `TransportWriterUnitTest`**

A focused test that:
- Constructs a small `SpectralDataset` in `@TempDir`
- Writes to a byte stream via `TransportWriter`
- Re-reads via `TransportReader`
- Asserts byte-exact round-trip

Cover error branches: malformed packet header, payload-length mismatch, magic byte mismatch.

- [ ] **Step 3: Build `TransportReaderUnitTest`**

Cover packet decoding directly (without the writer): construct minimal byte streams, verify `decodePacket` returns the right structures.

- [ ] **Step 4: Verify coverage**

Look at `target/site/jacoco/global.thalion.ttio.transport/`.
Expected: both classes ≥85%.

- [ ] **Step 5: Commit**

---

### Task J.3: Cover `hdf5.Hdf5CompoundIO` VL_BYTES paths (PR #35 debt)

**Files:**
- Test: `java/src/test/java/global/thalion/ttio/hdf5/Hdf5CompoundIOVlBytesTest.java` (new)

**Why:** `Hdf5CompoundIO` 138 missed of 340 (59.4%). The `VlBytesFFM` rewrite from PR #35 is the dominant gap. FFM code can be tested by exercising compound writes with VL_BYTES schemas — direct unit tests against the public `Hdf5CompoundIO.write(...)` API.

- [ ] **Step 1: Read `VlBytesFFM`** to understand the FFM allocation pattern.

- [ ] **Step 2: Write tests that exercise**:
- A compound type with one VL_BYTES column + one fixed column
- A compound type with multiple VL_BYTES columns
- VL_BYTES with empty bytes (zero-length cell)
- VL_BYTES with bytes near the largest expected size
- Round-trip: write compound → read compound → assert byte-equal cells

- [ ] **Step 3: Verify coverage**

```
target/site/jacoco/global.thalion.ttio.hdf5/Hdf5CompoundIO.html
target/site/jacoco/global.thalion.ttio.hdf5/VlBytesFFM.html
```

Expected: Hdf5CompoundIO ≥80%, VlBytesFFM ≥75% (some FFM lifecycle paths only fire on JVM cleanup).

- [ ] **Step 4: Commit**

---

### Task J.4: Cover `providers.ZarrProvider` (108 missed)

**Files:**
- Test: `java/src/test/java/global/thalion/ttio/providers/ZarrProviderUnitTest.java` (new)

**Why:** Existing tests mostly use the HDF5 provider. Zarr backend ships in production but has 63.1% coverage. Cover with targeted dataset writes.

- [ ] **Step 1: Find existing zarr-related test fixtures** (likely under `java/src/test/resources/zarr/`).

- [ ] **Step 2: Write tests that** create a dataset via `ZarrProvider`, write a few groups + datasets, read them back, assert structure.

- [ ] **Step 3: Verify coverage** ≥80%.

- [ ] **Step 4: Commit**

---

### Task J.5: Verify aggregate ≥84% and bump gate

**Files:**
- Modify: `java/pom.xml` (`<minimum>` value in jacoco-check)

- [ ] **Step 1: Run `mvn -B verify`**

Confirm aggregate from `target/site/jacoco/index.html` is ≥84%. If 80–84%, add ≥80% targeted tests on `genomics.GenomicRun` (107 missed) or `SpectralDataset` (225 missed). If <80%, revisit J.1–J.4.

- [ ] **Step 2: Bump JaCoCo threshold**

Edit `java/pom.xml`:
```diff
-                                            <minimum>0.76</minimum>
+                                            <minimum>0.84</minimum>
```

Update the comment block to remove the "lowered to 0.76 to accommodate VL_BYTES FFM" note since the FFM paths are now covered.

- [ ] **Step 3: Run `mvn -B verify`** locally to confirm gate passes.

- [ ] **Step 4: Commit**

```
git commit -m "test(java): restore JaCoCo gate to 84% — backed by targeted tests for tools/, transport/, hdf5/, providers/"
```

---

## Final integration

### Task F.1: Single PR with both gate raises

**Files:**
- All test files from P.1–P.4 + J.1–J.4 already committed individually
- Final commit raises both gates together

- [ ] **Step 1: Open PR with title** `test: restore Java + Python coverage gates to 0.84 (post-CI campaign restoration)`

- [ ] **Step 2: PR body lists** which uncovered code each test file targets, total lines covered, before/after percentages.

- [ ] **Step 3: Wait for CI green** — both Java JaCoCo and Python `--cov-fail-under` should pass at 0.84.

- [ ] **Step 4: Merge**

---

## Deferred / out of scope

- **Vendor-importer files** (Bruker / Thermo / Waters in both Python and Java) stay excluded — they need proprietary fixtures we don't have.
- **`codecs.FqzcompNx16Z`** Java class (497 missed of 613 = 18.9%) — to hit ≥80% on this class would require a substantial corpus of FASTQ-shaped test data and adds materially to the work. Defer to a "v0.11 codec coverage" workstream.
- **Hypothesis-based property tests** for codecs — listed in the V5 verification workplan; orthogonal to gate restoration.
- **Coverage reports beyond line/branch** (mutation testing, dataflow) — out of scope.

## Self-review

**Spec coverage:** ✓ Both gates have a Track. ✓ Each gap source from the CI campaign is addressed (PRs #41/#42 transport in P.1+J.2, PR #35 FFM in J.3, PR #44 catch in P.2, PR #47 perf-mark in P.4, the structural CLI 0% gap in P.3+J.1). ✓ Final integration in Track F.

**Type consistency:** ✓ Test class names match conventions (`*Test.java`, `test_*.py`). ✓ Coverage thresholds named consistently (0.76 → 0.84).

**Placeholder check:** ✓ Each step has a concrete command or code block. ✓ No "TBD", "implement later", or "see plan".
