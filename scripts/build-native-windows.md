# Building HDF5 + LZ4 plugin on Windows (MSYS2 UCRT64)

The Windows build job in `release-shaded-jar.yml` uses MSYS2 UCRT64 to
provide a POSIX-style toolchain for the libttio_rans + HDF5 + LZ4 plugin
builds. The native artifacts ship as `.dll` files alongside `tio-browser`.

## Required pacman packages

```
mingw-w64-ucrt-x86_64-hdf5
mingw-w64-ucrt-x86_64-hdf5-tools
mingw-w64-ucrt-x86_64-cmake
mingw-w64-ucrt-x86_64-ninja
mingw-w64-ucrt-x86_64-clang
mingw-w64-ucrt-x86_64-git
```

Install with (in CI step using `msys2/setup-msys2@v2`):

```yaml
- uses: msys2/setup-msys2@v2
  with:
    msystem: UCRT64
    install: >-
      mingw-w64-ucrt-x86_64-hdf5
      mingw-w64-ucrt-x86_64-hdf5-tools
      mingw-w64-ucrt-x86_64-cmake
      mingw-w64-ucrt-x86_64-ninja
      mingw-w64-ucrt-x86_64-clang
      mingw-w64-ucrt-x86_64-git
```

## File layout after install

HDF5 lives under `/ucrt64`:

| File | Purpose |
|---|---|
| `/ucrt64/bin/libhdf5.dll` | HDF5 core C library (rename to `hdf5.dll` for jpackage convention) |
| `/ucrt64/bin/libhdf5_hl.dll` | HDF5 high-level API (rename to `hdf5_hl.dll`) |
| `/ucrt64/lib/libhdf5.dll.a` | Import library for linking |
| `/ucrt64/include/hdf5.h` | Headers |

The JNI shim `hdf5_java.dll` is **NOT** in the MSYS2 package. Build from
source against the installed HDF5 using HDFGroup's `tools-make` tarball,
or compile the JHI5 native source directly.

## LZ4 plugin

Build the LZ4 filter plugin against the MSYS2 HDF5 via:

```
PREFIX=/ucrt64 bash scripts/build-h5lz4.sh master
```

The plugin lands at `/ucrt64/lib/libh5lz4.dll` (or `/ucrt64/bin/`
depending on cmake install convention). Stage it as `h5lz4.dll`
under `tio-browser/src/main/resources/native/win-x64/hdf5/` for the
`Hdf5NativeLoader` to pick up at runtime.

## CI step skeleton

The full per-platform build is in `.github/workflows/release-shaded-jar.yml`'s
matrix — see the `win-x64` matrix entry for the pacman install + LZ4
plugin build + native-staging recipe.
