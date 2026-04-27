#!/bin/bash
# Multi-function Java perf harness build+run script.
set -eu

JAVA_DIR="$HOME/TTI-O/java"
TOOLS_DIR="$HOME/TTI-O/tools/perf"
BUILD_DIR="$TOOLS_DIR/_build"
OUT_DIR="$TOOLS_DIR/_out_java_full"

mkdir -p "$BUILD_DIR" "$OUT_DIR"

CP_FILE="$JAVA_DIR/target/runtime-classpath.txt"
if [[ ! -s "$CP_FILE" ]]; then
    echo "runtime-classpath.txt missing — run 'mvn test-compile' first" >&2
    exit 1
fi
CP="$(cat "$CP_FILE"):$JAVA_DIR/target/classes:/usr/share/java/jarhdf5.jar"
HDF5_NATIVE="/usr/lib/x86_64-linux-gnu/jni:/usr/lib/x86_64-linux-gnu/hdf5/serial"

echo "[build] javac -> $BUILD_DIR"
javac -d "$BUILD_DIR" -cp "$CP" "$TOOLS_DIR/ProfileHarnessFull.java"

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
java \
    -Djava.library.path="$HDF5_NATIVE" \
    -XX:+FlightRecorder \
    -XX:StartFlightRecording="filename=$JFR_FILE,settings=profile" \
    -cp "$CP:$BUILD_DIR" \
    tools.perf.ProfileHarnessFull "$@"

echo
echo "[jfr] summary of recorded events:"
jfr summary "$JFR_FILE" | head -n 20 || true
