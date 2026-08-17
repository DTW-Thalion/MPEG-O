#!/usr/bin/env bash
# tools/perf/compression_suite/tools/install_sra_tools.sh
# Installs the NCBI SRA toolkit into ~/tools/sratoolkit (no sudo).
set -euo pipefail
VER=${SRA_VERSION:-3.1.1}
DEST=$HOME/tools
mkdir -p "$DEST"; cd "$DEST"
TAR=sratoolkit.$VER-ubuntu64.tar.gz
[ -f "$TAR" ] || curl -L -O "https://ftp-trace.ncbi.nlm.nih.gov/sra/sdk/$VER/$TAR"
tar xzf "$TAR"
ln -sfn "sratoolkit.$VER-ubuntu64" sratoolkit
echo "add to PATH: $DEST/sratoolkit/bin"
"$DEST/sratoolkit/bin/prefetch" --version
