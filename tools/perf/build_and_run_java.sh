#!/bin/bash
# Java profiling harness build+run script.
set -eu

JAVA_DIR="$HOME/MPEG-O/java"
TOOLS_DIR="$HOME/MPEG-O/tools/perf"
BUILD_DIR="$HOME/MPEG-O/tools/perf/_build"
OUT_DIR="$HOME/MPEG-O/tools/perf/_out_java"

mkdir -p "$BUILD_DIR" "$OUT_DIR"

# Classpath: all runtime deps + compiled mpgo classes.
CP_FILE="$JAVA_DIR/target/runtime-classpath.txt"
if [[ ! -s "$CP_FILE" ]]; then
    echo "runtime-classpath.txt missing — run 'mvn test-compile' first" >&2
    exit 1
fi
CP="$(cat "$CP_FILE"):$JAVA_DIR/target/classes:/usr/share/java/jarhdf5.jar"
HDF5_NATIVE="/usr/lib/x86_64-linux-gnu/jni:/usr/lib/x86_64-linux-gnu/hdf5/serial"

echo "[build] javac -> $BUILD_DIR"
javac -d "$BUILD_DIR" -cp "$CP" "$TOOLS_DIR/ProfileHarness.java"

JFR_FILE="$OUT_DIR/profile.jfr"
rm -f "$JFR_FILE"

echo "[run] profiling with JFR -> $JFR_FILE"
java \
    -Djava.library.path="$HDF5_NATIVE" \
    -XX:+FlightRecorder \
    -XX:StartFlightRecording="filename=$JFR_FILE,settings=profile" \
    -cp "$CP:$BUILD_DIR" \
    tools.perf.ProfileHarness "$@"

echo
echo "[jfr] execution samples (hot methods by count):"
jfr print --events jdk.ExecutionSample --stack-depth 20 "$JFR_FILE" \
    > "$OUT_DIR/samples_raw.txt" 2>&1
wc -l "$OUT_DIR/samples_raw.txt"

echo
echo "[jfr] native method samples:"
jfr print --events jdk.NativeMethodSample --stack-depth 20 "$JFR_FILE" \
    > "$OUT_DIR/native_samples_raw.txt" 2>&1
wc -l "$OUT_DIR/native_samples_raw.txt"

echo
echo "[jfr] object allocation samples (what's being allocated on hot path):"
jfr print --events jdk.ObjectAllocationSample "$JFR_FILE" \
    > "$OUT_DIR/allocs_raw.txt" 2>&1
wc -l "$OUT_DIR/allocs_raw.txt"

echo
echo "[jfr] summary of recorded events:"
jfr summary "$JFR_FILE" | head -n 30
