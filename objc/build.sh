#!/usr/bin/env bash
# build.sh — convenience wrapper that verifies build prerequisites,
# selects clang as the Objective-C compiler, sources the GNUstep
# environment, and invokes `make` with any extra arguments forwarded.
#
# Usage:
#   ./build.sh              # build everything
#   ./build.sh check        # build and run the test suite
#   ./build.sh clean        # clean build artefacts

set -e

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

"$here/check-deps.sh"

if ! command -v clang >/dev/null 2>&1; then
    echo "build.sh: clang is required but was not found on PATH" >&2
    exit 1
fi

if command -v gnustep-config >/dev/null 2>&1; then
    GNUSTEP_MAKEFILES="$(gnustep-config --variable=GNUSTEP_MAKEFILES)"
    # shellcheck disable=SC1091
    . "$GNUSTEP_MAKEFILES/GNUstep.sh"
fi

exec make CC=clang OBJC=clang "$@"
