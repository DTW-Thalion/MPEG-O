#!/usr/bin/env bash
# dev-setup.sh — one-shot Python developer setup for TTI-O.
#
# Builds the native rANS shared library, installs the Python
# package in editable mode with the broadest test extras, and
# prints the env vars required for an unblocked `pytest` run.
#
# Usage:
#   scripts/dev-setup.sh                # default: -e .[test,integration]
#   TTIO_PIP_EXTRAS="test,bruker,pqc" \
#     scripts/dev-setup.sh              # custom extras
#   TTIO_SKIP_NATIVE=1 scripts/dev-setup.sh  # Python-only, no cmake
#
# Prerequisites:
#   - cmake >= 3.16 + a C compiler + ninja (apt: cmake ninja-build)
#   - Python 3.11+
#   - libhdf5-dev + zlib1g-dev (apt) for h5py
#
# Idempotent: re-running re-builds only when sources changed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXTRAS="${TTIO_PIP_EXTRAS:-test,integration}"
SKIP_NATIVE="${TTIO_SKIP_NATIVE:-0}"

echo "==> repo: $REPO_ROOT"
echo "==> extras: [$EXTRAS]"
echo

if [[ "$SKIP_NATIVE" != "1" ]]; then
    if ! command -v cmake >/dev/null; then
        echo "error: cmake not on PATH. Install with:"
        echo "  sudo apt-get install -y cmake ninja-build"
        echo "or set TTIO_SKIP_NATIVE=1 to skip the native build (genomic"
        echo "codec tests will be unavailable)."
        exit 2
    fi

    GENERATOR="Unix Makefiles"
    if command -v ninja >/dev/null; then
        GENERATOR="Ninja"
    fi

    echo "==> Building native rANS library ($GENERATOR)..."
    # -DTTIO_RANS_BUILD_JNI=ON also produces libttio_rans_jni.so so
    # the Java cross-language tests can load the codec via JNI. The
    # Python test resolver puts native/_build on java.library.path
    # automatically when subprocessing into Java tools.
    cmake -B "$REPO_ROOT/native/_build" \
          -G "$GENERATOR" \
          -DCMAKE_BUILD_TYPE=Release \
          -DTTIO_RANS_BUILD_JNI=ON \
          "$REPO_ROOT/native"
    cmake --build "$REPO_ROOT/native/_build" --parallel

    if [[ ! -f "$REPO_ROOT/native/_build/libttio_rans.so" ]]; then
        echo "error: cmake build did not produce libttio_rans.so" >&2
        exit 1
    fi
    echo "==> native lib: $REPO_ROOT/native/_build/libttio_rans.so"
else
    echo "==> Skipping native build (TTIO_SKIP_NATIVE=1)"
fi
echo

echo "==> Installing Python package in editable mode..."

# PEP 668 (Ubuntu 24.04+, Debian 12+, recent macOS) marks
# system-managed Python environments as externally managed and pip
# refuses to install into them. Three respected paths forward:
#   (1) the user is already in a venv → no flags needed (preferred)
#   (2) TTIO_PIP_ARGS is set explicitly (e.g. "--user --break-system-packages")
#   (3) we detect PEP 668 + no venv and stop with a clear error.
PIP_ARGS="${TTIO_PIP_ARGS:-}"
if [[ -z "${VIRTUAL_ENV:-}" ]] && [[ -z "$PIP_ARGS" ]]; then
    if python3 -c 'import sys; sys.exit(0 if hasattr(sys, "base_prefix") and sys.base_prefix == sys.prefix else 1)' 2>/dev/null; then
        # Not in a venv. Probe for the EXTERNALLY-MANAGED marker.
        marker_found=0
        for d in $(python3 -c 'import sys; import sysconfig; p = sysconfig.get_path("stdlib", vars={"installed_base": sys.base_prefix}); print(p)' 2>/dev/null); do
            if [[ -f "$d/EXTERNALLY-MANAGED" ]]; then
                marker_found=1
                break
            fi
        done
        if [[ "$marker_found" == "1" ]]; then
            cat <<EOF >&2
error: this Python is marked externally-managed (PEP 668) and pip
will refuse to install. You have three options:

  (a) Create + activate a venv (recommended):
        python3 -m venv .venv
        source .venv/bin/activate
        scripts/dev-setup.sh

  (b) Override with --break-system-packages (fast, less safe):
        TTIO_PIP_ARGS="--break-system-packages --user" \\
          scripts/dev-setup.sh

  (c) Install via pipx (per-tool isolation):
        pipx install -e ./python --pip-args="$EXTRAS"

Aborting.
EOF
            exit 3
        fi
    fi
fi

# shellcheck disable=SC2086
( cd "$REPO_ROOT/python" && \
  python3 -m pip install $PIP_ARGS --upgrade pip setuptools wheel && \
  pip install $PIP_ARGS -e ".[$EXTRAS]" )
echo

cat <<EOF
==> Setup complete.

Add these to your shell rc (or run before pytest):

  export TTIO_RANS_LIB_PATH="$REPO_ROOT/native/_build/libttio_rans.so"

Optional vendor-format integration tests need extra fixtures:

  scripts/fetch-vendor-fixtures.sh         # downloads + sha256-verifies
  export TTIO_THERMO_RAW_FIXTURE="\$HOME/fixtures/thermo/small.RAW"
  export TTIO_BRUKER_TDF_FIXTURE="\$HOME/fixtures/bruker/diaPASEF.d"

The Thermo test also needs the ThermoRawFileParser CLI on PATH —
see docs/test-strategy.md "Thermo .raw delegation" for the
mono + binary install steps.

Quick sanity:

  cd python && pytest tests/validation -q
EOF
