# Contributing to TTI-O

TTI-O is a multi-language reference implementation (Python, Java,
Objective-C) for a multi-omics data standard. Each language is
independently testable; cross-language byte-equality is verified
by a dedicated harness.

## Quick start (Python)

```bash
# 1. System prerequisites (Ubuntu 24.04 / WSL):
sudo apt-get install -y zlib1g-dev cmake ninja-build
bash scripts/install-hdf5.sh   # builds + installs HDF5 1.14.6 to /usr/local

# 2. One-shot dev setup: builds the native rANS library + installs
#    Python with the broadest test extras + prints env vars.
scripts/dev-setup.sh

# 3. Set the env var the script printed:
export TTIO_RANS_LIB_PATH="$(pwd)/native/_build/libttio_rans.so"

# 4. Run the Python suite:
cd python && pytest tests/ -q --ignore=tests/stress
```

A clean Python+native install reaches **~1365 passing tests, ~4
skipped, 1 xfailed**. Skips are vendor-format integration tests
that need optional fixtures (see "Optional vendor-format fixtures"
below); the xfail is by-design (separate Java process can't see a
Python in-memory store).

## Repository layout

| Directory | Purpose |
|-----------|---------|
| `python/` | Python reference implementation (`ttio` package), the canonical write path. |
| `java/`   | Java reference implementation (Maven, JDK 22). |
| `objc/`   | Objective-C reference implementation (GNUstep). |
| `native/` | C library `libttio_rans` — the v2 codec kernels (rANS, ref_diff_v2, mate_info_v2, name_tokenized_v2, fqzcomp_nx16_z). All three language bindings link against it. |
| `docs/`   | Specs, ADRs, codec design docs, test strategy, vendor-format mappings. |
| `data/`   | Reference data + `.sha256` manifests for fetched fixtures. NOT committed binaries. |
| `scripts/`| Setup + fixture-fetch helpers. |

## Native rANS library

`libttio_rans.so` (or `.dylib` on macOS, `.dll` on Windows) is
mandatory at runtime for the v2 genomic codecs. Build via the
provided idempotent script:

```bash
bash scripts/build-native.sh           # C-only library (ObjC, Python ctypes)
bash scripts/build-native.sh --jni     # plus libttio_rans_jni.so (Java JNI)
export TTIO_RANS_LIB_PATH="$(pwd)/native/_build/libttio_rans.so"
```

The script is idempotent and invoked automatically by `objc/build.sh`
(so `./build.sh` from `objc/` will build the native lib first if
missing) and by the ObjC CI job. Python and Java CI jobs use the
`--jni` flag to also produce `libttio_rans_jni.so` for the JNI
wrapper.

Tests look up the library via `TTIO_RANS_LIB_PATH` first, then
fall back to `native/_build/libttio_rans.so` from the repo root.

## Java

```bash
cd java
mvn verify
```

Cross-language tests need the same `libttio_rans` on
`java.library.path`; the resolver in
`python/tests/validation/test_cross_language_smoke.py` injects the
correct path automatically when subprocessing into Java tools.

## Objective-C

```bash
source /usr/share/GNUstep/Makefiles/GNUstep.sh
cd objc/Source && make    # build libTTIO
cd ../Tests && make       # build TTIOTests test runner
cd ../Tools && make       # build CLI tools (TtioVerify, TtioSign, TtioFastaRoundTrip, …)
```

The cross-language test harness assumes `objc/Tools/obj/<Tool>`
binaries exist — `make` from `objc/Tools/` is a prerequisite.

## Optional vendor-format fixtures

`docs/test-strategy.md` covers the full setup. tldr:

```bash
scripts/fetch-vendor-fixtures.sh         # downloads + sha256-verifies
export TTIO_THERMO_RAW_FIXTURE="$HOME/fixtures/thermo/small.RAW"
export TTIO_BRUKER_TDF_FIXTURE="$HOME/fixtures/bruker/diaPASEF.d"
```

The Thermo test additionally requires `mono-complete` + the
`ThermoRawFileParser` v1.4.5 release on `PATH` — see
`docs/test-strategy.md` § "Thermo `.raw` delegation" for the
exact apt + curl + wrapper-script steps.

The Waters MassLynx test requires the proprietary `MassLynxRaw`
SDK which only ships on Windows; the test skips cleanly on Linux
even when `TTIO_MASSLYNX_FIXTURE` is set.

## Test strategy and CI

- `docs/test-strategy.md` is the canonical map of which test file
  covers which behaviour, including the cross-language conformance
  matrices and the optional fixture flow.
- `.github/workflows/ci.yml` runs `objc-build-test`, `python-test`
  (Python 3.11 + 3.12 matrix), `java-test`, `python-validation`,
  and `cross-compat` on every push + PR. All Python jobs build
  the native rANS library before running pytest.

## Code style and reviews

- Python: PEP 8 / `ruff`-style (no enforced linter yet); 79-char
  preferred but not strict; type hints on public APIs. `numpydoc`
  docstrings on public classes and functions.
- Java: the existing code follows standard Sun/Oracle Java style;
  `mvn verify` gates the build.
- ObjC: OpenStep-style `@interface ... @end` documentation
  comments (Inherits From / Conforms To / Declared In headers);
  see `docs/superpowers/skills/openstep/openstep.md` for the
  template if you're adding a new public class.

For non-trivial changes, run the full Python suite + the
language-specific suites you touched, plus the cross-language
matrices:

```bash
cd python && pytest tests/validation -q          # cross-language
cd java   && mvn verify                          # Java unit + integration
cd objc/Tests && make check                      # ObjC test runner
```

## Benchmarks

Three parallel timing-loggers, one per language. All emit the
same JSON schema so a single `jq` over the three result files
diffs cleanly across release tags:

```bash
# Python — runs the full stress matrix (provider + FASTA/FASTQ
# + production-corpus + Phase 2c-T bulk-mode). Results land in
# python/tests/stress/benchmark_results.json.
cd python && pytest tests/stress -v

# Long-tail FASTQ scaling cells (100K + 1M reads, ~2 minutes):
TTIO_INCLUDE_LONG_TAIL=1 pytest tests/stress/test_fasta_fastq_benchmark.py

# Java — transport encode + decode timing on a source .tio.
java -Djava.library.path=$REPO/native/_build:/usr/lib/x86_64-linux-gnu/jni \
     -cp "java/target/classes:$(deps):/usr/local/lib/jarhdf5.jar" \
     global.thalion.ttio.tools.Benchmark <source.tio> [output.json]

# ObjC — same shape via mono-free Objective-C binary.
LD_LIBRARY_PATH=$REPO/objc/Source/obj \
TTIO_RANS_LIB_PATH=$REPO/native/_build/libttio_rans.so \
$REPO/objc/Tools/obj/TtioBenchmark <source.tio> [output.json]
```

Headline numbers + interpretation are in
`docs/benchmarks/2026-05-05-v1.0-comprehensive-perf-report.md`.

## License

TTI-O is LGPL-3.0-or-later. Contributions are accepted under the
same terms (no separate CLA).
