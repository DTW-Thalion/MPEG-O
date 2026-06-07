#!/usr/bin/env bash
# run_perf_ci.sh — manual cross-SDK perf-regression orchestrator.
#
# Runs the Python, ObjC, and Java multi-function perf harnesses, then
# diffs the output against tools/perf/baseline.json via
# compare_baseline.py. All three SDKs run and are gated: each leg that
# is not explicitly skipped must produce a full.json, and a regression
# beyond threshold in any of them fails the run.
#
# NOT run in CI. The baseline is calibrated to the maintainer's local
# box; GitHub runners are noisier and would produce non-comparable
# numbers. Run this manually/occasionally (e.g. around a major release)
# on the box that captured the baseline:
#
#   bash tools/perf/run_perf_ci.sh                      # gate vs baseline
#   bash tools/perf/run_perf_ci.sh --update-baseline    # accept new numbers
#   PERF_N=10000 bash tools/perf/run_perf_ci.sh         # quick smoke run
#
# Exit status is propagated from compare_baseline.py:
#   0 — no regression
#   1 — at least one metric regressed beyond threshold
#   2 — usage / file / parse error

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"

# Workload size. Larger N makes each op run long enough that fixed
# scheduling/cache jitter is a small fraction of the timing, which
# (together with min-of-N timing) lets the gate use a tight threshold.
# This suite is run manually/occasionally (not in CI), so the ~15-20 min
# at PERF_N=100000 is an acceptable trade for stable numbers. Override
# with e.g. PERF_N=10000 for a quick smoke run.
PERF_N="${PERF_N:-100000}"
PERF_PEAKS="${PERF_PEAKS:-16}"

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
    "$here/build_and_run_python_full.sh" --n "$PERF_N" --peaks "$PERF_PEAKS"
fi

if [ "$run_objc" = "1" ]; then
    echo "[perf-ci] running ObjC harness..."
    "$here/build_and_run_objc_full.sh" --n "$PERF_N" --peaks "$PERF_PEAKS"
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
    "$here/build_and_run_java_full.sh" --n "$PERF_N" --peaks "$PERF_PEAKS"
fi

# Fail loudly if a SDK that ran produced no full.json (e.g. the harness
# silently errored out). Without this, the orchestrator would happily
# "compare" against an empty/missing file and the CI gate would go green
# while measuring nothing.
for pair in "python:$PYTHON_OUT" "objc:$OBJC_OUT" "java:$JAVA_OUT"; do
    lang="${pair%%:*}"; dir="${pair#*:}"
    eval "ran=\$run_$lang"
    if [ "$ran" = "1" ] && [ ! -s "$dir/full.json" ]; then
        echo "[perf-ci] ERROR: $lang harness produced no $dir/full.json" >&2
        exit 1
    fi
done

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
