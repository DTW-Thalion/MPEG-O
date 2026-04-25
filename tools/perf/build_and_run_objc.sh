#!/bin/bash
# ObjC profiling harness build+run script.
#
# Builds a standalone profile_objc binary linked against the already-
# built libTTIO. If BUILD_PG=1 is set, also rebuilds libTTIO with -pg
# and produces a gprof hot-method report.
set -e

ROOT="$HOME/TTI-O"
OBJC_DIR="$ROOT/objc"
TOOLS_DIR="$ROOT/tools/perf"
BUILD_DIR="$TOOLS_DIR/_build"
OUT_DIR="$TOOLS_DIR/_out_objc"

mkdir -p "$BUILD_DIR" "$OUT_DIR"

# --- Ensure libTTIO is built -----------------------------------------
if ! ls "$OBJC_DIR"/Source/*obj*/libTTIO* 2>/dev/null | head -1 >/dev/null; then
    echo "[build] libTTIO not built yet; running build.sh"
    (cd "$OBJC_DIR" && ./build.sh) >/dev/null
fi
LIB_OBJ_DIR="$(ls -d "$OBJC_DIR"/Source/*obj* | head -1)"
echo "[build] libTTIO found at $LIB_OBJ_DIR"

# --- Source GNUstep environment so clang sees -I/-L flags ------------
if command -v gnustep-config >/dev/null 2>&1; then
    GNUSTEP_MAKEFILES="$(gnustep-config --variable=GNUSTEP_MAKEFILES)"
    # shellcheck disable=SC1091
    . "$GNUSTEP_MAKEFILES/GNUstep.sh"
fi
GNU_CPP="$(gnustep-config --objc-flags 2>/dev/null || echo '')"
GNU_LIB="$(gnustep-config --base-libs 2>/dev/null || echo '-lgnustep-base')"

PG_FLAG=""
if [[ "${BUILD_PG:-0}" == "1" ]]; then
    PG_FLAG="-pg"
    echo "[build] BUILD_PG=1: instrumenting profile harness with -pg"
fi

OUT_BIN="$BUILD_DIR/profile_objc"

# Compile the harness with libTTIO's headers on the include path.
# libTTIO is ARC; the harness itself can be ARC too.
# shellcheck disable=SC2086
clang -fobjc-arc \
    -O2 $PG_FLAG \
    -I"$OBJC_DIR/Source" \
    $GNU_CPP \
    -L"$LIB_OBJ_DIR" \
    -L/usr/lib/x86_64-linux-gnu/hdf5/serial \
    -I/usr/include/hdf5/serial \
    "$TOOLS_DIR/profile_objc.m" \
    -L/usr/local/lib \
    -lTTIO -lhdf5_serial -lhdf5_serial_hl -lz -lcrypto -lsqlite3 -lobjc \
    $GNU_LIB \
    -o "$OUT_BIN"

echo "[run] $OUT_BIN $*"
(
    cd "$OUT_DIR"
    LD_LIBRARY_PATH="$LIB_OBJ_DIR:/usr/local/lib:${LD_LIBRARY_PATH:-}" \
        "$OUT_BIN" "$@"
)

if [[ "${BUILD_PG:-0}" == "1" && -f "$OUT_DIR/gmon.out" ]]; then
    echo
    echo "[gprof] flat profile (top 30 by self-time):"
    gprof -b -p "$OUT_BIN" "$OUT_DIR/gmon.out" | head -n 50
    echo
    echo "[gprof] call graph (top 20 by cumulative):"
    gprof -b -q "$OUT_BIN" "$OUT_DIR/gmon.out" | head -n 100
fi
