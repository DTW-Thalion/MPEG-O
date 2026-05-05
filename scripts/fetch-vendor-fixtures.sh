#!/usr/bin/env bash
# fetch-vendor-fixtures.sh — download + sha256-verify the optional
# vendor-format integration test fixtures (Thermo, Bruker).
#
# The fixtures live under public, redistributable upstream URLs
# (ThermoRawFileParser MIT, ProteoWizard Apache-2.0). They are NOT
# committed to this repo — pinned via sha256 manifests under
# `data/vendor/<vendor>/`.
#
# Usage:
#   scripts/fetch-vendor-fixtures.sh                  # fetch all
#   scripts/fetch-vendor-fixtures.sh thermo           # fetch one
#   scripts/fetch-vendor-fixtures.sh bruker
#
# Outputs:
#   $HOME/fixtures/thermo/small.RAW
#   $HOME/fixtures/bruker/diaPASEF.d/{analysis.tdf,analysis.tdf_bin}
#
# Exports needed afterwards (printed at the end):
#   TTIO_THERMO_RAW_FIXTURE
#   TTIO_BRUKER_TDF_FIXTURE

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_ROOT="${TTIO_FIXTURE_ROOT:-$HOME/fixtures}"

vendors=("$@")
if [[ ${#vendors[@]} -eq 0 ]]; then
    vendors=(thermo bruker)
fi

fetch_thermo() {
    local dst="$FIXTURE_ROOT/thermo"
    mkdir -p "$dst"
    local url="https://raw.githubusercontent.com/compomics/ThermoRawFileParser/master/ThermoRawFileParserTest/Data/small.RAW"
    echo "[thermo] fetching small.RAW (~1.5 MB)..."
    curl -sLf -o "$dst/small.RAW" "$url"
    ( cd "$dst" && sha256sum -c "$REPO_ROOT/data/vendor/thermo/small.RAW.sha256" )
    echo "[thermo] OK: $dst/small.RAW"
    echo "         export TTIO_THERMO_RAW_FIXTURE=$dst/small.RAW"
}

fetch_bruker() {
    local dst="$FIXTURE_ROOT/bruker/diaPASEF.d"
    mkdir -p "$dst"
    local base="https://raw.githubusercontent.com/ProteoWizard/pwiz/master/pwiz/data/vendor_readers/Bruker/Reader_Bruker_Test.data/diaPASEF.d"
    echo "[bruker] fetching diaPASEF.d (~1 MB)..."
    curl -sLf -o "$dst/analysis.tdf"     "$base/analysis.tdf"
    curl -sLf -o "$dst/analysis.tdf_bin" "$base/analysis.tdf_bin"
    ( cd "$FIXTURE_ROOT/bruker" && \
      sha256sum -c "$REPO_ROOT/data/vendor/bruker/diaPASEF.d.sha256" )
    echo "[bruker] OK: $dst"
    echo "         export TTIO_BRUKER_TDF_FIXTURE=$dst"
}

for v in "${vendors[@]}"; do
    case "$v" in
        thermo) fetch_thermo ;;
        bruker) fetch_bruker ;;
        *)
            echo "unknown vendor: $v (expected thermo|bruker)" >&2
            exit 2
            ;;
    esac
done

echo
echo "All requested fixtures fetched + verified."
