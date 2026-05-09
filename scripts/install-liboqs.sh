#!/usr/bin/env bash
# scripts/install-liboqs.sh — Build and install liboqs from source.
#
# Usage: ./scripts/install-liboqs.sh [VERSION]
#
# Defaults:
#   VERSION  0.10.1
#   PREFIX   /usr/local  (override via OQS_PREFIX env var)
#
# Installs:
#   $PREFIX/lib/liboqs.so            shared library
#   $PREFIX/include/oqs/oqs.h        C headers
#
# Required by:
#   - Python `liboqs-python>=0.14` (PQC tests)
#   - ObjC TTIO_PQC* APIs (when `liboqs` headers present at compile time)
#
# Idempotent: exits 0 immediately if the right version is already installed.
#
# Build dependencies: cmake (>=3.16), gcc/clang, make/ninja, openssl-dev.
#
# Notes:
#   - Ubuntu 24.04 has no apt package for liboqs; this script source-builds.
#   - liboqs-python's auto-build to ~/_oqs is unreliable in CI environments,
#     so we install system-wide instead.

set -euo pipefail

VERSION="${1:-0.10.1}"
PREFIX="${OQS_PREFIX:-/usr/local}"

# ---------------------------------------------------------------------------
# Idempotency check
# ---------------------------------------------------------------------------
if [ -f "${PREFIX}/lib/liboqs.so" ] && [ -f "${PREFIX}/include/oqs/oqs.h" ]; then
    echo "liboqs already installed at ${PREFIX} — skipping build."
    echo "  $(ls -la ${PREFIX}/lib/liboqs.so 2>/dev/null | awk '{print $5, $9}')"
    exit 0
fi

# ---------------------------------------------------------------------------
# Build dependencies
# ---------------------------------------------------------------------------
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    ninja-build \
    libssl-dev

# ---------------------------------------------------------------------------
# Download + extract
# ---------------------------------------------------------------------------
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

URL="https://github.com/open-quantum-safe/liboqs/archive/refs/tags/${VERSION}.tar.gz"
echo "Downloading liboqs ${VERSION} from ${URL} ..."
curl -fsSL "${URL}" -o "${WORK}/liboqs.tar.gz"
tar -xf "${WORK}/liboqs.tar.gz" -C "${WORK}"
cd "${WORK}/liboqs-${VERSION}"

# ---------------------------------------------------------------------------
# Configure + build
# ---------------------------------------------------------------------------
echo "Configuring liboqs ${VERSION} (prefix=${PREFIX}) ..."
cmake -B build -G Ninja \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DOQS_BUILD_ONLY_LIB=ON \
    -DOQS_DIST_BUILD=ON

echo "Building liboqs ($(nproc) parallel jobs) ..."
cmake --build build --parallel "$(nproc)"

echo "Installing liboqs to ${PREFIX} ..."
sudo cmake --install build
sudo ldconfig

# Verify
if [ ! -f "${PREFIX}/lib/liboqs.so" ]; then
    echo "liboqs: build completed but ${PREFIX}/lib/liboqs.so not produced — investigate." >&2
    exit 3
fi

echo "Installed liboqs ${VERSION} to ${PREFIX}."
echo "  Library:  ${PREFIX}/lib/liboqs.so"
echo "  Headers:  ${PREFIX}/include/oqs/oqs.h"
