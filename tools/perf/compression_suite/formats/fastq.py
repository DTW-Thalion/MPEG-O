# tools/perf/compression_suite/formats/fastq.py
"""FASTQ.gz level 6 baseline."""
from __future__ import annotations

import subprocess
from pathlib import Path

from formats import register
import common


class _FastqGz:
    key, tier, lossy = "fastq_gz", "unaligned", False

    def encode(self, inp: Path, out_dir: Path, ref: Path | None) -> Path:
        out = out_dir / f"{inp.name}.gz"
        with open(inp, "rb") as fi, open(out, "wb") as fo:
            subprocess.run(["gzip", "-6", "-c"], stdin=fi, stdout=fo, check=True)
        return out

    def decode(self, enc: Path, out_dir: Path, ref: Path | None) -> Path:
        out = out_dir / f"{enc.name}.decoded.fastq"
        with open(out, "wb") as fo:
            subprocess.run(["gzip", "-dc", str(enc)], stdout=fo, check=True)
        return out

    def version(self) -> str:
        return common.tool_version(["gzip", "--version"])


register(_FastqGz())
