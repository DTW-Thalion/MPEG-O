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


def _sam11_lines(path: Path) -> list[str]:
    p = subprocess.run(["samtools", "view", str(path)], capture_output=True, text=True, check=True)
    rows = []
    for line in p.stdout.splitlines():
        c = line.split("\t", 11)[:11]
        rows.append("\t".join(c))
    rows.sort()
    return rows


def sam11_md5(path: Path) -> str:
    """md5 over SAM columns 1-11 of every record, order-independent."""
    rows = _sam11_lines(path)
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


_SAM11_COLS = ["QNAME", "FLAG", "RNAME", "POS", "MAPQ", "CIGAR", "RNEXT", "PNEXT", "TLEN", "SEQ", "QUAL"]


def sam11_diff_summary(a: Path, b: Path) -> str:
    """One line naming how the 11-column projection of ``b`` differs
    from ``a``: records only in one file, and, for the records with the
    same QNAME and mate flag on both sides, which columns differ. Empty
    string when equal. Used to annotate a verify FAIL, never to pass one."""
    def rows(p):
        out = {}
        for line in _sam11_lines(p):
            f = line.split("\t")
            key = (f[0], int(f[1]) & 0xC0, f[2], f[3])
            out.setdefault(key, []).append(f)
        return out
    ra, rb = rows(a), rows(b)
    if ra == rb:
        return ""
    only_a = sum(len(v) for k, v in ra.items() if k not in rb)
    only_b = sum(len(v) for k, v in rb.items() if k not in ra)
    cols: dict[str, int] = {}
    for k, va in ra.items():
        vb = rb.get(k)
        if vb is None:
            continue
        for fa, fb in zip(sorted(va), sorted(vb)):
            for i, name in enumerate(_SAM11_COLS):
                if fa[i] != fb[i]:
                    if name == "FLAG":
                        name = "FLAG(0x%x)" % (int(fa[i]) ^ int(fb[i]))
                    cols[name] = cols.get(name, 0) + 1
    parts = []
    if only_a:
        parts.append(f"{only_a} records missing from output")
    if only_b:
        parts.append(f"{only_b} records added in output")
    if cols:
        parts.append("columns differing: " + ", ".join(f"{k} in {v}" for k, v in sorted(cols.items())))
    return "; ".join(parts)
