#!/bin/bash
set -e
ROOT="$HOME/MPEG-O"
OBJC_DIR="$ROOT/objc"
BUILD="$ROOT/tools/perf/_build"
mkdir -p "$BUILD"

LIB_OBJ_DIR="$(ls -d "$OBJC_DIR"/Source/*obj* | head -1)"

if command -v gnustep-config >/dev/null 2>&1; then
    GNUSTEP_MAKEFILES="$(gnustep-config --variable=GNUSTEP_MAKEFILES)"
    . "$GNUSTEP_MAKEFILES/GNUstep.sh"
fi
GNU_CPP="$(gnustep-config --objc-flags 2>/dev/null || echo '')"
GNU_LIB="$(gnustep-config --base-libs 2>/dev/null || echo '-lgnustep-base')"

clang -fobjc-arc -O2 \
    -I"$OBJC_DIR/Source" \
    -I/usr/include/hdf5/serial \
    $GNU_CPP \
    -L"$LIB_OBJ_DIR" \
    -L/usr/lib/x86_64-linux-gnu/hdf5/serial \
    -L/usr/local/lib \
    "$ROOT/tools/perf/profile_read_detail.m" \
    -lMPGO -lhdf5_serial -lhdf5_serial_hl -lz -lcrypto -lsqlite3 -lobjc \
    $GNU_LIB \
    -o "$BUILD/profile_read_detail"

LD_LIBRARY_PATH="$LIB_OBJ_DIR:/usr/local/lib:${LD_LIBRARY_PATH:-}" \
    "$BUILD/profile_read_detail" "$@"
