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
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    zlib1g-dev \
    libcurl4-openssl-dev \
    default-jdk

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
echo "Configuring HDF5 ${VERSION} (prefix=${PREFIX}, --enable-java --enable-threadsafe) ..."
# --enable-threadsafe + --enable-java is marked "unsupported" by HDF Group but
# works in practice. --enable-unsupported is required to override the configure
# guard. --enable-cxx is dropped because libhdf5_cpp is incompatible with
# --enable-threadsafe and TTI-O does not use the C++ bindings.
./configure \
    --prefix="${PREFIX}" \
    --enable-java \
    --enable-threadsafe \
    --enable-unsupported \
    --enable-shared \
    --disable-static \
    --disable-tests \
    --disable-tools \
    --disable-hl \
    --with-ros3-vfd

echo "Building HDF5 ($(nproc) parallel jobs) ..."
make -j"$(nproc)"

echo "Installing HDF5 to ${PREFIX} ..."
sudo make install
# Create an unversioned jarhdf5.jar symlink for consistent path across versions
if [ -f "${PREFIX}/lib/jarhdf5-${VERSION_DOTTED}.jar" ]; then
    sudo ln -sf "${PREFIX}/lib/jarhdf5-${VERSION_DOTTED}.jar" "${PREFIX}/lib/jarhdf5.jar"
fi
sudo ldconfig

echo "Installed HDF5 ${VERSION} to ${PREFIX}."

# Verification
if [ -f "${SETTINGS}" ]; then
    INSTALLED=$(grep -oP 'HDF5 Version:\s+\K[\d.]+' "${SETTINGS}" 2>/dev/null || true)
    echo "Verification: installed HDF5 version = ${INSTALLED}"
fi

# Report key artefact locations
echo "  C library:    ${PREFIX}/lib/libhdf5.so"
echo "  JNI library:  ${PREFIX}/lib/libhdf5_java.so"
echo "  Java jar:     ${PREFIX}/lib/jarhdf5.jar"