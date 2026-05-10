#!/usr/bin/env bash
# scripts/install-hdf5.sh -- Build and install HDF5 from source.
#
# Usage:  ./scripts/install-hdf5.sh [VERSION]
#
# Defaults:
#   VERSION  1.14.6
#   PREFIX   /usr/local  (override via HDF5_PREFIX env var)
#
# Installs:
#   $PREFIX/lib/libhdf5.so           C library (thread-safe)
#   $PREFIX/lib/libhdf5_java.so      JNI binding
#   $PREFIX/lib/jarhdf5.jar          Java wrapper jar
#   $PREFIX/include/hdf5.h           C headers
#
# Build configuration:
#   --enable-threadsafe   required (concurrent file-handle safety)
#   --enable-java         required (jhdf5.jar + libhdf5_java.so)
#   --enable-unsupported  required (HDF Group's own constraint: threadsafe is
#                                   marked "unsupported" with java; this flag
#                                   acknowledges that it works in practice)
#   --enable-cxx          DROPPED (TTI-O ObjC uses pure C HDF5; libhdf5_cpp not
#                                  needed; cxx is incompatible with threadsafe)
#   --with-ros3-vfd       enables S3 cloud-native .tio access
#
# Idempotent: exits 0 immediately if the right version + threadsafe is installed.

set -euo pipefail

VERSION="${1:-1.14.6}"
PREFIX="${HDF5_PREFIX:-/usr/local}"

# ---------------------------------------------------------------------------
# Portability helpers (Linux + macOS + MSYS2 UCRT64)
# ---------------------------------------------------------------------------
UNAME_S="$(uname -s)"
case "${UNAME_S}" in
    Linux*)     OS=linux ;;
    Darwin*)    OS=macos ;;
    MINGW*|MSYS*|CYGWIN*) OS=windows ;;
    *)          OS=unknown ;;
esac

# Use sudo only when the prefix is not writable (skip on MSYS2/MINGW where
# /ucrt64 is user-owned, and skip when running as root in CI).
if [ -w "${PREFIX}" ] || [ ! -e "${PREFIX}" ] && [ -w "$(dirname "${PREFIX}")" ]; then
    SUDO=""
else
    SUDO="sudo"
fi
# MSYS2 has no sudo; force empty there.
if [ "${OS}" = "windows" ]; then
    SUDO=""
fi

# Portable parallel-jobs count.
nproc_portable() {
    if command -v nproc >/dev/null 2>&1; then
        nproc
    elif [ "${OS}" = "macos" ]; then
        sysctl -n hw.logicalcpu
    else
        echo 2
    fi
}

# ---------------------------------------------------------------------------
# Idempotency check
# ---------------------------------------------------------------------------
SETTINGS="${PREFIX}/lib/libhdf5.settings"
if [ -f "${SETTINGS}" ]; then
    INSTALLED=$(grep -oP 'HDF5 Version:\s+\K[\d.]+' "${SETTINGS}" 2>/dev/null || true)
    THREADSAFE=$(grep -oP 'Threadsafety:\s+\K\w+' "${SETTINGS}" 2>/dev/null || true)
    if [ "${INSTALLED}" = "${VERSION}" ] && [ "${THREADSAFE}" = "yes" ]; then
        echo "HDF5 ${VERSION} (thread-safe) already installed at ${PREFIX} -- skipping build."
        exit 0
    fi
    echo "Found HDF5 ${INSTALLED} (threadsafe=${THREADSAFE:-?}) at ${PREFIX}; replacing with ${VERSION} (thread-safe)."
fi

# ---------------------------------------------------------------------------
# Build dependencies
# ---------------------------------------------------------------------------
case "${OS}" in
    linux)
        if command -v apt-get >/dev/null 2>&1; then
            ${SUDO} apt-get update -qq
            ${SUDO} apt-get install -y --no-install-recommends \
                build-essential \
                cmake \
                zlib1g-dev \
                libcurl4-openssl-dev \
                default-jdk
        else
            echo "install-hdf5: non-apt Linux detected; assuming build deps (gcc/make/cmake/zlib/curl/jdk) are present."
        fi
        ;;
    macos)
        echo "install-hdf5: macOS detected; assuming Xcode CLT + brew-installed cmake, zlib, curl, openjdk are present."
        # On macOS, callers are expected to: brew install cmake openjdk zlib
        ;;
    windows)
        echo "install-hdf5: MSYS2/MINGW detected; assuming pacman packages (mingw-w64-ucrt-x86_64-{gcc,cmake,curl,zlib,jdk-openjdk}) are present."
        ;;
    *)
        echo "install-hdf5: unknown OS (${UNAME_S}); skipping dep install, build may fail."
        ;;
esac

# ---------------------------------------------------------------------------
# Download + extract
# ---------------------------------------------------------------------------
# URL pattern confirmed: v1_14/v1_14_6/downloads/hdf5-1.14.6.tar.gz
# Verified 200 OK at: https://support.hdfgroup.org/releases/hdf5/
VERSION_MAJOR_MINOR="${VERSION%.*}"
VERSION_DOTTED="${VERSION}"
VERSION_DASHED="${VERSION//./_}"
MAJOR_MINOR_DASHED="${VERSION_MAJOR_MINOR//./_}"

URL="https://support.hdfgroup.org/releases/hdf5/v${MAJOR_MINOR_DASHED}/v${VERSION_DASHED}/downloads/hdf5-${VERSION_DOTTED}.tar.gz"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

echo "Downloading HDF5 ${VERSION} from ${URL} ..."
curl -fsSL "${URL}" -o "${WORK}/hdf5.tar.gz"
tar -xf "${WORK}/hdf5.tar.gz" -C "${WORK}"
cd "${WORK}/hdf5-${VERSION_DOTTED}"

# ---------------------------------------------------------------------------
# Configure + build
# ---------------------------------------------------------------------------
echo "Configuring HDF5 ${VERSION} (prefix=${PREFIX}, --enable-java --enable-threadsafe --enable-hl) ..."
# --enable-threadsafe + --enable-java + --enable-hl is marked "unsupported" by
# HDF Group but works in practice. --enable-unsupported is required to override
# the configure guard. --enable-cxx is dropped because libhdf5_cpp is
# incompatible with --enable-threadsafe and TTI-O does not use the C++ bindings.
# HL (high-level) is required for hdf5_hl.h / H5DSset_scale used by the ObjC
# NMR2D spectrum implementation (objc/Source/Spectra/TTIONMR2DSpectrum.m).
./configure \
    --prefix="${PREFIX}" \
    --enable-java \
    --enable-threadsafe \
    --enable-unsupported \
    --enable-shared \
    --disable-static \
    --disable-tests \
    --disable-tools \
    --enable-hl \
    --with-ros3-vfd

JOBS="$(nproc_portable)"
echo "Building HDF5 (${JOBS} parallel jobs) ..."
make -j"${JOBS}"

echo "Installing HDF5 to ${PREFIX} ..."
${SUDO} make install
# Create an unversioned jarhdf5.jar symlink for consistent path across versions
if [ -f "${PREFIX}/lib/jarhdf5-${VERSION_DOTTED}.jar" ]; then
    ${SUDO} ln -sf "${PREFIX}/lib/jarhdf5-${VERSION_DOTTED}.jar" "${PREFIX}/lib/jarhdf5.jar"
fi
# ldconfig is Linux-only (glibc dynamic linker cache refresh).
if [ "${OS}" = "linux" ] && command -v ldconfig >/dev/null 2>&1; then
    ${SUDO} ldconfig
fi

echo "Installed HDF5 ${VERSION} to ${PREFIX}."

# Verification
if [ -f "${SETTINGS}" ]; then
    INSTALLED=$(grep -oP 'HDF5 Version:\s+\K[\d.]+' "${SETTINGS}" 2>/dev/null || true)
    echo "Verification: installed HDF5 version = ${INSTALLED}"
fi

# Report key artefact locations (extension differs per OS).
case "${OS}" in
    linux)   LIBEXT=so ;;
    macos)   LIBEXT=dylib ;;
    windows) LIBEXT=dll ;;
    *)       LIBEXT=so ;;
esac
echo "  C library:    ${PREFIX}/lib/libhdf5.${LIBEXT}"
echo "  JNI library:  ${PREFIX}/lib/libhdf5_java.${LIBEXT}"
echo "  Java jar:     ${PREFIX}/lib/jarhdf5.jar"