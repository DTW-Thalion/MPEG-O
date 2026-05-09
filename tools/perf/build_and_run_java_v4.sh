#!/usr/bin/env bash
# V4 codec throughput harness for Java — builds ProfileJavaV4
# against the existing target/classes, runs it on either synthetic
# data (default) or a pre-extracted corpus.
#
# Usage:
#   ./build_and_run_java_v4.sh                 # synthetic 10 MiB
#   ./build_and_run_java_v4.sh chr22           # chr22 (170 MiB qualities)
#   ./build_and_run_java_v4.sh wes
#   ./build_and_run_java_v4.sh hg002_illumina
#   ./build_and_run_java_v4.sh hg002_pacbio
#
# Prereqs:
#   - Java compiled (mvn test-compile in java/)
#   - libttio_rans + libttio_rans_jni built (native/_build/)
#   - For corpus mode: tools/perf/htscodecs_compare.sh has been run
set -eu

ROOT="$HOME/TTI-O"
JAVA_DIR="$ROOT/java"
TOOLS_DIR="$ROOT/tools/perf"
BUILD_DIR="$TOOLS_DIR/_build_java_v4"
mkdir -p "$BUILD_DIR"

# Ensure runtime classpath is built (Maven generates it on demand).
CP_FILE="$JAVA_DIR/target/runtime-classpath.txt"
if [ ! -s "$CP_FILE" ]; then
    echo "[build] runtime-classpath.txt missing — generating"
    (cd "$JAVA_DIR" && mvn -q dependency:build-classpath \
        -Dmdep.outputFile=target/runtime-classpath.txt) >/dev/null
fi
CP="$(cat "$CP_FILE"):$JAVA_DIR/target/classes:/usr/share/java/jarhdf5.jar"

# Compile the harness if source is newer than .class.
SRC="$TOOLS_DIR/ProfileJavaV4.java"
CLS="$BUILD_DIR/tools/perf/ProfileJavaV4.class"
if [ ! -f "$CLS" ] || [ "$SRC" -nt "$CLS" ]; then
    echo "[build] javac -> $BUILD_DIR"
    javac -d "$BUILD_DIR" -cp "$CP" "$SRC"
fi

NATIVE="$ROOT/native/_build"
HDF5_LIBS="/usr/lib/x86_64-linux-gnu/jni:/usr/lib/x86_64-linux-gnu/hdf5/serial"

java \
    -Djava.library.path="$HDF5_LIBS:$NATIVE" \
    -cp "$CP:$BUILD_DIR" \
    tools.perf.ProfileJavaV4 "$@"
