# tio-browser

JavaFX desktop application for inspecting, importing, exporting, and
transporting TTI-O `.tio` multi-omics datasets. Built on the
[`global.thalion:ttio`](../java) Java library.

## Quick install (end users)

Download the cross-platform shaded jar from the latest GitHub Release:

```bash
java -jar tio-browser-<version>-shaded.jar
```

The shaded jar bundles the JavaFX runtime, the `ttio` Java library,
and the `libttio_rans` native library for **Linux x86_64**, **macOS
Apple Silicon (arm64)**, and **Windows x86_64**. No additional
toolchain is required beyond a JDK 17+ runtime.

### Platform support matrix

| Platform | Support | Native library |
|---|---|---|
| Linux x86_64 (glibc ≥ 2.35, Ubuntu 22.04+) | Full | bundled (`native/linux-x64/libttio_rans_jni.so`) |
| macOS Apple Silicon (arm64, macOS 13+) | Full | bundled (`native/mac-aarch64/libttio_rans_jni.dylib`) |
| Windows x86_64 (Windows 10+) | Full | bundled (`native/win-x64/ttio_rans_jni.dll`, MinGW UCRT64) |
| macOS Intel (x86_64) | Graceful degradation | not bundled — non-genomic workflows work; Read Inspector falls back to a placeholder |
| Other (linux-aarch64, win-aarch64) | Graceful degradation | not bundled — same fallback as Intel Mac |

On Intel Mac and other unbundled platforms, the application starts
normally and all non-genomic features (MS, NMR, Raman/IR/UV-Vis, plot
tabs, headers tables, dataset tree, encryption, identifications,
quantifications) work without the native library. Only the genomic
**Read Inspector** tab — which decodes `NameTokenizerV2` /
`RefDiffV2` codecs through JNI — surfaces a placeholder message.

### Native-lib resolution order

`NativeLibraryLoader` resolves `libttio_rans_jni` at first call (when
the genomic Read Inspector mounts) using this fallback chain:

1. `System.loadLibrary("ttio_rans_jni")` — picks up a system-installed
   library via `java.library.path` (developer mode; set
   `-Djava.library.path=/path/to/native_build`).
2. Resource extraction from `/native/<platform>/...` bundled in the
   shaded jar — copied to a temp file and loaded via
   `System.load(...)` (end-user fat-jar mode).
3. Records `NativeLibraryLoader.lastError()`; the genomic UI surfaces
   this as a placeholder. The rest of the app keeps working.

The loader is idempotent — repeated calls are no-ops once
`isLoaded()` returns true or `lastError()` is set.

## Build from source

### Prerequisites

- JDK 17+
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

## License

LGPL-3.0-or-later. See [`../LICENSE`](../LICENSE).
