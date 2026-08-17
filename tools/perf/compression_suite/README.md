# Compression benchmark suite

Measures whole real datasets as TTI-O vs CRAM 3.0 / 3.1 vs MPEG-G
(genie), and vs mzML.gz / mzML+numpress for mass spectrometry. Every
size in REPORT.md has a passing decode-verify. Design:
docs/superpowers/specs/2026-08-16-compression-suite-design.md.

Prerequisites (WSL Ubuntu): samtools 1.19 or later, podman with the
docker.io/muefab/genie image, sra-tools (tools/install_sra_tools.sh),
/usr/bin/time, the project venv with pyyaml, psims and pynumpress.

    export TTIO_BENCH_DATA=$HOME/ttio-bench-data
    PY=python/.venv/bin/python
    $PY tools/perf/compression_suite/suite.py fetch
    $PY tools/perf/compression_suite/suite.py prepare
    $PY tools/perf/compression_suite/suite.py encode --smoke
    $PY tools/perf/compression_suite/suite.py encode
    $PY tools/perf/compression_suite/suite.py report

Stages are idempotent: a result JSON is reused when its input sha256
and tool version are unchanged. Every format encodes the whole corpus
file; the TTI-O importers and exporters stream, so nothing is sharded.
