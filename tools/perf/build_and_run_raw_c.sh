#!/bin/bash
# Pure-C libhdf5 baseline harness — bypasses every binding layer.
set -e

BUILD_DIR="$HOME/MPEG-O/tools/perf/_build"
mkdir -p "$BUILD_DIR"

OUT="$BUILD_DIR/profile_raw_c"
clang -O2 -Wall \
    -I/usr/include/hdf5/serial \
    -L/usr/lib/x86_64-linux-gnu/hdf5/serial \
    "$HOME/MPEG-O/tools/perf/profile_raw_c.c" \
    -lhdf5_serial -lhdf5_serial_hl -lz \
    -o "$OUT"

"$OUT" "$@"
