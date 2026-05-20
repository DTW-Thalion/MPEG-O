#!/usr/bin/env bash
#
# scripts/workbench-live-smoke.sh
#
# Boots a real tti-workbench-server daemon and runs the client-SDK
# live integration test (python/tests/integration/test_workbench_live.py)
# against it. This is the live half of the W1-W5 acceptance gates:
# the unit suites pin the wire shapes, this proves the actual
# ttio.workbench.* client talks to the daemon.
#
# Inputs (env, with sensible defaults):
#   TTIOWB_SERVER_DIR   path to a built tti-workbench-server checkout
#                       (default: $HOME/tti-workbench-server)
#   TTIO_REPO_PATH      path to this TTI-O checkout
#                       (default: the repo this script lives in)
#   TTIOWB_PORT         daemon port (default: 18493)
#   TTIOWB_PROJECT      project to seed the bootstrap admin into
#                       (default: adni)
#
# The daemon binary must already be built
# ($TTIOWB_SERVER_DIR/Tools/obj/TtioWBServer); build it with
# `cd tti-workbench-server && bash scripts/build.sh` first. The CI
# workflow builds it; locally it is usually already built.
#
# Exits non-zero on any failure; tears the daemon down on exit.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TTIO_REPO_PATH="${TTIO_REPO_PATH:-$REPO_ROOT}"
TTIOWB_SERVER_DIR="${TTIOWB_SERVER_DIR:-$HOME/tti-workbench-server}"
PORT="${TTIOWB_PORT:-18493}"
PROJECT="${TTIOWB_PROJECT:-adni}"

DAEMON="$TTIOWB_SERVER_DIR/Tools/obj/TtioWBServer"
if [ ! -x "$DAEMON" ]; then
    echo "error: daemon not built at $DAEMON" >&2
    echo "       run: (cd '$TTIOWB_SERVER_DIR' && bash scripts/build.sh)" >&2
    exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ttiowb-live.XXXXXX")"
mkdir -p "$WORK/containers" "$WORK/staging"

cat > "$WORK/conf.json" <<EOF
{
  "listen": { "host": "127.0.0.1", "port": $PORT, "worker_count": 1, "shutdown_grace_seconds": 5 },
  "storage": { "root": "$WORK/containers" },
  "staging": { "root": "$WORK/staging", "retention_hours": 1 },
  "db": { "backend": "sqlite", "sqlite": { "path": "$WORK/metadata.sqlite" }, "pool_size": 4 },
  "pipelines": { "max_concurrent_jobs": 2, "cancel_grace_seconds": 3 },
  "logging": { "path": "$WORK/server.log", "level": "info" },
  "audit": { "path": "$WORK/audit.log" }
}
EOF

export LD_LIBRARY_PATH="$TTIOWB_SERVER_DIR/Source/obj:$TTIO_REPO_PATH/objc/Source/obj:/usr/local/lib:/usr/GNUstep/Local/Library/Libraries:${LD_LIBRARY_PATH:-}"

DAEMON_PID=""
cleanup() {
    if [ -n "$DAEMON_PID" ]; then
        kill -TERM "$DAEMON_PID" 2>/dev/null || true
        sleep 1
        kill -0 "$DAEMON_PID" 2>/dev/null && kill -9 "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> starting daemon on 127.0.0.1:$PORT (workdir $WORK)"
"$DAEMON" --config "$WORK/conf.json" > "$WORK/run.log" 2>&1 &
DAEMON_PID=$!

READY=0
for _ in $(seq 1 120); do
    if curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/healthz"; then
        READY=1; break
    fi
    sleep 0.5
done
if [ "$READY" != 1 ]; then
    echo "FAIL: daemon never answered /healthz" >&2
    echo "--- run.log ---"; cat "$WORK/run.log" >&2 || true
    exit 1
fi

echo "==> seeding bootstrap admin into project '$PROJECT'"
python3 - "$WORK/metadata.sqlite" "$PROJECT" <<'PY'
import sqlite3, sys, json
db, project = sys.argv[1], sys.argv[2]
con = sqlite3.connect(db)
con.execute("UPDATE users SET projects = ? WHERE username = 'admin'",
            (json.dumps([project]),))
con.commit()
con.close()
PY

echo "==> running client-SDK live integration tests"
export TTIO_WORKBENCH_URL="ws://127.0.0.1:$PORT/transport"
export TTIO_WORKBENCH_STAGING="$WORK/staging"
export TTIO_WORKBENCH_PROJECT="$PROJECT"
export TTIO_RANS_LIB_PATH="${TTIO_RANS_LIB_PATH:-$TTIO_REPO_PATH/native/_build/libttio_rans.so}"

# Capture test exit codes rather than aborting on first failure.
set +e

# --- Python client live test ---
echo "==> [python] pytest test_workbench_live.py"
( cd "$TTIO_REPO_PATH/python" \
  && python3 -m pytest tests/integration/test_workbench_live.py -v --no-header "$@" )
PY_RC=$?

# --- Java client live test (parity; opt-in via TTIOWB_JAVA_TEST=1
#     since it needs Maven + JDK 22+; the workbench-live workflow
#     sets it, local runs default to Python-only) ---
JAVA_RC=0
if [ "${TTIOWB_JAVA_TEST:-0}" = "1" ]; then
    echo "==> [java] mvn -Dtest=WorkbenchLiveTest"
    ( cd "$TTIO_REPO_PATH/java" \
      && mvn -q -Djacoco.skip=true \
             -Dhdf5.jar.path=/usr/local/lib/jarhdf5.jar \
             -Dsurefire.failIfNoSpecifiedTests=false \
             -Dtest=WorkbenchLiveTest test )
    JAVA_RC=$?
fi

echo "==> server.log tail:"; tail -8 "$WORK/server.log" 2>/dev/null || true
echo "==> results: python=$PY_RC java=$JAVA_RC"
[ "$PY_RC" = 0 ] && [ "$JAVA_RC" = 0 ]
