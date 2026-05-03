#!/usr/bin/env bash
# V4 codec throughput harness — builds profile_objc_v4 against the
# already-built libTTIO + libttio_rans, runs it on either synthetic
# data (default) or a pre-extracted corpus.
#
# Usage:
#   ./build_and_run_objc_v4.sh                 # synthetic 10 MiB
#   ./build_and_run_objc_v4.sh chr22           # chr22 (170 MiB qualities)
#   ./build_and_run_objc_v4.sh wes
#   ./build_and_run_objc_v4.sh hg002_illumina
#   ./build_and_run_objc_v4.sh hg002_pacbio
#
# Prereqs:
#   - libTTIO built (objc/Source/obj/libTTIO.so)
#   - libttio_rans built (native/_build/libttio_rans.so)
#   - For corpus mode: tools/perf/htscodecs_compare.sh has been run
#     to populate /tmp/{name}_v4_{qual,lens,flags}.bin
set -eu

ROOT="$HOME/TTI-O"
TOOLS_DIR="$ROOT/tools/perf"
OUT_DIR="$TOOLS_DIR/_out_objc_v4"
mkdir -p "$OUT_DIR"

OBJC_SRC="$ROOT/objc/Source"
NATIVE="$ROOT/native/_build"
HDF5_DIR="/usr/lib/x86_64-linux-gnu/hdf5/serial"
HDF5_INCLUDE="/usr/include/hdf5/serial"

# Build only if source is newer than binary.
SRC="$TOOLS_DIR/profile_objc_v4.m"
BIN="$OUT_DIR/profile_objc_v4"
if [ ! -f "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
    echo "[build] $BIN"
    clang \
      -I/usr/GNUstep/Local/Library/Headers -I"$OBJC_SRC" \
      -I"$HDF5_INCLUDE" \
      -DGNUSTEP -fobjc-runtime=gnustep-2.2 -fblocks \
      -fconstant-string-class=NSConstantString \
      -fexceptions -fobjc-exceptions -D_NATIVE_OBJC_EXCEPTIONS -O2 \
      -L/usr/GNUstep/Local/Library/Libraries -L/usr/local/lib \
      -L"$OBJC_SRC/obj" -L"$NATIVE" -L"$HDF5_DIR" \
      -Wl,-rpath,"$OBJC_SRC/obj" -Wl,-rpath,"$NATIVE" \
      -Wl,-rpath,"$HDF5_DIR" \
      -Wl,-rpath,/usr/GNUstep/Local/Library/Libraries \
      -Wl,-rpath,/usr/local/lib \
      "$SRC" \
      -lTTIO -lttio_rans -lhdf5 -lhdf5_hl -lz -lcrypto \
      -lgnustep-base -lobjc -lpthread -lm \
      -o "$BIN"
fi

"$BIN" "$@"
