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


_MOD = 1 << 128


def _multiset_digest(items) -> str:
    """Order-independent digest of a stream of byte strings in constant
    memory: the sum of every item's md5 (as a 128-bit integer) modulo
    2**128, followed by the item count. Equal multisets give equal
    digests; a 130 GB SAM never has to be held or sorted in memory."""
    total = 0
    n = 0
    for it in items:
        total = (total + int.from_bytes(hashlib.md5(it).digest(), "little")) % _MOD
        n += 1
    return f"{total:032x}-{n}"


def _sam11_records(path: Path):
    """SAM columns 1-11 of every record, streamed from samtools view."""
    with subprocess.Popen(["samtools", "view", str(path)], stdout=subprocess.PIPE) as p:
        assert p.stdout is not None
        for line in p.stdout:
            c = line.rstrip(b"\n").split(b"\t", 11)[:11]
            yield b"\t".join(c)
        if p.wait() != 0:
            raise RuntimeError(f"samtools view failed on {path}")


def _sam11_lines(path: Path) -> list[str]:
    """Every 11-column record, sorted, in memory: only for the diff
    summary of small files (see sam11_diff_summary)."""
    rows = [r.decode() for r in _sam11_records(path)]
    rows.sort()
    return rows


def sam11_md5(path: Path) -> str:
    """Digest over SAM columns 1-11 of every record, order-independent
    (see _multiset_digest)."""
    return _multiset_digest(_sam11_records(path))


def _fastq_triples(path: Path):
    opener = gzip.open if str(path).endswith(".gz") else open
    with opener(path, "rb") as f:
        while True:
            name = f.readline()
            if not name:
                break
            seq = f.readline().rstrip(b"\n"); f.readline(); qual = f.readline().rstrip(b"\n")
            yield name[1:].split()[0] + b"\t" + seq + b"\t" + qual


def fastq_md5(path: Path) -> str:
    """Digest over (name, seq, qual) triples, order-independent; the
    name is cut at the first space."""
    return _multiset_digest(_fastq_triples(path))


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


DIFF_SUMMARY_MAX_BYTES = 2 * 1024 ** 3
_SAM11_COLS = ["QNAME", "FLAG", "RNAME", "POS", "MAPQ", "CIGAR", "RNEXT", "PNEXT", "TLEN", "SEQ", "QUAL"]


def sam11_diff_summary(a: Path, b: Path) -> str:
    """One line naming how the 11-column projection of ``b`` differs
    from ``a``: records only in one file, and, for the records with the
    same QNAME and mate flag on both sides, which columns differ. Empty
    string when equal. Used to annotate a verify FAIL, never to pass one."""
    if a.stat().st_size > DIFF_SUMMARY_MAX_BYTES or b.stat().st_size > DIFF_SUMMARY_MAX_BYTES:
        return "decode differs from input (diff summary skipped: input larger than 2 GB)"
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
