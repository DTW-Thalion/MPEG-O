#!/usr/bin/env bash
# build.sh — convenience wrapper that verifies build prerequisites,
# selects clang as the Objective-C compiler, sources the GNUstep
# environment, and invokes `make` with any extra arguments forwarded.
#
# Usage:
#   ./build.sh                   # build everything
#   ./build.sh check             # build and run the test suite
#   ./build.sh clean             # clean build artefacts
#   ./build.sh --coverage check  # build with clang coverage instrumentation,
#                                 # run tests, emit objc/coverage/coverage.lcov
#                                 # (requires llvm-profdata + llvm-cov on PATH;
#                                 # warns and skips export if missing).
#
# V1 (verification workplan): the --coverage flag injects
# -fprofile-instr-generate -fcoverage-mapping into ADDITIONAL_OBJCFLAGS
# and ADDITIONAL_LDFLAGS via the GNUstep make convention. After tests,
# the .profraw files are merged into a single coverage.lcov for CI
# upload. See docs/verification-workplan.md §V1.

set -e

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

# Parse and consume our own flags before forwarding the rest to make.
COVERAGE=0
PASSTHROUGH=()
for arg in "$@"; do
    case "$arg" in
        --coverage) COVERAGE=1 ;;
        *) PASSTHROUGH+=("$arg") ;;
    esac
done

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

if [ "$COVERAGE" = "1" ]; then
    # -fprofile-instr-generate emits a .profraw per process; the path
    # is controlled at runtime via LLVM_PROFILE_FILE. The %p pattern
    # expands to the pid so concurrent test executables don't clobber
    # each other. The actual flag injection is done by
    # objc/GNUmakefile.preamble guarded on TTIO_COVERAGE — we cannot
    # set ADDITIONAL_* on the make command line because make's
    # command-line vars override (not append to) the makefile's `+=`,
    # which would silently drop -fobjc-arc and break the build.
    export LLVM_PROFILE_FILE="$here/coverage/raw/ttio-%p.profraw"
    export TTIO_COVERAGE=1
    mkdir -p "$here/coverage/raw"
    rm -f "$here/coverage/raw/"*.profraw 2>/dev/null || true

    make CC=clang OBJC=clang "${PASSTHROUGH[@]}"

    # If the user said --coverage but did not say `check`, no .profraw
    # files will exist (nothing was executed). That's fine — coverage
    # build artefacts are still useful (linker confirmed the flags work).
    shopt -s nullglob
    profraws=("$here/coverage/raw/"*.profraw)
    shopt -u nullglob

    if [ ${#profraws[@]} -eq 0 ]; then
        echo "build.sh --coverage: no .profraw files emitted (did you run with 'check'?)" >&2
        exit 0
    fi

    # Resolve the llvm tool names — distros ship them version-suffixed
    # (llvm-cov-18 on Ubuntu 24.04 noble) so fall back if unsuffixed
    # isn't on PATH.
    find_llvm_tool() {
        local base="$1"
        if command -v "$base" >/dev/null 2>&1; then
            echo "$base"; return 0
        fi
        local versioned
        versioned=$(compgen -c "${base}-" 2>/dev/null | grep -E "^${base}-[0-9]+$" | sort -t- -k2 -n -r | head -1)
        if [ -n "$versioned" ]; then
            echo "$versioned"; return 0
        fi
        return 1
    }

    if ! LLVM_PROFDATA=$(find_llvm_tool llvm-profdata) || \
       ! LLVM_COV=$(find_llvm_tool llvm-cov); then
        echo "build.sh --coverage: llvm-profdata + llvm-cov not on PATH;" >&2
        echo "                    raw profiles in $here/coverage/raw/" >&2
        echo "                    install with: apt install llvm" >&2
        exit 0
    fi

    "$LLVM_PROFDATA" merge -sparse "${profraws[@]}" \
        -o "$here/coverage/coverage.profdata"

    # Find every binary that participates in a coverage-instrumented
    # test run. The test runner is at Tests/obj/TTIOTests, but it
    # links against libTTIO.so (Source/obj/libTTIO.so) which carries
    # ~all the production code's coverage maps. llvm-cov needs every
    # binary object that contributed profile data passed as -object
    # so it can resolve the corresponding source files.
    binaries=()
    while IFS= read -r -d '' bin; do
        # First binary is the positional arg to llvm-cov export; the
        # rest get -object prefixes (added later).
        binaries+=("$bin")
    done < <(find "$here" -path "*/obj/TTIOTests" -type f -print0 2>/dev/null)
    # Also pick up the shared libTTIO.so* the test binary links to —
    # without this the report contains only Tests/ source coverage.
    while IFS= read -r -d '' lib; do
        binaries+=("$lib")
    done < <(find "$here/Source" -name "libTTIO.so*" -type f -print0 2>/dev/null)

    if [ ${#binaries[@]} -eq 0 ]; then
        echo "build.sh --coverage: no TTIOTests binary found under $here" >&2
        echo "                    raw profiles in $here/coverage/raw/" >&2
        exit 0
    fi

    # llvm-cov export needs one positional binary; the rest take -object.
    primary="${binaries[0]}"
    rest=()
    for ((i=1; i<${#binaries[@]}; i++)); do
        rest+=("-object" "${binaries[$i]}")
    done

    "$LLVM_COV" export "$primary" "${rest[@]}" \
        -instr-profile="$here/coverage/coverage.profdata" \
        -format=lcov > "$here/coverage/coverage.lcov"

    lines_hit=$(grep -c '^DA:.*,[1-9]' "$here/coverage/coverage.lcov" || echo 0)
    echo "build.sh --coverage: wrote $here/coverage/coverage.lcov ($lines_hit hit lines)"
    exit 0
fi

exec make CC=clang OBJC=clang "${PASSTHROUGH[@]}"
