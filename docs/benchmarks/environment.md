# M92 Benchmark Environment

The benchmark harness needs three external tools alongside the
TTI-O Python package: `samtools` (for BAM/CRAM and the SAM-text
intermediate), `genie` (MPEG-G reference encoder/decoder), and
the Python `ttio` package itself.

## samtools (CRAM 3.1)

Modern samtools writes CRAM 3.1 by default. Verified with v1.19+.

```bash
sudo apt install samtools           # Ubuntu 24.04+ ships ≥ 1.19
samtools --version | head -1        # samtools 1.19.2 / htslib 1.19
```

The benchmark harness pins `version=3.1` explicitly via
`--output-fmt-option version=3.1` so older samtools that defaults
to CRAM 3.0 won't accidentally skew results.

## ttio (Python)

```bash
cd /path/to/TTI-O/python
pip install -e ".[test,import]"
python -c "import ttio; print(ttio.__version__)"   # 1.2.0
```

## Genie (MPEG-G reference)

Genie is the MPEG group's reference implementation of MPEG-G
(ISO/IEC 23092). Built from source.

### Build (Ubuntu 22.04+ / 24.04 / WSL Ubuntu)

Genie depends on **libbsc** (Block-Sorting Compression by
Ilya Grebnov), which is not packaged in apt. We build it
from source first and install to a user-local prefix.

```bash
sudo apt install -y build-essential cmake git \
                    libboost-all-dev libssl-dev zlib1g-dev \
                    libbz2-dev liblzma-dev libcurl4-openssl-dev \
                    libdeflate-dev libhts-dev pkg-config

PREFIX="$HOME/genie/install"
mkdir -p "$HOME/src" "$PREFIX"

# 1. libbsc — header + static lib only.
cd "$HOME/src"
git clone --depth 1 https://github.com/IlyaGrebnov/libbsc.git
cd libbsc
make -j"$(nproc)"
cp libbsc/libbsc.h "$PREFIX/include/"
cp libbsc.a        "$PREFIX/lib/"

# 2. Genie. CMake finds libbsc via CMAKE_PREFIX_PATH.
cd "$HOME/src"
git clone --recursive https://github.com/MueFab/genie.git
cd genie
mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" \
      -DCMAKE_PREFIX_PATH="$PREFIX" \
      -DBSC_INCLUDE_DIR="$PREFIX/include" \
      -DBSC_LIBRARY="$PREFIX/lib/libbsc.a" \
      ..
make -j"$(nproc)"
make install

"$PREFIX/bin/genie" --help | head -5
# Pin the commits you built — record both in the report's
# host-metadata section.
git -C "$HOME/src/libbsc" rev-parse HEAD
git -C "$HOME/src/genie"  rev-parse HEAD
```

The repo ships a ready-to-run build script with the same
sequence at [`/home/toddw/genie_build.sh`](../../tools/benchmarks/genie_build.sh)
(WSL absolute path; see `tools/benchmarks/genie_build.sh` if
checked into the tree).

If your distro lacks `libdeflate-dev`, install
`libdeflate1 libdeflate-tools` and pass
`-DUSE_BUNDLED_LIBDEFLATE=ON` to cmake.

### Pinning

The harness uses whichever `genie` is on `PATH`, or `$GENIE_BIN`
if set. Pin a specific commit by setting:

```bash
export GENIE_BIN=/opt/genie-v2.0.0/bin/genie
```

…and recording the commit SHA in the report's host-metadata
section. The runner captures `samtools --version`; record genie's
build identifier alongside in the report manually until we wire
up auto-detection.

### Known caveats

- MueFab/genie has no formal release tags; we pin by commit SHA
  rather than version. Record the SHA produced by the
  `git rev-parse HEAD` at the end of the build script.
- The CLI grammar has churned across the project's history. The
  harness exercises only `genie run -i ... -o ... -f`; the
  `genie capsulate` / `genie unframe` subcommands are not used.
  If a future commit breaks `genie run`, fall back to the last
  known-good SHA recorded in `docs/benchmarks/v1.2.0-report.md`.

## Verifying the toolchain

```bash
python -m tools.benchmarks.cli list
```

Datasets that aren't on disk will be marked with `✗ (missing)`.
Tools that aren't on `PATH` will surface the first time their
adapter runs (the harness fails the run, not the whole sweep).

## CI

The benchmarks are too heavy for per-PR CI. They run on demand:

```bash
gh workflow run bench.yml -f dataset=chr22_na12878
```

…on the cold-storage runner with the fixture cache already
warmed via `dvc pull`. Results land in `gh-pages` under
`benchmarks/<commit-sha>.md`.
