# tools/perf/compression_suite/common.py
"""Shared helpers for the compression benchmark suite."""
from __future__ import annotations

import hashlib
import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

import yaml


@dataclass
class Corpus:
    id: str
    tier: str            # aligned | unaligned | ms
    source: str          # URL, sra:<accession>, or file:///path
    sha256: str | None
    reference: str | None
    notes: str = ""


@dataclass
class Timed:
    wall_s: float
    peak_rss_mb: float
    returncode: int


def load_manifest(path: Path) -> list[Corpus]:
    doc = yaml.safe_load(Path(path).read_text())
    out = []
    for c in doc["corpora"]:
        out.append(Corpus(id=c["id"], tier=c["tier"], source=c["source"],
                          sha256=c.get("sha256"), reference=c.get("reference"),
                          notes=c.get("notes", "")))
    return out


def data_dir() -> Path:
    return Path(os.environ.get("TTIO_BENCH_DATA",
                               str(Path.home() / "ttio-bench-data")))


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for blk in iter(lambda: f.read(1 << 24), b""):
            h.update(blk)
    return h.hexdigest()


_WALL = re.compile(r"Elapsed \(wall clock\).*?: (?:(\d+):)?(\d+):(\d+(?:\.\d+)?)")
_RSS = re.compile(r"Maximum resident set size \(kbytes\): (\d+)")


def run_timed(cmd: list[str], cwd=None, stdout=None, env=None) -> Timed:
    """Run cmd under /usr/bin/time -v; return wall seconds and peak RSS MB."""
    p = subprocess.run(["/usr/bin/time", "-v", *cmd], cwd=cwd, stdout=stdout,
                       stderr=subprocess.PIPE, text=True, env=env)
    err = p.stderr
    m = _WALL.search(err)
    if not m:
        raise RuntimeError(f"time -v output not parsed:\n{err[-2000:]}")
    h, mnt, s = m.groups()
    wall = (int(h) if h else 0) * 3600 + int(mnt) * 60 + float(s)
    r = _RSS.search(err)
    rss_mb = int(r.group(1)) / 1024.0 if r else 0.0
    if p.returncode != 0:
        tail = "\n".join(l for l in err.splitlines()
                         if not l.startswith("\t"))[-3000:]
        raise RuntimeError(f"command failed rc={p.returncode}: {cmd}\n{tail}")
    return Timed(wall_s=wall, peak_rss_mb=rss_mb, returncode=p.returncode)


def tool_version(cmd: list[str]) -> str:
    p = subprocess.run(cmd, capture_output=True, text=True)
    return ((p.stdout or p.stderr).strip().splitlines() or ["unknown"])[0]
