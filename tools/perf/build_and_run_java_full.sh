#!/bin/bash
# Multi-function Java perf harness build+run script.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JAVA_DIR="$ROOT/java"
TOOLS_DIR="$ROOT/tools/perf"
BUILD_DIR="$TOOLS_DIR/_build"
OUT_DIR="$TOOLS_DIR/_out_java_full"

mkdir -p "$BUILD_DIR" "$OUT_DIR"

CP_FILE="$JAVA_DIR/target/runtime-classpath.txt"
if [[ ! -s "$CP_FILE" ]]; then
    echo "runtime-classpath.txt missing — run 'mvn test-compile' first" >&2
    exit 1
fi
# Prefer the locally-built HDF5 Java bindings (the jar and the native
# libhdf5_java.so MUST be the same version) — this is the pair the Maven
# build uses (-Dhdf5.jar=/usr/local/lib/jarhdf5.jar). Fall back to the
# system package if the local build isn't present.
if [[ -f /usr/local/lib/jarhdf5.jar ]]; then
    HDF5_JAR=/usr/local/lib/jarhdf5.jar
else
    HDF5_JAR=/usr/share/java/jarhdf5.jar
fi
CP="$(cat "$CP_FILE"):$JAVA_DIR/target/classes:$HDF5_JAR"
# java.library.path: lead with /usr/local/lib (matching libhdf5_java.so)
# and $ROOT/native/_build (libttio_rans_jni.so — the v2 codecs
# ref_diff_v2 / name_tokenizer_v2 delegate to it); keep the system HDF5
# dirs as a fallback for environments without the local build.
HDF5_NATIVE="/usr/local/lib:$ROOT/native/_build:/usr/lib/x86_64-linux-gnu/jni:/usr/lib/x86_64-linux-gnu/hdf5/serial"

# Use JAVA_HOME's toolchain if set (so javac matches the runtime java and
# the major-66 build classes); otherwise fall back to PATH.
JAVAC="${JAVA_HOME:+$JAVA_HOME/bin/}javac"
JAVA_BIN="${JAVA_HOME:+$JAVA_HOME/bin/}java"

echo "[build] $JAVAC -> $BUILD_DIR"
"$JAVAC" -d "$BUILD_DIR" -cp "$CP" "$TOOLS_DIR/ProfileHarnessFull.java"

JFR_FILE="$OUT_DIR/profile.jfr"
rm -f "$JFR_FILE"

# Default --json $OUT_DIR/full.json so the perf-CI orchestrator
# always picks up fresh numbers from the Java leg without an
# explicit flag from the caller.
HAS_JSON=0
for a in "$@"; do
    [ "$a" = "--json" ] && HAS_JSON=1 && break
done
if [ "$HAS_JSON" = "0" ]; then
    set -- "$@" --json "$OUT_DIR/full.json"
fi

echo "[run] profiling with JFR -> $JFR_FILE"
"$JAVA_BIN" \
    -Djava.library.path="$HDF5_NATIVE" \
    -XX:+FlightRecorder \
    -XX:StartFlightRecording="filename=$JFR_FILE,settings=profile" \
    -cp "$CP:$BUILD_DIR" \
    tools.perf.ProfileHarnessFull "$@"

echo
echo "[jfr] summary of recorded events:"
jfr summary "$JFR_FILE" | head -n 20 || true
