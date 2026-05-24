# tio-browser

JavaFX desktop application for inspecting, importing, exporting,
encoding, and transporting TTI-O `.tio` multi-omics datasets — and the
desktop client for the **TTI-O Workbench** server. Built on the
[`global.thalion:ttio`](../java) Java library.

## Features

### `.tio` browsing

- Open a `.tio` container; inspect its `SpectralDataset` tree, MS / NMR
  / vibrational / UV-Vis runs, `GenomicRun` reads + index, provenance
  chains, identifications + quantifications.
- Per-spectrum / per-read inspector with channel-level signal plots.

### TTI-O Workbench Client (W1–W6, v1.5.0)

| Panel | Capability | Workplan |
|---|---|---|
| Connection Manager | Bootstrap-admin login (username + password + TOTP) against a workbench daemon; live connection-status indicator. | W5.1 |
| Container Browser | Paged `GET /v1/containers` listing with project / owner / encryption filters. | W5.2 |
| Transfer Manager + Selective Access | Per-AU upload + download with a filter builder (RT / MS level / chromosome / position predicates). Determinate progress bar (W6.1b). | W5.3 / W6.1 |
| Cohort Query Builder | Compose `POST /v1/cohorts/query` JSON predicates over phenotype / container / subject / sample fields; preview-count and full-rows modes; cursor pagination. | W5.4 |
| Pipeline Launcher + Job Monitor | Submit jobs to the server, watch live status + logs, cancel running jobs. | W5.5 |
| Interactive Session Launcher | Start an interactive analysis session through the workbench daemon. | W5.6 |
| Encoding + Export panels | Import a vendor format → encode to `.tio` → export back to mzML / nmrML / JCAMP-DX / BAM / CRAM. Progress bar during open + export (W6 follow-up). | W5.7 |

The Workbench Client SDK underneath the GUI is also exposed as a
Python `ttio` CLI / SDK (`python/src/ttio/workbench/`) and a Java SDK
(`java/.../workbench/`) — the GUI is a thin shell over the same
client APIs.

## Quick install (end users)

Download the JAR for your operating system from the [latest GitHub Release](https://github.com/DTW-Thalion/TTI-O/releases/latest):

| OS | Download |
|---|---|
| Linux x86_64 | `tio-browser-<ver>-linux-x64.jar` |
| macOS Apple Silicon (arm64) | `tio-browser-<ver>-mac-aarch64.jar` |
| Windows x86_64 | `tio-browser-<ver>-win-x64.jar` |

Run with a JDK 22+:

```bash
java -jar tio-browser-<ver>-<your-os>.jar
java -jar tio-browser-<ver>-<your-os>.jar --open path/to/dataset.tio
```

Each per-platform JAR bundles HDF5 1.14.6, the LZ4 filter plugin, and `libttio_rans_jni` for that platform — **no other prerequisites beyond a JDK 22+**.

If you download the wrong JAR for your OS, the app shows a modal error pointing you to the correct asset.

## Build from source

### Prerequisites

- JDK 22+
- Maven 3.9+
- libhdf5-java (provides `/usr/share/java/jarhdf5.jar`)
  - Ubuntu 24.04+: `apt install libhdf5-java libhdf5-jni libhdf5-dev`
  - Ubuntu 22.04: `apt install libhdf5-dev libhdf5-jni libjarhdf5-java`
- For the genomic Read Inspector: `cmake`, `gcc`/`clang`, `zlib`
  development headers, and `pthread` (already present on Linux/macOS;
  Windows uses MinGW-w64 UCRT64 via MSYS2).

### Build the `ttio` library, then `tio-browser`

```bash
# Step 1: install ttio:1.x to local M2
cd java
mvn -B install -DskipTests -Djacoco.skip=true \
    -Dhdf5.jar=/usr/share/java/jarhdf5.jar

# Step 2: build the tio-browser shaded jar (no genomic native — the
# JNI library will be picked up if you previously built it under
# native/_build, otherwise the genomic Read Inspector falls back).
cd ../tio-browser
mvn -B package -Dhdf5.jar=/usr/share/java/jarhdf5.jar
java -jar target/tio-browser-*-shaded.jar
```

### Build the optional native library locally

```bash
cd native
cmake -B _build -DCMAKE_BUILD_TYPE=Release -DTTIO_RANS_BUILD_JNI=ON
cmake --build _build --target ttio_rans_jni
# Then either symlink into resources, or pass via java.library.path:
java -Djava.library.path=$(pwd)/_build \
     -jar ../tio-browser/target/tio-browser-*-shaded.jar
```

## Releasing (cross-platform shaded jar)

The
[`release-shaded-jar.yml`](../.github/workflows/release-shaded-jar.yml)
GitHub Actions workflow builds `libttio_rans_jni` on three platforms
(`ubuntu-22.04`, `macos-14`, `windows-2022`) using a matrix job, then
stages all three into `tio-browser/src/main/resources/native/{linux-x64,mac-aarch64,win-x64}/...`
and produces the cross-platform shaded jar.

### Trigger paths

- **Tag push**: `git tag vX.Y.Z && git push --tags` — workflow runs
  and uploads the shaded jar to a GitHub Release.
- **Manual smoke-test**: `gh workflow run release-shaded-jar.yml`
  (or via the Actions UI) — produces the shaded jar as a workflow
  artifact without cutting a release.

### Why arm64-only on macOS

The bundled macOS native is currently **arm64-only**:

- **Universal2** (x86_64 + arm64): blocked because `native/src/`
  SIMD `.c` files use `<immintrin.h>` x86 intrinsics directly without
  arm64 self-guards, so the arm64 slice fails to link with
  `Undefined symbols for architecture x86_64: __ttio_rans_decode_block_avx2`.
- **Intel-only on `macos-13`**: blocked by GHA Intel macOS runner
  capacity (60+ minute queue waits during peak).
- **arm64-only on `macos-14`**: ships clean. Intel Mac users hit
  graceful degradation (Read Inspector placeholder); all other
  features work.

Universal2 support is a future follow-up gated on the SIMD `.c`
files self-guarding for arm64.

### Why MinGW-w64 on Windows

The C codebase under `native/src/` is fundamentally POSIX (uses
`pthread.h` directly in `fqzcomp_qual.c`, `threadpool.c`, and
`wire_format.c`). MSVC needs a separate pthread shim (e.g.,
`pthreads4w` via vcpkg) which is a future effort. **MinGW-w64 UCRT64
via MSYS2** (`msys2/setup-msys2@v2`) provides POSIX threads natively
and the existing GCC-style warning + SIMD compile flags work
unchanged.

## Native installers (optional)

For users who prefer a platform-native installer instead of the JAR:

| OS | Asset |
|---|---|
| Linux | `tio-browser_<ver>_amd64.deb` |
| macOS | `tio-browser-<ver>-mac-aarch64.dmg` (arm64) |
| Windows | `tio-browser-<ver>-win-x64.msi` |

Each installer bundles the platform's HDF5 + JRE — completely self-contained.

To build locally:

```bash
mvn -pl tio-browser package -P <your-platform> -P native-package
```

Where `<your-platform>` is one of `linux-x64`, `mac-aarch64`, `win-x64`.

## Diagnostics

Tools → Diagnostics opens a modal dialog showing the live status of
every external dependency the library can use:

- HDF5 JNI (in-process probe via `H5.H5get_libversion`)
- `samtools` on PATH (required for BAM/SAM/CRAM import/export)
- `ThermoRawFileParser` on PATH (for Thermo `.raw` import; honors the
  `THERMORAWFILEPARSER` env var if set)
- `masslynxraw` on PATH (for Waters `.RAW` import; honors
  `MASSLYNXRAW` env var)
- `python3` (or `python` on Windows) with `opentimspy` importable
  (for Bruker timsTOF `.d` import)

Greyed-out format rows in Import / Export tell you which binary is
missing. The **Re-probe** button picks up newly-installed binaries
without restarting the app.

## Known limitations

- No multi-document tabs — one open `.tio` at a time.
- No alignment-coverage track visualization (per-read inspector
  only).
- No telemetry, auto-update, or crash reporter.
- macOS app bundles produced by `jpackage` are unsigned — users may
  need right-click → Open on first launch.
- Workbench client requires bootstrap-admin TOTP for login; SSO
  / OIDC is server-side scope, not exposed in the GUI yet.

## License

LGPL-3.0-or-later. See [`../LICENSE`](../LICENSE).
