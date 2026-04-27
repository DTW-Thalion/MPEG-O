#!/bin/bash
# Multi-function ObjC perf harness build+run script.
#
# Builds a standalone profile_objc_full binary linked against the
# already-built libTTIO. Mirrors build_and_run_objc.sh but compiles
# the extended harness covering every major v0.11.1 function.
set -e

ROOT="$HOME/TTI-O"
OBJC_DIR="$ROOT/objc"
TOOLS_DIR="$ROOT/tools/perf"
BUILD_DIR="$TOOLS_DIR/_build"
OUT_DIR="$TOOLS_DIR/_out_objc_full"

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

OUT_BIN="$BUILD_DIR/profile_objc_full"

# shellcheck disable=SC2086
clang -fobjc-arc \
    -O2 \
    -I"$OBJC_DIR/Source" \
    $GNU_CPP \
    -L"$LIB_OBJ_DIR" \
    -L/usr/lib/x86_64-linux-gnu/hdf5/serial \
    -I/usr/include/hdf5/serial \
    "$TOOLS_DIR/profile_objc_full.m" \
    -L/usr/local/lib \
    -lTTIO -lhdf5_serial -lhdf5_serial_hl -lz -lcrypto -lsqlite3 -lobjc \
    $GNU_LIB -lm \
    -o "$OUT_BIN"

# Default `--json $OUT_DIR/full.json` so the perf-CI orchestrator
# always gets a fresh result file. Caller can override by passing
# their own `--json <path>` on the command line.
HAS_JSON=0
for a in "$@"; do
    [ "$a" = "--json" ] && HAS_JSON=1 && break
done
if [ "$HAS_JSON" = "0" ]; then
    set -- "$@" --json "$OUT_DIR/full.json"
fi

echo "[run] $OUT_BIN $*"
(
    cd "$OUT_DIR"
    LD_LIBRARY_PATH="$LIB_OBJ_DIR:/usr/local/lib:${LD_LIBRARY_PATH:-}" \
        "$OUT_BIN" "$@"
)
