#!/usr/bin/env bash
# v0.7 M51: thin wrapper that invokes a com.dtwthalion.mpgo.tools.* main
# class with the full runtime classpath (including the system-scoped
# jhdf5 jar). Used by the compound-parity harness to run the Java
# dumper the same way Python and ObjC invoke their native CLIs.
#
# Usage:
#   ./run-tool.sh <fully.qualified.ClassName> [args...]
#
# The companion `mvn exec:java` path can't see system-scope deps, so
# this script builds an explicit CLASSPATH instead.
set -e

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

# Detect HDF5 jar and native libs.
if [ -z "${MPGO_HDF5_JAR:-}" ]; then
    if [ -f /usr/share/java/jarhdf5.jar ]; then
        MPGO_HDF5_JAR=/usr/share/java/jarhdf5.jar
    else
        echo "run-tool.sh: set MPGO_HDF5_JAR to the jhdf5 jar path" >&2
        exit 1
    fi
fi
if [ -z "${MPGO_HDF5_NATIVE:-}" ]; then
    MPGO_HDF5_NATIVE=/usr/lib/x86_64-linux-gnu/jni:/usr/lib/x86_64-linux-gnu/hdf5/serial
fi

# Ensure the project is built so target/classes exists.
if [ ! -d target/classes ]; then
    mvn -q -B compile >&2
fi

# Build the dependency classpath once. Cache so subsequent runs are fast.
cp_file="target/runtime-classpath.txt"
if [ ! -f "$cp_file" ] || [ pom.xml -nt "$cp_file" ]; then
    mvn -q -B dependency:build-classpath \
        -DincludeScope=runtime \
        -Dmdep.outputFile="$cp_file" >&2
fi

CLASSPATH="target/classes:$(cat "$cp_file"):$MPGO_HDF5_JAR"
exec java -cp "$CLASSPATH" -Djava.library.path="$MPGO_HDF5_NATIVE" "$@"
