# Building HDF5 + LZ4 plugin on Windows (MSYS2 UCRT64)

The Windows build job in `release-shaded-jar.yml` uses MSYS2 UCRT64 to
provide a POSIX-style toolchain for the libttio_rans + HDF5 + LZ4 plugin
builds. The native artifacts ship as `.dll` files alongside `tio-browser`.

## HDF5 is built from source (not pacman)

MSYS2's `mingw-w64-ucrt-x86_64-hdf5` package **omits the JNI shim**
`libhdf5_java.dll`, which `Hdf5NativeLoader` needs at launch. So we use
`scripts/install-hdf5.sh` — the same script Linux + macOS already use —
which passes `--enable-java` to HDF5's configure and produces both
`jarhdf5.jar` AND `libhdf5_java.dll` as part of the source build.

## Required pacman packages

Just the build toolchain — HDF5 itself is built from source:

```
mingw-w64-ucrt-x86_64-cmake
mingw-w64-ucrt-x86_64-ninja
mingw-w64-ucrt-x86_64-clang
mingw-w64-ucrt-x86_64-gcc
mingw-w64-ucrt-x86_64-git
mingw-w64-ucrt-x86_64-zlib
mingw-w64-ucrt-x86_64-curl
mingw-w64-ucrt-x86_64-make
autoconf
automake
libtool
make
```

Install in CI via `msys2/setup-msys2@v2`:

```yaml
- uses: msys2/setup-msys2@v2
  with:
    msystem: UCRT64
    install: >-
      mingw-w64-ucrt-x86_64-cmake
      mingw-w64-ucrt-x86_64-ninja
      mingw-w64-ucrt-x86_64-clang
      mingw-w64-ucrt-x86_64-gcc
      mingw-w64-ucrt-x86_64-git
      mingw-w64-ucrt-x86_64-zlib
      mingw-w64-ucrt-x86_64-curl
      mingw-w64-ucrt-x86_64-make
      autoconf
      automake
      libtool
      make
```

A JDK is also required for the `--enable-java` JNI-shim compilation.
In CI, `actions/setup-java@v4` provides one and exports `JAVA_HOME`
in Windows path form (`C:\hostedtoolcache\...`). The MSYS2 shell
needs the POSIX-form translation:

```bash
export JAVA_HOME="$(cygpath -u "$JAVA_HOME")"
```

`cygpath -u` rewrites `C:\hostedtoolcache\windows\Java_Temurin-Hotspot_jdk\21.x\x64`
to `/c/hostedtoolcache/windows/Java_Temurin-Hotspot_jdk/21.x/x64`, which
HDF5's autoconf-driven `--enable-java` probe can resolve.

## Building HDF5 + JNI shim

```bash
HDF5_PREFIX=/ucrt64 bash scripts/install-hdf5.sh 1.14.6
```

Override `HDF5_PREFIX` so HDF5 lands in `/ucrt64` alongside MSYS2's
other libs (the script's default `/usr/local` is not on the UCRT64
search path).

## File layout after build

HDF5 from-source build (libtool) emits DLLs under `${PREFIX}/bin/`,
import libraries under `${PREFIX}/lib/`:

| File | Purpose |
|---|---|
| `/ucrt64/bin/libhdf5.dll` | HDF5 core C library (rename to `hdf5.dll`) |
| `/ucrt64/bin/libhdf5_hl.dll` | HDF5 high-level API (rename to `hdf5_hl.dll`) |
| `/ucrt64/bin/libhdf5_java.dll` | JNI shim (rename to `hdf5_java.dll`) — produced by `--enable-java` |
| `/ucrt64/lib/libhdf5.dll.a` | Import library for linking |
| `/ucrt64/lib/jarhdf5.jar` | Java HDF5 wrapper jar |
| `/ucrt64/include/hdf5.h` | Headers |

The "lib" prefix is dropped at staging time to match
`Hdf5NativeLoader`'s `WIN_LIBS` table (Java's `System.load(...)` on
Windows expects bare `hdf5.dll`, not `libhdf5.dll`).

## LZ4 plugin

Build the LZ4 filter plugin against the from-source HDF5:

```
PREFIX=/ucrt64 bash scripts/build-h5lz4.sh master
```

The plugin lands at `/ucrt64/lib/libh5lz4.dll` (or `/ucrt64/bin/`
depending on cmake install convention). Stage it as `h5lz4.dll`
under `tio-browser/src/main/resources/native/win-x64/hdf5/` for the
`Hdf5NativeLoader` to pick up at runtime.

## CI step skeleton

The full per-platform build is in `.github/workflows/release-shaded-jar.yml`'s
matrix — see the `win-x64` matrix entry for the toolchain install +
HDF5-from-source + LZ4 plugin build + native-staging recipe.
