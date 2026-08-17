# tools/perf/compression_suite/verify.py
"""Normalised digests so every format is compared on identical information."""
from __future__ import annotations

import gzip
import hashlib
import subprocess
from pathlib import Path

import numpy as np


def _open_text(path: Path):
    return gzip.open(path, "rt") if str(path).endswith(".gz") else open(path, "rt")


def sam11_md5(path: Path) -> str:
    """md5 over SAM columns 1-11 of every record, order-independent."""
    p = subprocess.run(["samtools", "view", str(path)], capture_output=True, text=True, check=True)
    rows = []
    for line in p.stdout.splitlines():
        c = line.split("\t", 11)[:11]
        rows.append("\t".join(c))
    rows.sort()
    h = hashlib.md5()
    for r in rows:
        h.update(r.encode()); h.update(b"\n")
    return h.hexdigest()


def fastq_md5(path: Path) -> str:
    """md5 over sorted (name, seq, qual) triples; name is cut at the first space."""
    triples = []
    with _open_text(path) as f:
        while True:
            name = f.readline()
            if not name:
                break
            seq = f.readline().rstrip("\n"); f.readline(); qual = f.readline().rstrip("\n")
            triples.append(name[1:].split()[0] + "\t" + seq + "\t" + qual)
    triples.sort()
    h = hashlib.md5()
    for t in triples:
        h.update(t.encode()); h.update(b"\n")
    return h.hexdigest()


def _iter_mzml(path: Path):
    from pyteomics import mzml as _mzml
    with _mzml.MzML(str(path)) as reader:
        for sp in reader:
            yield (sp["id"],
                   np.ascontiguousarray(sp["m/z array"], dtype="<f8"),
                   np.ascontiguousarray(sp["intensity array"], dtype="<f8"))


def mzml_arrays_md5(path: Path) -> str:
    """Digest of every spectrum's m/z and intensity arrays as float64
    in file order. Spectrum ids are not part of the digest: the check
    is the arrays (spec section 6), and the TTI-O exporter renumbers
    ids as scan=1..n."""
    h = hashlib.md5()
    for _sid, mz, it in _iter_mzml(path):
        h.update(len(mz).to_bytes(8, "little")); h.update(mz.tobytes()); h.update(it.tobytes())
    return h.hexdigest()


def mzml_max_rel_error(a: Path, b: Path) -> float:
    worst = 0.0
    for (ia, mza, ita), (ib, mzb, itb) in zip(_iter_mzml(a), _iter_mzml(b)):
        if len(mza) != len(mzb):
            return float("inf")
        for x, y in ((mza, mzb), (ita, itb)):
            den = np.maximum(np.abs(x), 1e-300)
            worst = max(worst, float(np.max(np.abs(x - y) / den)) if len(x) else 0.0)
    return worst
