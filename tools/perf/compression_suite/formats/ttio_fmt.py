# tools/perf/compression_suite/formats/ttio_fmt.py
"""TTI-O via the ttio CLI: encode = ttio encode, decode = ttio export."""
from __future__ import annotations

import os
import subprocess
from pathlib import Path

import h5py

from formats import register
import common

TTIO_CLI = os.environ.get("TTIO_CLI", "/home/toddw/TTI-O/python/.venv/bin/ttio")


def layer_name(tio: Path, tier: str) -> str:
    with h5py.File(tio, "r") as f:
        group = "study/genomic_runs" if tier in ("aligned", "unaligned") else "study/ms_runs"
        names = sorted(f[group].keys())
        if not names:
            raise RuntimeError(f"{tio}: no runs under {group}")
        return names[0]


class _Ttio:
    lossy = False

    def __init__(self, key: str, tier: str, in_fmt: str, out_fmt: str, out_ext: str):
        self.key, self.tier, self.in_fmt, self.out_fmt, self.out_ext = key, tier, in_fmt, out_fmt, out_ext

    def encode(self, inp: Path, out_dir: Path, ref: Path | None) -> Path:
        out = out_dir / f"{inp.name}.{self.key}.tio"
        if out.exists():
            out.unlink()
        subprocess.run([TTIO_CLI, "encode", "--input", str(inp), "--format", self.in_fmt,
                        "--output", str(out)], check=True)
        return out

    def decode(self, enc: Path, out_dir: Path, ref: Path | None) -> Path:
        out = out_dir / f"{enc.name}.decoded{self.out_ext}"
        if out.exists():
            out.unlink()
        subprocess.run([TTIO_CLI, "export", "--input", str(enc), "--layer",
                        layer_name(enc, self.tier), "--format", self.out_fmt,
                        "--output", str(out)], check=True)
        return out

    def version(self) -> str:
        return common.tool_version([TTIO_CLI, "--version"])


register(_Ttio("ttio", "aligned", "bam", "bam", ".bam"))
register(_Ttio("ttio_fastq", "unaligned", "fastq", "fastq", ".fastq"))
register(_Ttio("ttio_mzml", "ms", "mzml", "mzml", ".mzML"))
