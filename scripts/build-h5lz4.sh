#!/usr/bin/env bash
# Build the HDF5 LZ4 filter plugin (HDF5 filter id 32004) against an
# already-installed HDF5. Intended to run on Linux x64, macOS arm64,
# and Windows MSYS2 UCRT64. Output: libh5lz4.{so,dylib,dll} in
# ${PREFIX}/lib (Linux/macOS) or ${PREFIX}/bin (MSYS2 Windows).
#
# Usage: scripts/build-h5lz4.sh [version]
#   version: hdf5_plugins git tag or branch (default: master)
#
# Required env vars (defaults shown):
#   PREFIX=/usr/local      — install prefix; override on macOS or MSYS2
#   WORK=/tmp/h5lz4-build  — scratch dir
#
# Source: https://github.com/HDFGroup/hdf5_plugins
set -euo pipefail

VERSION="${1:-master}"
WORK="${WORK:-/tmp/h5lz4-build}"
PREFIX="${PREFIX:-/usr/local}"

echo "build-h5lz4: VERSION=${VERSION}, WORK=${WORK}, PREFIX=${PREFIX}"

rm -rf "$WORK"
git clone --depth 1 --branch "$VERSION" \
    https://github.com/HDFGroup/hdf5_plugins.git "$WORK"

# Upstream master's CMakeLists guards the LZ4 plugin with
# `if (NOT MINGW)` and the inner WIN32 branch only enables LZ4 for
# MSVC >= 19.30 (Visual Studio 2022). Every MinGW + clang/gcc path
# hits `set (ENABLE_LZ4 OFF CACHE BOOL "" FORCE)`, which overrides
# our `-DENABLE_LZ4=ON` flag silently. Linux + macOS take the
# non-WIN32 branch (`FILTER_OPTION (LZ4)`) and build fine.
#
# Patch the FORCE-OFF lines to FILTER_OPTION(LZ4) so MSYS2 UCRT64
# with system lz4 (mingw-w64-ucrt-x86_64-lz4) builds the plugin.
# The H5Zlz4.c source compiles cleanly under MinGW; the guard was
# upstream caution, not a real incompatibility.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        echo "build-h5lz4: patching upstream CMakeLists to allow MinGW LZ4 build"
        sed -i 's|set (ENABLE_LZ4 OFF CACHE BOOL "" FORCE)|FILTER_OPTION (LZ4)|g' \
            "$WORK/CMakeLists.txt"
        grep -n 'ENABLE_LZ4\|FILTER_OPTION (LZ4)' "$WORK/CMakeLists.txt" | head -5
        ;;
esac

cmake -B "$WORK/_build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DBUILD_TESTING=OFF \
    -DH5PL_ALLOW_EXTERNAL_SUPPORT=TGZ \
    -DENABLE_LZ4=ON \
    -DENABLE_BSHUF=OFF \
    -DENABLE_BLOSC=OFF \
    -DENABLE_BLOSC2=OFF \
    -DENABLE_BZIP2=OFF \
    -DENABLE_JPEG=OFF \
    -DENABLE_LZF=OFF \
    -DENABLE_MAFISC=OFF \
    -DENABLE_SZF=OFF \
    -DENABLE_ZFP=OFF \
    -DENABLE_ZSTD=OFF \
    "$WORK"

cmake --build "$WORK/_build" --parallel

# Use sudo on Linux/macOS where /usr/local needs root; skip in MSYS2
if [ -w "$PREFIX" ]; then
    cmake --install "$WORK/_build"
else
    sudo cmake --install "$WORK/_build"
fi

echo "build-h5lz4: installed plugin to $PREFIX"
ls -la "$PREFIX/lib/libh5lz4"* 2>/dev/null || \
    ls -la "$PREFIX/bin/h5lz4"* 2>/dev/null || \
    find "$PREFIX" -name "*h5lz4*" -type f 2>/dev/null | head -10
