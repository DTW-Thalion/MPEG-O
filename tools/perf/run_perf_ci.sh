#!/usr/bin/env bash
# run_perf_ci.sh — V2 perf-regression CI orchestrator.
#
# Runs the Python and ObjC multi-function perf harnesses, then diffs
# the output against tools/perf/baseline.json via compare_baseline.py.
# Java is intentionally absent in v1: ProfileHarnessFull emits
# tabular text + JFR, not JSON; adding JSON output is a V2.1
# follow-up.
#
# Exit status is propagated from compare_baseline.py:
#   0 — no regression
#   1 — at least one metric regressed beyond threshold
#   2 — usage / file / parse error
#
# Per docs/verification-workplan.md §V2.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"

PYTHON_OUT="$here/_out_python_full"
OBJC_OUT="$here/_out_objc_full"
JAVA_OUT="$here/_out_java_full"

mkdir -p "$PYTHON_OUT" "$OBJC_OUT" "$JAVA_OUT"

run_python=1
run_objc=1
run_java=1
threshold_arg=()
update_baseline=0

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-python) run_python=0; shift ;;
        --skip-objc)   run_objc=0; shift ;;
        --skip-java)   run_java=0; shift ;;
        --threshold)   threshold_arg=(--threshold "$2"); shift 2 ;;
        --update-baseline) update_baseline=1; shift ;;
        --help|-h)
            sed -n '2,15p' "$0"
            exit 0
            ;;
        *)
            echo "unknown arg: $1" >&2
            exit 2
            ;;
    esac
done

if [ "$run_python" = "1" ]; then
    echo "[perf-ci] running Python harness..."
    "$here/build_and_run_python_full.sh" --n 10000 --peaks 16
fi

if [ "$run_objc" = "1" ]; then
    echo "[perf-ci] running ObjC harness..."
    "$here/build_and_run_objc_full.sh" --n 10000 --peaks 16
fi

if [ "$run_java" = "1" ]; then
    echo "[perf-ci] running Java harness..."
    # build_and_run_java_full.sh requires target/runtime-classpath.txt;
    # ensure it exists by running mvn dependency:build-classpath if not.
    if [ ! -s "$repo_root/java/target/runtime-classpath.txt" ]; then
        (cd "$repo_root/java" && \
            mvn -q dependency:build-classpath \
                -Dmdep.outputFile=target/runtime-classpath.txt)
    fi
    "$here/build_and_run_java_full.sh" --n 10000 --peaks 16
fi

new_args=()
[ "$run_python" = "1" ] && new_args+=(--new "$PYTHON_OUT/full.json:python")
[ "$run_objc" = "1" ]   && new_args+=(--new "$OBJC_OUT/full.json:objc")
[ "$run_java" = "1" ]   && new_args+=(--new "$JAVA_OUT/full.json:java")

if [ ${#new_args[@]} -eq 0 ]; then
    echo "[perf-ci] both harnesses skipped — nothing to compare" >&2
    exit 0
fi

update_args=()
[ "$update_baseline" = "1" ] && update_args+=(--update-baseline)

echo "[perf-ci] comparing against baseline..."
exec python3 "$here/compare_baseline.py" \
    --baseline "$here/baseline.json" \
    "${new_args[@]}" \
    "${threshold_arg[@]}" \
    "${update_args[@]}"
