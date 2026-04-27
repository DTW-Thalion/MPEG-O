#!/usr/bin/env bash
# Multi-function Python perf harness wrapper.
#
# Mirrors build_and_run_{objc,java}_full.sh — runs the full v0.11.1
# perf sweep and writes JSON to tools/perf/_out_python_full/full.json
# by default so the perf-CI orchestrator always picks up fresh
# numbers without an explicit `--json` flag from the caller.
#
# Caller args are forwarded verbatim to profile_python_full.py
# (e.g. `--n 10000 --peaks 16 --only ms.hdf5,encryption`).
set -euo pipefail

ROOT="$HOME/TTI-O"
TOOLS_DIR="$ROOT/tools/perf"
OUT_DIR="$TOOLS_DIR/_out_python_full"

mkdir -p "$OUT_DIR"

# Prefer the project venv if it exists; fall back to system python3.
if [ -x "$ROOT/.venv/bin/python" ]; then
    PY="$ROOT/.venv/bin/python"
else
    PY="python3"
fi

# Default --json so the orchestrator always gets a fresh result file.
HAS_JSON=0
for a in "$@"; do
    [ "$a" = "--json" ] && HAS_JSON=1 && break
done
if [ "$HAS_JSON" = "0" ]; then
    set -- "$@" --json "$OUT_DIR/full.json"
fi

# Default --out so temp files land in the right scratch dir.
HAS_OUT=0
for a in "$@"; do
    [ "$a" = "--out" ] && HAS_OUT=1 && break
done
if [ "$HAS_OUT" = "0" ]; then
    set -- "$@" --out "$OUT_DIR"
fi

echo "[run] $PY $TOOLS_DIR/profile_python_full.py $*"
exec "$PY" "$TOOLS_DIR/profile_python_full.py" "$@"
