# CLI Coverage (R1) — Design

**Date:** 2026-06-06
**Origin:** `docs/architecture/2026-06-06-coverage-analysis.md` recommendation R1.
**Scope:** Raise coverage of the CLI tools across the Python, Java, and ObjC SDKs by
exercising their entry points in a way each coverage tool credits. Test-only work
(plus one behavior-identical Python refactor). No `.tio`/transport wire change, no
public-API break, cross-language conformance untouched.

## Problem

CLI tools read as 0–50% covered across the SDKs. The cause differs by SDK:

- **Java & Python** are genuinely **subprocess-blind**: the CLIs are exercised by
  spawning a child JVM / `python -m`, and JaCoCo / pytest-cov only instrument the test
  process. The fix is to invoke `main()` **in-process**.
- **ObjC is NOT subprocess-blind**: `build.sh --coverage` passes every `Tools/obj/*`
  binary to `llvm-cov` as `-object`, and NSTask children inherit `LLVM_PROFILE_FILE`,
  so subprocess runs are credited. The low numbers reflect tests that only hit
  no-args/error branches. The fix is to **add happy-path NSTask invocations**.

## Approach by SDK

### Java — in-process `main()` (new test class)
Add `java/src/test/java/global/thalion/ttio/tools/CliMainsCoverageTest.java` (JUnit 5),
reusing the established `captureStdout(Runnable)` helper pattern from `CliSmokeTest` /
`V2CliSmokeTest`. All four target tools' happy paths return normally without
`System.exit`, so direct in-process `main()` calls work. Existing `System.exit`
usage/error branches stay covered by the `CliSubprocessRunner` tests — not duplicated.

| Tool | Fixture | Assertion |
|------|---------|-----------|
| `MzMLProbe` | `src/test/resources/tiny.pwiz.1.1.mzML` | stdout contains a JSON key (e.g. `spectrum`) |
| `NmrMLProbe` | `src/test/resources/bmse000325.nmrML` | stdout contains a JSON key |
| `TransportEncodeCli` | `.tio` built via `TtioWriteGenomicFixture` into `@TempDir` | output `.tis` exists and is non-empty |
| `FastaImportBench` | tiny inline `.fa` (≥1 sequence) → `.tio` in `@TempDir` | output `.tio` exists; stdout contains `BENCH` |

`FastaImportBench` must receive a FASTA with at least one sequence — an empty FASTA
throws on the percentile index (`sorted[(int)(n*0.90)]` with `n==0`).

### Python — in-process `main([...])` (extend `test_c1_cli_mains.py`)
Add tests calling `mod.main([...])` directly with `capsys`, building fixtures via the
existing `_make_minimal_tio` / `_make_fixture` helpers. New tests carry **no** marker
(the default filter deselects `slow`/`perf`/`integration`). Optional-dep gating mirrors
existing tests (`_skip_if_no_liboqs`, `_skip_if_optional_dep_missing`, `find_spec`).
The gated CI job installs `.[test]` (includes `liboqs-python`, `websockets`,
`opentimspy`) with native liboqs preinstalled, so these tests run (not skip) and move
the gated number. None of the four modules is in the coverage `omit` list.

- `ttio_pqc_cli`: port the sig/kem/hdf5 round-trips from the subprocess
  `test_m75_cli_parity.py` to in-process `main([...])` (gated on `oqs`).
- `ttio_verify_cli`: add `NOT_SIGNED` (status 2), bad-key `SystemExit` (length / non-hex),
  dataset-not-found `KeyError`, not-a-dataset, and `OSError` open-failure branches.
- `transport_encode_cli`: add `--checksum`, `--bulk`, and `--image-processed` branches
  (`--image-processed` needs a `.tio` carrying an MS image; `--bulk` is a harmless no-op
  on the minimal MS fixture).
- `transport_server_cli`: see the seam below.

#### `transport_server_cli` seam (behavior-identical refactor)
`main()` currently blocks in `asyncio.run(run())` → `await server.wait_closed()` until
SIGTERM/KeyboardInterrupt, which cannot be driven in-process. Refactor the serve body
into a module-level `async def serve(ttio_path, host, port, *, ready=None)` coroutine
that `main()` still wraps via `asyncio.run`. `main()`'s observable behavior is
unchanged (same stdout `PORT=<n>` line, same return codes, same signature). The test
drives `serve()` in-process with `asyncio.wait_for` / task cancellation — starting it
on `--port 0`, confirming it binds and prints the port, exercising one request via the
existing client, then cancelling. The underlying `TransportServer`/`serving` is already
covered; this closes the thin CLI wrapper.

### ObjC — happy-path NSTask (extend `TestC1ToolsCli.m`)
No production change. Extend the existing fork-exec test (`objc/Tests/TestC1ToolsCli.m`,
which already runs each tool via `NSTask` from `Tools/obj`) with valid-argv happy-path
runs. Build a fixture (or reuse one produced by an earlier tool in the chain, mirroring
the existing `TtioWriteGenomicFixture → TtioVerify` chaining), run the tool, assert
exit 0 and that the expected output file/stdout appears.

- One-shot tools: `TtioSign`, `TtioToMzML`, `TtioJcampDxDump`, `TtioTransportEncode`,
  `TtioSimulator`, `MakeFixtures`.
- `TtioTransportServer` (long-running): launch via `NSTask`, read the `PORT=<n>` line
  from stdout, connect a `TTIOTransportClient` to exercise one request, send `SIGTERM`,
  assert a clean exit.

## Invariants
- Test-only across all three SDKs. The single Python `serve()` extraction is a
  behavior-identical refactor — no wire format, no on-disk format, no `main` signature
  or public-API change.
- Cross-language conformance/parity suites untouched.
- Each SDK independently verifiable:
  - Python: `cd python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest -q` and the gated `--cov-fail-under=84` run.
  - Java: `cd java && JAVA_HOME=~/jdk25 mvn -o -B verify` (JaCoCo gate at BUNDLE LINE ≥ 0.84).
  - ObjC: `cd objc && ./build.sh --coverage check`.

## Success criteria
- The four Java tool classes move off 0% (visible in `jacoco.csv`).
- Python `transport_encode_cli` / `ttio_verify_cli` / `ttio_pqc_cli` /
  `transport_server_cli` rise materially; overall Python coverage stays ≥ 84%.
- ObjC tool happy-path lines covered (visible in `coverage.lcov`); `build.sh check` green.
- All three gated suites remain green. Single PR, test-only.

## Out of scope (tracked separately)
R2 (ObjC scope fix + gate), R3 (fqzcomp codec tests), R4 (Java branch gate),
R5/R6 (per-class floor + ratchet), R7/R8 (live-daemon + native coverage).
