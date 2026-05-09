#!/usr/bin/env bash
# scripts/build-native.sh -- Build native/_build/libttio_rans.so from source.
#
# Usage: ./scripts/build-native.sh [--jni] [--force]
#
# The native library lives at native/_build/libttio_rans.so. ObjC
# (libTTIO.so) and the JNI bridge (libttio_rans_jni.so used by
# tio-browser) both need it for genomic codec support
# (NAME_TOKENIZED_V2, REF_DIFF_V2, FQZCOMP_NX16). Without it, ObjC
# builds compile cleanly but skip the codec dispatch -- and any test
# that writes a genomic run with read_names raises
# NSInternalInconsistencyException at runtime.
#
# Flags:
#   --jni    Also build libttio_rans_jni.so (adds -DTTIO_RANS_BUILD_JNI=ON).
#            Required by Python integration tests and the Java JNI matrix
#            that load the JNI wrapper via java.library.path.  Produces
#            both libttio_rans.so and libttio_rans_jni.so in native/_build/.
#   --force  Bypass idempotency check and always rebuild.
#
# Idempotent: if the expected library (or libraries, when --jni is passed)
# already exists and is newer than every .c in native/src/, the script is a
# no-op (override with --force).
#
# Build dependencies: cmake, gcc/clang, zlib1g-dev, pthreads.
# JNI additionally requires a JDK with jni.h (set JAVA_HOME if needed).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE_DIR="${REPO_ROOT}/native"
BUILD_DIR="${NATIVE_DIR}/_build"
LIB_PATH="${BUILD_DIR}/libttio_rans.so"
JNI_LIB_PATH="${BUILD_DIR}/libttio_rans_jni.so"

force=false
jni=false
for arg in "$@"; do
    case "$arg" in
        --force) force=true ;;
        --jni)   jni=true ;;
        --help|-h)
            echo "Usage: $0 [--jni] [--force]"
            echo "Builds native/_build/libttio_rans.so (and optionally libttio_rans_jni.so) via cmake."
            exit 0
            ;;
        *)
            echo "Unknown arg: $arg" >&2
            exit 2
            ;;
    esac
done

# ------------------------------------------------------------
# Idempotency check: skip if all expected libs are newer than every source file.
# ------------------------------------------------------------
if [ "$force" = false ] && [ -f "$LIB_PATH" ]; then
    # In JNI mode both libraries must exist and be up-to-date.
    jni_ok=true
    if [ "$jni" = true ] && [ ! -f "$JNI_LIB_PATH" ]; then
        jni_ok=false
    fi

    if [ "$jni_ok" = true ]; then
        newest_src=$(find "${NATIVE_DIR}/src" "${NATIVE_DIR}/include" "${NATIVE_DIR}/CMakeLists.txt" \
                          -type f -newer "$LIB_PATH" 2>/dev/null | head -1 || true)
        if [ -z "$newest_src" ]; then
            if [ "$jni" = true ]; then
                echo "native: $LIB_PATH and $JNI_LIB_PATH up-to-date -- skipping build (use --force to override)."
            else
                echo "native: $LIB_PATH up-to-date -- skipping build (use --force to override)."
            fi
            exit 0
        fi
        echo "native: source newer than lib ($newest_src); rebuilding."
    else
        echo "native: $JNI_LIB_PATH missing; building JNI variant."
    fi
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

jni_cmake_flag=""
if [ "$jni" = true ]; then
    jni_cmake_flag="-DTTIO_RANS_BUILD_JNI=ON"
fi

echo "native: configuring (cmake -B _build${generator_args[*]:+ -G Ninja}${jni_cmake_flag:+ $jni_cmake_flag}) ..."
cmake -B _build "${generator_args[@]}" -DCMAKE_BUILD_TYPE=Release ${jni_cmake_flag:+"$jni_cmake_flag"} > /dev/null

if [ "$jni" = true ]; then
    echo "native: building ttio_rans + ttio_rans_jni ($(nproc) parallel jobs) ..."
    cmake --build _build --parallel "$(nproc)" --target ttio_rans --target ttio_rans_jni
else
    echo "native: building ttio_rans ($(nproc) parallel jobs) ..."
    cmake --build _build --parallel "$(nproc)" --target ttio_rans
fi

if [ ! -f "$LIB_PATH" ]; then
    echo "native: build completed but $LIB_PATH not produced -- investigate." >&2
    exit 3
fi

if [ "$jni" = true ] && [ ! -f "$JNI_LIB_PATH" ]; then
    echo "native: build completed but $JNI_LIB_PATH not produced -- investigate." >&2
    exit 3
fi

if [ "$jni" = true ]; then
    echo "native: built $LIB_PATH ($(stat -c %s "$LIB_PATH") bytes) and $JNI_LIB_PATH ($(stat -c %s "$JNI_LIB_PATH") bytes)."
else
    echo "native: built $LIB_PATH ($(stat -c %s "$LIB_PATH") bytes)."
fi