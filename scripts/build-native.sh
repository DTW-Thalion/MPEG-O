#!/usr/bin/env bash
# scripts/build-native.sh — Build native/_build/libttio_rans.so from source.
#
# Usage: ./scripts/build-native.sh [--force]
#
# The native library lives at native/_build/libttio_rans.so. ObjC
# (libTTIO.so) and the JNI bridge (libttio_rans_jni.so used by
# tio-browser) both need it for genomic codec support
# (NAME_TOKENIZED_V2, REF_DIFF_V2, FQZCOMP_NX16). Without it, ObjC
# builds compile cleanly but skip the codec dispatch — and any test
# that writes a genomic run with read_names raises
# NSInternalInconsistencyException at runtime.
#
# Idempotent: if native/_build/libttio_rans.so exists and is newer
# than every .c in native/src/, the script is a no-op (override with
# --force).
#
# Build dependencies: cmake, gcc/clang, zlib1g-dev, pthreads.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE_DIR="${REPO_ROOT}/native"
BUILD_DIR="${NATIVE_DIR}/_build"
LIB_PATH="${BUILD_DIR}/libttio_rans.so"

force=false
for arg in "$@"; do
    case "$arg" in
        --force) force=true ;;
        --help|-h)
            echo "Usage: $0 [--force]"
            echo "Builds native/_build/libttio_rans.so via cmake."
            exit 0
            ;;
        *)
            echo "Unknown arg: $arg" >&2
            exit 2
            ;;
    esac
done

# ------------------------------------------------------------
# Idempotency check: skip if lib is newer than every source file.
# ------------------------------------------------------------
if [ "$force" = false ] && [ -f "$LIB_PATH" ]; then
    newest_src=$(find "${NATIVE_DIR}/src" "${NATIVE_DIR}/include" "${NATIVE_DIR}/CMakeLists.txt" \
                      -type f -newer "$LIB_PATH" 2>/dev/null | head -1 || true)
    if [ -z "$newest_src" ]; then
        echo "native: $LIB_PATH up-to-date — skipping build (use --force to override)."
        exit 0
    fi
    echo "native: source newer than lib ($newest_src); rebuilding."
fi

# ------------------------------------------------------------
# Configure + build via cmake
# ------------------------------------------------------------
cd "$NATIVE_DIR"
# Prefer Ninja for fresh configure; reuse existing generator if cache present.
generator_args=()
if [ ! -f "_build/CMakeCache.txt" ] && command -v ninja >/dev/null 2>&1; then
    generator_args+=("-G" "Ninja")
fi
echo "native: configuring (cmake -B _build${generator_args[*]:+ -G Ninja}) ..."
cmake -B _build "${generator_args[@]}" -DCMAKE_BUILD_TYPE=Release > /dev/null

echo "native: building ($(nproc) parallel jobs) ..."
cmake --build _build --parallel "$(nproc)" --target ttio_rans

if [ ! -f "$LIB_PATH" ]; then
    echo "native: build completed but $LIB_PATH not produced — investigate." >&2
    exit 3
fi

echo "native: built $LIB_PATH ($(stat -c %s "$LIB_PATH") bytes)."
