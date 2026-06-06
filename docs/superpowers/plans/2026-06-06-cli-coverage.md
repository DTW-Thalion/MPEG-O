# CLI Coverage (R1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Raise CLI-tool coverage across the Python, Java, and ObjC SDKs by exercising tool entry points in a way each coverage tool credits.

**Architecture:** Java + Python are subprocess-blind → add **in-process `main()`** tests (existing templates: `CliSmokeTest.java`, `test_m75_cli_parity.py`). ObjC is NOT subprocess-blind (`build.sh --coverage` feeds every `Tools/obj/*` binary to `llvm-cov` as `-object`; NSTask children inherit `LLVM_PROFILE_FILE`) → add **happy-path NSTask** runs. One behavior-identical Python refactor (extract an `async def serve(...)` seam from `transport_server_cli.main`) makes the blocking server testable in-process.

**Tech Stack:** JUnit 5 (Java), pytest + pytest-asyncio (Python), GNUstep `Testing.h` inline-`PASS` harness (ObjC).

**Note on TDD framing:** Tasks 1, 2, 4, 5 backfill coverage for *existing, working* code — the new tests should **pass on first green run** (a failure means the test is wrong, not the code). For those, "verify it fails" is replaced by "run it and confirm it passes AND exercises the target lines." Task 3 contains a real refactor (a new `serve()` function) and follows strict red→green.

**Build/verify commands (run from WSL):**
- Python: `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest <args>`
- Java: `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -B <args>`
- ObjC: `cd ~/TTI-O/objc && ./build.sh check` (add `--coverage` for the lcov)

---

## File Structure

| File | Responsibility | Task |
|------|----------------|------|
| `java/src/test/java/global/thalion/ttio/tools/CliMainsCoverageTest.java` (create) | In-process happy-path `main()` tests for MzMLProbe, NmrMLProbe, TransportEncodeCli, FastaImportBench | 1 |
| `python/tests/test_c1_cli_mains.py` (modify) | New in-process `main([...])` tests: verify branches, transport_encode branches, pqc round-trips | 2 |
| `python/src/ttio/tools/transport_server_cli.py` (modify) | Extract `async def serve(...)` seam (behavior-identical) | 3 |
| `python/tests/test_c1_cli_mains.py` (modify) | In-process `serve()` bind/stop test | 3 |
| `objc/Tests/TestC1ToolsCli.m` (modify) | Happy-path NSTask runs for one-shot tools + server | 4, 5 |

---

## Task 1: Java — in-process `main()` for the four 0%-coverage tools

**Files:**
- Create: `java/src/test/java/global/thalion/ttio/tools/CliMainsCoverageTest.java`

**Context:** `MzMLProbe`, `NmrMLProbe`, `TransportEncodeCli`, `FastaImportBench` show 0% in `jacoco.csv` because they are only run via `CliSubprocessRunner` (child JVM, invisible to JaCoCo). All four happy paths return normally without `System.exit`, so direct `main()` calls work. This mirrors the existing `CliSmokeTest.java` exactly (reuse its `captureStdout` pattern). Fixtures already in `java/src/test/resources/`: `tiny.pwiz.1.1.mzML`, `bmse000325.nmrML`. `TtioWriteGenomicFixture.main(new String[]{path})` writes a `.tio` (see `CliSmokeTest.buildGenomicFixture`). `FastaImportBench` computes percentile indices `sorted[(int)(n*0.90)]`, so it must get a FASTA with ≥1 sequence (empty → `ArrayIndexOutOfBoundsException`).

- [ ] **Step 1: Read the four tool sources to confirm argv + a stable stdout token**

Run: read `java/src/main/java/global/thalion/ttio/tools/{MzMLProbe,NmrMLProbe,TransportEncodeCli,FastaImportBench}.java`. Confirm: MzMLProbe/NmrMLProbe take `<file>` and print one JSON line; TransportEncodeCli takes `<input.tio> <output.tis>`; FastaImportBench takes `<source.fa> <target.tio>` and prints `BENCH` lines. Note one stable substring each probe prints (e.g. a JSON key) for the assertion.

- [ ] **Step 2: Write the test class**

```java
/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.tools;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.*;

/**
 * In-process coverage for four CLI tools that the bundle JaCoCo report
 * had at 0% line coverage: MzMLProbe, NmrMLProbe, TransportEncodeCli,
 * FastaImportBench.
 *
 * <p>Like {@link CliSmokeTest}, these run {@code main(String[])}
 * in-process because the JaCoCo agent only attaches to the surefire JVM
 * — lines run in a {@link CliSubprocessRunner} child are not recorded.
 * Only happy paths (which return without {@link System#exit(int)}) are
 * exercised here; the usage/error {@code System.exit} branches stay
 * covered by the subprocess tests in {@code C1CliMainsTest}.</p>
 */
public class CliMainsCoverageTest {

    /** Run {@code action} with stdout + stderr swallowed; return stdout. */
    private static String captureStdout(Runnable action) {
        PrintStream origOut = System.out;
        PrintStream origErr = System.err;
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        ByteArrayOutputStream err = new ByteArrayOutputStream();
        try {
            System.setOut(new PrintStream(out));
            System.setErr(new PrintStream(err));
            action.run();
        } finally {
            System.setOut(origOut);
            System.setErr(origErr);
        }
        return out.toString();
    }

    /** Resolve a fixture under src/test/resources via the classloader. */
    private static String fixture(String name) {
        var url = CliMainsCoverageTest.class.getClassLoader().getResource(name);
        assertNotNull(url, "fixture not found on classpath: " + name);
        return url.getFile();
    }

    @Test
    @DisplayName("MzMLProbe: prints JSON for a real mzML fixture in-process")
    void mzmlProbeSmoke() {
        String stdout = captureStdout(() -> {
            try { MzMLProbe.main(new String[]{fixture("tiny.pwiz.1.1.mzML")}); }
            catch (Exception e) { throw new RuntimeException(e); }
        });
        assertTrue(stdout.contains("{") && stdout.contains("}"),
            "MzMLProbe should print a JSON object; got: " + stdout);
    }

    @Test
    @DisplayName("NmrMLProbe: prints JSON for a real nmrML fixture in-process")
    void nmrmlProbeSmoke() {
        String stdout = captureStdout(() -> {
            try { NmrMLProbe.main(new String[]{fixture("bmse000325.nmrML")}); }
            catch (Exception e) { throw new RuntimeException(e); }
        });
        assertTrue(stdout.contains("{") && stdout.contains("}"),
            "NmrMLProbe should print a JSON object; got: " + stdout);
    }

    @Test
    @DisplayName("TransportEncodeCli: encodes a .tio fixture to a non-empty .tis in-process")
    void transportEncodeSmoke(@TempDir Path tmp) throws Exception {
        Path tio = tmp.resolve("encode_src.tio");
        captureStdout(() -> TtioWriteGenomicFixture.main(new String[]{tio.toString()}));
        assertTrue(Files.exists(tio), "fixture .tio should exist");
        Path tis = tmp.resolve("encode_out.tis");
        captureStdout(() -> {
            try { TransportEncodeCli.main(new String[]{tio.toString(), tis.toString()}); }
            catch (Exception e) { throw new RuntimeException(e); }
        });
        assertTrue(Files.exists(tis) && Files.size(tis) > 0,
            "TransportEncodeCli should write a non-empty .tis");
    }

    @Test
    @DisplayName("FastaImportBench: imports a tiny FASTA to a .tio in-process")
    void fastaImportBenchSmoke(@TempDir Path tmp) throws Exception {
        Path fa = tmp.resolve("tiny.fa");
        Files.writeString(fa, ">chr1\nACGTACGTACGTACGTACGT\n>chr2\nTTTTGGGGCCCCAAAA\n");
        Path tio = tmp.resolve("fasta_out.tio");
        String stdout = captureStdout(() -> {
            try { FastaImportBench.main(new String[]{fa.toString(), tio.toString()}); }
            catch (Exception e) { throw new RuntimeException(e); }
        });
        assertTrue(Files.exists(tio) && Files.size(tio) > 0,
            "FastaImportBench should write a non-empty .tio");
        assertTrue(stdout.contains("BENCH"),
            "FastaImportBench should print BENCH lines; got: " + stdout);
    }
}
```

- [ ] **Step 3: Run the new tests and confirm they PASS**

Run: `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -B test -Dtest=CliMainsCoverageTest`
Expected: 4 tests pass. If `fixture()` fails, adjust the resource name in Step 1; if a probe assertion fails, read its actual stdout and tighten the substring.

- [ ] **Step 4: Confirm coverage moved (the four classes off 0%)**

Run: `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -B verify`
Expected: BUILD SUCCESS (JaCoCo gate ≥0.84 still met). Then grep `target/site/jacoco/jacoco.csv` for `MzMLProbe`, `NmrMLProbe`, `TransportEncodeCli`, `FastaImportBench` — each LINE-covered count should now be > 0.

- [ ] **Step 5: Commit**

```bash
git add java/src/test/java/global/thalion/ttio/tools/CliMainsCoverageTest.java
git commit -m "test(java): in-process main() coverage for 4 zero-coverage CLI tools"
```

---

## Task 2: Python — in-process `main([...])` for one-shot CLIs

**Files:**
- Modify: `python/tests/test_c1_cli_mains.py`

**Context:** `test_c1_cli_mains.py` already calls `mod.main([...])` in-process with `capsys` and has `_make_minimal_tio(tmp_path, name)` + `_skip_if_no_liboqs()` helpers. `test_m75_cli_parity.py` proves these round-trips but via subprocess (`python -m`) — which pytest-cov does NOT credit. Porting those round-trips to in-process `main([...])` lifts `ttio_pqc_cli`/`ttio_verify_cli`/`transport_encode_cli` coverage. None of these modules is in the coverage `omit` list. The gated CI job installs `.[test]` (liboqs-python, websockets, opentimspy present) with native liboqs, so pqc-gated tests run. New tests must carry **no** marker (the default filter deselects `slow`/`perf`/`integration`). The signing key + dataset path constants from `test_m75_cli_parity.py`:

```python
FIXTURE_KEY = bytes((0xA5 ^ (i * 3)) & 0xFF for i in range(32))
FIXTURE_KEY_HEX = FIXTURE_KEY.hex()
DATASET_PATH = "/study/ms_runs/run_0001/signal_channels/intensity_values"
```

- [ ] **Step 1: Read the existing fixture helpers in the test file**

Run: read `python/tests/test_c1_cli_mains.py` lines 360–410 to confirm the exact signature of `_make_minimal_tio` (does it return a `Path`? what dataset paths does the resulting `.tio` contain?). If the minimal fixture lacks the MS run at `DATASET_PATH`, copy the `_build_written_run` + `_make_fixture` helpers from `test_m75_cli_parity.py` into this file (or import them) so the sign/verify dataset path exists.

- [ ] **Step 2: Add in-process verify-branch + transport-encode tests**

Append to `python/tests/test_c1_cli_mains.py` (imports go at top of file — `import pytest`, `from pathlib import Path` are already present):

```python
# ── In-process happy-path / error-branch coverage (ported from the
#    subprocess round-trips in test_m75_cli_parity.py, which pytest-cov
#    does not credit). ────────────────────────────────────────────────

_VERIFY_KEY_HEX = bytes((0xA5 ^ (i * 3)) & 0xFF for i in range(32)).hex()
_VERIFY_DATASET = "/study/ms_runs/run_0001/signal_channels/intensity_values"


def test_verify_cli_not_signed_in_process(tmp_path, capsys):
    from ttio.tools import ttio_verify_cli
    src = _make_minimal_tio(tmp_path, "verify_unsigned.tio")
    rc = ttio_verify_cli.main([str(src), _VERIFY_DATASET, _VERIFY_KEY_HEX])
    assert rc == 2
    assert capsys.readouterr().out.strip() == "NOT_SIGNED"


def test_verify_cli_bad_key_length_in_process(tmp_path):
    from ttio.tools import ttio_verify_cli
    src = _make_minimal_tio(tmp_path, "verify_badlen.tio")
    with pytest.raises(SystemExit):
        ttio_verify_cli.main([str(src), _VERIFY_DATASET, "deadbeef"])


def test_verify_cli_non_hex_key_in_process(tmp_path):
    from ttio.tools import ttio_verify_cli
    src = _make_minimal_tio(tmp_path, "verify_nonhex.tio")
    with pytest.raises(SystemExit):
        ttio_verify_cli.main([str(src), _VERIFY_DATASET, "z" * 64])


def test_verify_cli_dataset_not_found_in_process(tmp_path, capsys):
    from ttio.tools import ttio_verify_cli
    src = _make_minimal_tio(tmp_path, "verify_missing_ds.tio")
    rc = ttio_verify_cli.main([str(src), "/does/not/exist", _VERIFY_KEY_HEX])
    assert rc == 3
    assert capsys.readouterr().out.strip() == "ERROR"


def test_verify_cli_open_failure_in_process(tmp_path, capsys):
    from ttio.tools import ttio_verify_cli
    missing = tmp_path / "nope.tio"
    rc = ttio_verify_cli.main([str(missing), _VERIFY_DATASET, _VERIFY_KEY_HEX])
    assert rc == 3
    assert capsys.readouterr().out.strip() == "ERROR"


def test_transport_encode_checksum_and_bulk_in_process(tmp_path):
    from ttio.tools import transport_encode_cli
    src = _make_minimal_tio(tmp_path, "te_src.tio")
    out = tmp_path / "te_out.tis"
    # --checksum and --bulk both run on a minimal MS fixture (--bulk is a
    # documented no-op on MS-only inputs).
    rc = transport_encode_cli.main(
        [str(src), str(out), "--checksum", "--bulk"])
    assert rc == 0
    assert out.exists() and out.stat().st_size > 0
```

- [ ] **Step 3: Add the `--image-processed` branch test (needs an MS image)**

`--image-processed` calls `ds.image_for_kind(ImageKind.MS)`, so the fixture must carry an MS image. Read how other tests build an MS-image `.tio` (grep `image_for_kind` / `write_image` under `python/tests/`); reuse that builder. Then:

```python
def test_transport_encode_image_processed_in_process(tmp_path):
    from ttio.tools import transport_encode_cli
    src = _make_ms_image_tio(tmp_path, "te_img.tio")   # builder from an existing test
    out = tmp_path / "te_img.tis"
    rc = transport_encode_cli.main([str(src), str(out), "--image-processed"])
    assert rc == 0
    assert out.exists() and out.stat().st_size > 0
```

If no reusable MS-image builder exists in the suite, SKIP this single test with `pytest.skip("no MS-image fixture builder available")` rather than inventing one — note it in the commit message as a follow-up. (The `--checksum`/`--bulk` branches in Step 2 still land.)

- [ ] **Step 4: Add in-process pqc round-trips (gated on liboqs)**

```python
def test_pqc_cli_sig_roundtrip_in_process(tmp_path):
    _skip_if_no_liboqs()
    from ttio.tools import ttio_pqc_cli
    pk, sk = tmp_path / "pk.bin", tmp_path / "sk.bin"
    msg, sig = tmp_path / "msg.bin", tmp_path / "sig.bin"
    msg.write_bytes(b"r1 in-process pqc")
    assert ttio_pqc_cli.main(["sig-keygen", str(pk), str(sk)]) == 0
    assert ttio_pqc_cli.main(["sig-sign", str(sk), str(msg), str(sig)]) == 0
    assert ttio_pqc_cli.main(["sig-verify", str(pk), str(msg), str(sig)]) == 0


def test_pqc_cli_kem_roundtrip_in_process(tmp_path):
    _skip_if_no_liboqs()
    from ttio.tools import ttio_pqc_cli
    pk, sk = tmp_path / "kpk.bin", tmp_path / "ksk.bin"
    ct = tmp_path / "ct.bin"
    ss1, ss2 = tmp_path / "ss1.bin", tmp_path / "ss2.bin"
    assert ttio_pqc_cli.main(["kem-keygen", str(pk), str(sk)]) == 0
    assert ttio_pqc_cli.main(["kem-encaps", str(pk), str(ct), str(ss1)]) == 0
    assert ttio_pqc_cli.main(["kem-decaps", str(sk), str(ct), str(ss2)]) == 0
    assert ss1.read_bytes() == ss2.read_bytes()


def test_pqc_cli_hdf5_sign_verify_in_process(tmp_path):
    _skip_if_no_liboqs()
    from ttio.tools import ttio_pqc_cli
    src = _make_minimal_tio(tmp_path, "pqc_hdf5.tio")
    pk, sk = tmp_path / "hpk.bin", tmp_path / "hsk.bin"
    assert ttio_pqc_cli.main(["sig-keygen", str(pk), str(sk)]) == 0
    assert ttio_pqc_cli.main(
        ["hdf5-sign", str(src), _VERIFY_DATASET, str(sk)]) == 0
    assert ttio_pqc_cli.main(
        ["hdf5-verify", str(src), _VERIFY_DATASET, str(pk)]) == 0
```

If `_make_minimal_tio`'s `.tio` lacks `_VERIFY_DATASET`, use the `_make_fixture` builder from Step 1 instead.

- [ ] **Step 5: Run the new tests and confirm they PASS**

Run: `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest tests/test_c1_cli_mains.py -q -k "in_process"`
Expected: all new tests pass (pqc ones run if liboqs present locally, else skip — that's fine; they run in CI).

- [ ] **Step 6: Confirm coverage on the three modules rose and the gate holds**

Run: `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest -q --cov=src/ttio --cov-report=term-missing --cov-fail-under=84 tests/test_c1_cli_mains.py tests/test_m75_cli_parity.py`
Expected: `ttio_verify_cli` and `transport_encode_cli` show higher coverage; suite passes. (Full-suite gate is verified in Task 6's final review.)

- [ ] **Step 7: Commit**

```bash
git add python/tests/test_c1_cli_mains.py
git commit -m "test(python): in-process CLI coverage for verify/transport-encode/pqc"
```

---

## Task 3: Python — `serve()` seam + in-process server test

**Files:**
- Modify: `python/src/ttio/tools/transport_server_cli.py`
- Modify: `python/tests/test_c1_cli_mains.py`

**Context:** `main()` blocks in `asyncio.run(run())` → `await server.wait_closed()` and can't be driven in-process. Extract the serve body into a module-level `async def serve(...)` that `main()` still wraps. **Behavior-identical:** `main()` keeps its signature, still prints `PORT=<n>` (default `on_ready=None` branch), still returns 0 / 130. This is a real refactor → strict TDD (test the new function first).

- [ ] **Step 1: Write the failing test for the new `serve()` seam**

Append to `python/tests/test_c1_cli_mains.py`. Match the async-test style used in `tests/test_transport_server.py` (read it first to copy the `pytest-asyncio` marker / loop setup):

```python
@pytest.mark.asyncio
async def test_transport_server_cli_serve_binds_and_stops(tmp_path):
    _skip_if_optional_dep_missing("ttio.tools.transport_server_cli")
    import asyncio
    from ttio.tools import transport_server_cli
    src = _make_minimal_tio(tmp_path, "serve.tio")
    ports: list[int] = []
    task = asyncio.create_task(
        transport_server_cli.serve(
            str(src), host="127.0.0.1", port=0, on_ready=ports.append)
    )
    try:
        for _ in range(100):
            if ports:
                break
            await asyncio.sleep(0.02)
        assert ports, "serve() did not report a bound port"
        assert ports[0] > 0
    finally:
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
```

- [ ] **Step 2: Run it to confirm it fails (no `serve` attribute)**

Run: `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest tests/test_c1_cli_mains.py::test_transport_server_cli_serve_binds_and_stops -q`
Expected: FAIL with `AttributeError: module 'ttio.tools.transport_server_cli' has no attribute 'serve'`.

- [ ] **Step 3: Extract the `serve()` seam (behavior-identical)**

Replace the body of `python/src/ttio/tools/transport_server_cli.py` from `def main` downward with:

```python
async def serve(
    ttio_path: str,
    *,
    host: str = "127.0.0.1",
    port: int = 0,
    on_ready=None,
) -> None:
    """Serve a .tio file over WebSocket transport until cancelled.

    The bound port is reported via ``on_ready(port)`` if given, else
    printed to stdout as ``PORT=<n>`` (the CLI default). Runs until the
    surrounding task is cancelled or the server is closed.
    """
    server = TransportServer(ttio_path, host=host, port=port)
    await server.start()
    if on_ready is not None:
        on_ready(server.port)
    else:
        print(f"PORT={server.port}", flush=True)
    try:
        await server.wait_closed()
    except asyncio.CancelledError:
        pass
    finally:
        await server.stop()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Serve an TTI-O .tio file over WebSocket transport."
    )
    parser.add_argument("ttio_path", help="path to a .tio file")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0,
                        help="0 = pick any free port (default)")
    args = parser.parse_args(argv)

    try:
        asyncio.run(serve(args.ttio_path, host=args.host, port=args.port))
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run the new test to confirm it passes**

Run: `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest tests/test_c1_cli_mains.py::test_transport_server_cli_serve_binds_and_stops -q`
Expected: PASS.

- [ ] **Step 5: Confirm `main()` still works (parity test green) — no behavior change**

Run: `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest tests/test_c1_cli_mains.py -q -k "transport_server"`
Expected: existing `transport_server_cli` `--help`/no-args parametrized cases still pass (the `print(f"PORT=...")` default path is unchanged).

- [ ] **Step 6: Commit**

```bash
git add python/src/ttio/tools/transport_server_cli.py python/tests/test_c1_cli_mains.py
git commit -m "refactor(python): extract serve() seam from transport_server_cli; in-process server test"
```

---

## Task 4: ObjC — happy-path NSTask runs for one-shot tools

**Files:**
- Modify: `objc/Tests/TestC1ToolsCli.m`

**Context:** `TestC1ToolsCli.m` already fork-execs tools via `c1RunTool(name, args, &out, &err)` and chains `TtioWriteGenomicFixture → TtioVerify → TtioPerAU`. Coverage IS credited for these subprocess runs (NSTask children inherit `LLVM_PROFILE_FILE`; `build.sh` passes each `Tools/obj/*` to `llvm-cov`). The low numbers mean only no-args/error branches run. Add valid-argv happy-path runs for `TtioSign`, `TtioTransportEncode`, `TtioToMzML`, `TtioJcampDxDump`, `TtioSimulator`, `MakeFixtures`. Reuse the `c1RunTool` / `c1ToolMissing` helpers and `NSTemporaryDirectory()`. The ObjC tools mirror their Python/Java equivalents for argv.

- [ ] **Step 1: Confirm each tool's valid argv by reading its main()**

Run: read `objc/Tools/{TtioSign,TtioTransportEncode,TtioToMzML,TtioJcampDxDump,TtioSimulator,MakeFixtures}.m`. Record the exact positional argv each expects (e.g. `TtioSign <tio> <dataset> <keyhex>`, `TtioTransportEncode <in.tio> <out.tis>`, `TtioToMzML <in.tio> <out.mzML>`, `MakeFixtures <out-dir>`/no-arg). For `TtioJcampDxDump`, locate a JCAMP-DX fixture in the tree (grep `*.jdx` / `*.dx` under `objc/` and `python/tests/`); if none exists, leave that one as the existing no-args case and note it.

- [ ] **Step 2: Add a happy-path block inside `testC1ToolsCli`**

Insert before the final closing `}` of `testC1ToolsCli` (after the `TtioBamDump` block), adjusting argv per Step 1 findings. Build a fixture once and chain the encode/sign/export tools off it:

```c
        // ── Happy-path runs for one-shot tools (raise beyond no-args) ──
        if (!c1ToolMissing(@"TtioWriteGenomicFixture")) {
            NSString *hp = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"c1_hp_fixture.tio"];
            [[NSFileManager defaultManager] removeItemAtPath:hp error:NULL];
            NSMutableData *o = nil, *e = nil;
            c1RunTool(@"TtioWriteGenomicFixture", @[hp], &o, &e);

            if ([[NSFileManager defaultManager] fileExistsAtPath:hp]) {
                // TtioTransportEncode <in.tio> <out.tis>
                if (!c1ToolMissing(@"TtioTransportEncode")) {
                    NSString *tis = [NSTemporaryDirectory()
                        stringByAppendingPathComponent:@"c1_hp.tis"];
                    NSMutableData *eo = nil, *ee = nil;
                    int rc = c1RunTool(@"TtioTransportEncode", @[hp, tis], &eo, &ee);
                    PASS(rc == 0 && [[NSFileManager defaultManager]
                            fileExistsAtPath:tis],
                         "C1 ObjC HP: TtioTransportEncode wrote a .tis");
                    [[NSFileManager defaultManager] removeItemAtPath:tis error:NULL];
                }
                // TtioSign <tio> <dataset> <keyhex>   (64 hex chars)
                if (!c1ToolMissing(@"TtioSign")) {
                    NSString *ds =
                        @"/study/genomic_runs/genomic_0001/genomic_index/positions";
                    NSString *keyHex = [@"" stringByPaddingToLength:64
                        withString:@"0" startingAtIndex:0];
                    NSMutableData *so = nil, *se = nil;
                    int rc = c1RunTool(@"TtioSign", @[hp, ds, keyHex], &so, &se);
                    PASS(rc == 0, "C1 ObjC HP: TtioSign on a real dataset exits 0");
                }
            }
            [[NSFileManager defaultManager] removeItemAtPath:hp error:NULL];
        }

        // MakeFixtures writes its fixture set into a target dir.
        if (!c1ToolMissing(@"MakeFixtures")) {
            NSString *dir = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"c1_makefixtures"];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir
                withIntermediateDirectories:YES attributes:nil error:NULL];
            NSMutableData *o = nil, *e = nil;
            int rc = c1RunTool(@"MakeFixtures", @[dir], &o, &e);
            PASS(rc >= 0, "C1 ObjC HP: MakeFixtures runs with an output dir");
            [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
        }
```

For `TtioToMzML` add a run that consumes an MS `.tio` (build one via `MakeFixtures` output or an existing MS fixture) and writes an `.mzML`; for `TtioSimulator` use the argv found in Step 1. Adjust dataset paths / argv to match what the tool sources actually expect (Step 1) — if `TtioSign` uses a different key format, fix the literal here.

- [ ] **Step 3: Build and run the ObjC suite**

Run: `cd ~/TTI-O/objc && ./build.sh check`
Expected: all `PASS` lines green, no `FAIL`. If a tool rejects the argv, correct it per the tool's `main()` (Step 1).

- [ ] **Step 4: Confirm coverage with the lcov build**

Run: `cd ~/TTI-O/objc && ./build.sh --coverage check` (requires `llvm-profdata`/`llvm-cov` — if absent locally, note that CI will confirm; the `check` in Step 3 still proves the runs work).
Expected: `objc/coverage/coverage.lcov` shows higher covered-line counts for `TtioSign.m`, `TtioTransportEncode.m`, `MakeFixtures.m` (and others wired in Step 2).

- [ ] **Step 5: Commit**

```bash
git add objc/Tests/TestC1ToolsCli.m
git commit -m "test(objc): happy-path NSTask runs for one-shot CLI tools"
```

---

## Task 5: ObjC — `TtioTransportServer` launch→PORT→SIGTERM test

**Files:**
- Modify: `objc/Tests/TestC1ToolsCli.m`

**Context:** `TtioTransportServer` is long-running (loops until SIGTERM/SIGINT) and prints `PORT=<n>` on startup. To cover its happy path: launch via `NSTask` (capturing stdout via a pipe), read the `PORT=` line, then send `SIGTERM` and assert a clean teardown. `c1RunTool` uses `waitUntilExit` and reads stdout to EOF — which would block forever on a server. So this needs a dedicated launch path that does NOT `waitUntilExit` before signalling. Read `objc/Tools/TtioTransportServer.m` (Step 1) to confirm argv (likely `<tio> [--port N]`) and that it prints `PORT=` to stdout.

- [ ] **Step 1: Confirm argv and startup output**

Run: read `objc/Tools/TtioTransportServer.m`. Confirm the argv (`<tio> [--port <n>]`) and that it prints a line beginning `PORT=` on stdout once bound, and that `handleSig()` triggers a clean exit on SIGTERM.

- [ ] **Step 2: Add a server smoke that launches, reads PORT, then SIGTERMs**

Add a new block at the end of `testC1ToolsCli` (uses `NSTask.processIdentifier` + `kill`; include `#include <signal.h>` at the top of the file alongside the existing `#include <unistd.h>`):

```c
        // ── TtioTransportServer: launch, read PORT=, then SIGTERM ──────
        if (!c1ToolMissing(@"TtioTransportServer")
                && !c1ToolMissing(@"TtioWriteGenomicFixture")) {
            NSString *srvTio = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"c1_srv.tio"];
            [[NSFileManager defaultManager] removeItemAtPath:srvTio error:NULL];
            NSMutableData *fo = nil, *fe = nil;
            c1RunTool(@"TtioWriteGenomicFixture", @[srvTio], &fo, &fe);

            if ([[NSFileManager defaultManager] fileExistsAtPath:srvTio]) {
                NSString *path = [kToolsDir
                    stringByAppendingPathComponent:@"TtioTransportServer"];
                NSTask *task = [[NSTask alloc] init];
                task.launchPath = path;
                task.arguments = @[srvTio, @"--port", @"0"];
                task.environment = [NSProcessInfo processInfo].environment;
                NSPipe *outPipe = [NSPipe pipe];
                task.standardOutput = outPipe;
                NSFileHandle *rd = [outPipe fileHandleForReading];

                BOOL launched = YES;
                @try { [task launch]; }
                @catch (NSException *exc) { launched = NO; }
                PASS(launched, "C1 ObjC HP: TtioTransportServer launched");

                if (launched) {
                    // Read until we see a PORT= line or time out (~3s).
                    NSMutableData *acc = [NSMutableData data];
                    BOOL sawPort = NO;
                    for (int i = 0; i < 30 && !sawPort; i++) {
                        NSData *chunk = [rd availableData];
                        if (chunk.length) {
                            [acc appendData:chunk];
                            NSString *s = [[NSString alloc] initWithData:acc
                                encoding:NSUTF8StringEncoding];
                            if ([s containsString:@"PORT="]) sawPort = YES;
                        } else {
                            usleep(100000);  // 100ms
                        }
                    }
                    PASS(sawPort,
                         "C1 ObjC HP: TtioTransportServer printed PORT=");
                    kill(task.processIdentifier, SIGTERM);
                    [task waitUntilExit];
                    PASS(YES, "C1 ObjC HP: TtioTransportServer exited after SIGTERM");
                }
            }
            [[NSFileManager defaultManager] removeItemAtPath:srvTio error:NULL];
        }
```

- [ ] **Step 3: Build and run the suite**

Run: `cd ~/TTI-O/objc && ./build.sh check`
Expected: the three new server `PASS` lines green; total runtime increases by only a few seconds. If `availableData` blocks, confirm the tool flushes stdout after printing `PORT=` (Step 1); if the tool prints to stderr instead, attach an `errPipe` and read that.

- [ ] **Step 4: Commit**

```bash
git add objc/Tests/TestC1ToolsCli.m
git commit -m "test(objc): TtioTransportServer launch/PORT/SIGTERM happy-path coverage"
```

---

## Final verification (after all tasks)

- [ ] **Run all three gated suites green:**
  - Python: `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest -q --cov=src/ttio --cov-fail-under=84` → passes, coverage ≥ 84%.
  - Java: `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -B verify` → BUILD SUCCESS (JaCoCo gate met).
  - ObjC: `cd ~/TTI-O/objc && ./build.sh check` → no FAIL.
- [ ] **Push (Windows git) + open PR** against `main` from `coverage-r1-cli-mains`; watch CI; merge once green; sync `main`.
- [ ] **Update memory** with the ObjC subprocess-is-credited finding and the R1 outcome.
```
