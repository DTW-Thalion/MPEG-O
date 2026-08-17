# Compression Benchmark Suite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A rerunnable suite under `tools/perf/compression_suite/` that measures whole real datasets (GIAB/1000G BAMs, NCBI SRA runs, PRIDE mzML) as TTI-O vs CRAM 3.0/3.1 vs MPEG-G (genie) and vs mzML.gz/numpress, decode-verifies every size, and renders a committed `REPORT.md`.

**Architecture:** A manifest (`manifest.yaml`) names corpora by accession + sha256. `suite.py` runs four idempotent stages (`fetch`, `prepare`, `encode`, `report`); each format family is one module with `encode / decode / version`; `verify.py` reduces any decoded output to a normalised md5 so formats are compared on identical information; `report.py` turns per-corpus JSON results into tables. Every format encodes the whole file: since v1.9 the TTI-O importers and exporters stream (blocks_v1 layout), so no input is sharded.

**Tech Stack:** Python 3.12 (project venv at `python/.venv`), PyYAML, samtools 1.19.2 (CRAM 3.0/3.1), podman image `docker.io/muefab/genie` (MPEG-G reference software), sra-tools (`prefetch`, `fasterq-dump`), psims + pynumpress (mzML writing), `/usr/bin/time -v`, `ttio encode` / `ttio export` (TTI-O CLI).

**Spec:** `docs/superpowers/specs/2026-08-16-compression-suite-design.md`

## Global Constraints

- All commands run in WSL Ubuntu at `/home/toddw/TTI-O`; Python is `/home/toddw/TTI-O/python/.venv/bin/python` (`PY` below). Never the Store stub.
- Bench data lives outside the repo at `$TTIO_BENCH_DATA` (default `/home/toddw/ttio-bench-data`) with `raw/`, `prepared/`, `out/`.
- Primary aligned comparison is on 11-column BAMs (SAM cols 1-11, header kept); full-tag CRAM/MPEG-G is a secondary column. TTI-O is never run on full-tag input.
- Every size counted in the report has a passing decode-verify; a failed verify is `verify: FAIL` with no size.
- Threads = 1 for size runs (`samtools -@ 1`, genie `--threads 1`).
- Whole files, no shards: every format encodes the corpus file as one input (mzML runs are chosen at 1-4 GB each). Peak RSS of the TTI-O rows is a measured result, not a constraint.
- Nothing in this suite runs in CI. `results/` and `REPORT.md` are committed; data is not.
- Public text (README, REPORT, commit messages): plain statements of fact, digits for numbers, no em dashes, no bullets in commit messages.

---

### Task 1: Scaffold, manifest loader, timed runner

**Files:**
- Create: `tools/perf/compression_suite/__init__.py` (empty)
- Create: `tools/perf/compression_suite/README.md`
- Create: `tools/perf/compression_suite/manifest.yaml`
- Create: `tools/perf/compression_suite/common.py`
- Create: `tools/perf/compression_suite/suite.py`
- Test: `tools/perf/compression_suite/tests/test_common.py`

**Interfaces:**
- Produces: `common.load_manifest(path) -> list[Corpus]` where `Corpus` is a dataclass `(id: str, tier: str, source: str, sha256: str | None, reference: str | None, notes: str)`.
- Produces: `common.run_timed(cmd: list[str], cwd=None, stdout=None) -> Timed` with `Timed(wall_s: float, peak_rss_mb: float, returncode: int)`; runs `/usr/bin/time -v` around `cmd`, parses `Elapsed (wall clock)` and `Maximum resident set size`.
- Produces: `common.sha256_of(path) -> str`, `common.data_dir() -> Path` (from `TTIO_BENCH_DATA`), `common.tool_version(cmd: list[str]) -> str` (first line of stdout+stderr).

- [ ] **Step 1: Write the failing tests**

```python
# tools/perf/compression_suite/tests/test_common.py
import os, sys, textwrap
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import common  # noqa: E402


def test_load_manifest_reads_fields(tmp_path):
    m = tmp_path / "manifest.yaml"
    m.write_text(textwrap.dedent("""
        corpora:
          - id: toy_bam
            tier: aligned
            source: file:///x/toy.bam
            sha256: null
            reference: file:///x/ref.fa
            notes: toy
    """))
    corpora = common.load_manifest(m)
    assert [c.id for c in corpora] == ["toy_bam"]
    assert corpora[0].tier == "aligned"
    assert corpora[0].reference == "file:///x/ref.fa"


def test_run_timed_reports_wall_and_rss():
    t = common.run_timed(["sh", "-c", "python3 -c 'x=bytearray(50_000_000)'"])
    assert t.returncode == 0
    assert t.wall_s >= 0.0
    assert t.peak_rss_mb > 40


def test_sha256_of(tmp_path):
    p = tmp_path / "f"; p.write_bytes(b"abc")
    assert common.sha256_of(p) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"


def test_data_dir_env(monkeypatch, tmp_path):
    monkeypatch.setenv("TTIO_BENCH_DATA", str(tmp_path))
    assert common.data_dir() == tmp_path
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /home/toddw/TTI-O && python/.venv/bin/python -m pytest tools/perf/compression_suite/tests/test_common.py -q`
Expected: FAIL (`No module named 'common'`).

- [ ] **Step 3: Implement common.py**

```python
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
```

- [ ] **Step 4: Write manifest.yaml (on-disk corpora now; fetched ones in Task 8)**

```yaml
# tools/perf/compression_suite/manifest.yaml
# Corpora for the compression benchmark suite. sha256 is filled by
# `suite.py fetch` on first fetch and enforced afterwards. Sizes and
# accessions for the fetched corpora are recorded by Task 8.
corpora:
  - id: na12878_chr22_lowcov
    tier: aligned
    source: file:///home/toddw/TTI-O/data/genomic/na12878/na12878.chr22.lean.mapped.bam
    sha256: null
    reference: file:///home/toddw/TTI-O/data/genomic/reference/hs37.chr22.fa
    notes: 1000 Genomes NA12878 low coverage, chr22 slice (hs37)
  - id: na12878_wes_chr22
    tier: aligned
    source: file:///home/toddw/TTI-O/data/genomic/na12878_wes/na12878_wes.chr22.bam
    sha256: null
    reference: file:///home/toddw/TTI-O/data/genomic/reference/hg19.chr22.fa
    notes: NIST NA12878 WES, chr22 slice (hg19)
  - id: hg002_2x250_chr22
    tier: aligned
    source: file:///home/toddw/TTI-O/data/genomic/hg002_illumina/hg002_illumina.chr22.bam
    sha256: null
    reference: file:///home/toddw/TTI-O/data/genomic/reference/hg19.chr22.fa
    notes: GIAB HG002 Illumina 2x250, chr22 slice
  - id: hg002_hifi_subset
    tier: aligned
    source: file:///home/toddw/TTI-O/data/genomic/hg002_pacbio/hg002_pacbio.subset.bam
    sha256: null
    reference: null
    notes: GIAB HG002 PacBio HiFi subset; reference resolved in Task 7 from the BAM header
  - id: pxd000001_orbitrap
    tier: ms
    source: file:///tmp/ttio-comp-bench/TMT_Erwinia_1uLSike_Top10HCD_isol2_45stepped_60min_01-20141210.mzML
    sha256: null
    reference: null
    notes: PRIDE PXD000001, Orbitrap Velos, on disk from the compression audit
```

- [ ] **Step 5: Write suite.py skeleton with the four subcommands wired to stubs**

```python
# tools/perf/compression_suite/suite.py
"""Compression benchmark suite driver: fetch | prepare | encode | report."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import common  # noqa: E402


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="suite.py")
    ap.add_argument("--manifest", default=str(HERE / "manifest.yaml"))
    ap.add_argument("--corpus", action="append", default=None,
                    help="restrict to these corpus ids (repeatable)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("fetch")
    sub.add_parser("prepare")
    pe = sub.add_parser("encode")
    pe.add_argument("--formats", default="all",
                    help="comma list of format keys or 'all'")
    pe.add_argument("--smoke", action="store_true",
                    help="on-disk corpora only")
    sub.add_parser("report")
    args = ap.parse_args(argv)
    corpora = common.load_manifest(Path(args.manifest))
    if args.corpus:
        corpora = [c for c in corpora if c.id in set(args.corpus)]
    if args.cmd == "fetch":
        from stages import fetch; return fetch.run(corpora, Path(args.manifest))
    if args.cmd == "prepare":
        from stages import prepare; return prepare.run(corpora)
    if args.cmd == "encode":
        from stages import encode; return encode.run(corpora, args.formats, args.smoke)
    if args.cmd == "report":
        import report; return report.run(HERE / "results", HERE / "REPORT.md")
    return 2


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 6: Write README.md**

```markdown
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
```

- [ ] **Step 7: Install pyyaml/psims/pynumpress into the venv and run tests**

Run: `cd /home/toddw/TTI-O && python/.venv/bin/pip install -q pyyaml psims pynumpress && python/.venv/bin/python -m pytest tools/perf/compression_suite/tests/test_common.py -q`
Expected: 4 passed.

- [ ] **Step 8: Commit**

```bash
git add tools/perf/compression_suite
git commit -F /home/toddw/msg.txt   # subject: "perf: compression suite scaffold, manifest loader, timed runner"
```

---

### Task 2: verify.py normalisers

**Files:**
- Create: `tools/perf/compression_suite/verify.py`
- Test: `tools/perf/compression_suite/tests/test_verify.py`
- Fixtures used: `python/tests/fixtures/genomic/m87_test.bam`, `java/src/test/resources/tiny.pwiz.1.1.mzML`

**Interfaces:**
- Produces: `verify.sam11_md5(bam_or_sam: Path) -> str` (samtools view, project cols 1-11, sort by (qname, flag, rname, pos), md5 of the joined lines).
- Produces: `verify.fastq_md5(fastq: Path) -> str` (gz or plain; (name-before-first-space, seq, qual) triples sorted, md5).
- Produces: `verify.mzml_arrays_md5(mzml: Path) -> str` (for each spectrum in file order: id, m/z float64 bytes, intensity float64 bytes; md5).
- Produces: `verify.mzml_max_rel_error(a: Path, b: Path) -> float` (max relative deviation between spectra arrays; used only for numpress rows).

- [ ] **Step 1: Write the failing tests**

```python
# tools/perf/compression_suite/tests/test_verify.py
import shutil, subprocess, sys
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify  # noqa: E402

REPO = Path(__file__).resolve().parents[4]
BAM = REPO / "python/tests/fixtures/genomic/m87_test.bam"
MZML = REPO / "java/src/test/resources/tiny.pwiz.1.1.mzML"
samtools = shutil.which("samtools")


@pytest.mark.skipif(samtools is None, reason="samtools missing")
def test_sam11_md5_ignores_aux_tags_and_order(tmp_path):
    a = verify.sam11_md5(BAM)
    # Reorder records and strip tags: md5 must be identical.
    sam = tmp_path / "shuffled.sam"
    hdr = subprocess.run([samtools, "view", "-H", str(BAM)], capture_output=True, text=True).stdout
    body = subprocess.run([samtools, "view", str(BAM)], capture_output=True, text=True).stdout.splitlines()
    body = ["\t".join(l.split("\t")[:11]) for l in reversed(body)]
    sam.write_text(hdr + "\n".join(body) + "\n")
    assert verify.sam11_md5(sam) == a


@pytest.mark.skipif(samtools is None, reason="samtools missing")
def test_sam11_md5_changes_when_a_base_changes(tmp_path):
    body = subprocess.run([samtools, "view", str(BAM)], capture_output=True, text=True).stdout.splitlines()
    hdr = subprocess.run([samtools, "view", "-H", str(BAM)], capture_output=True, text=True).stdout
    cols = body[0].split("\t"); cols[9] = ("A" if cols[9][0] != "A" else "C") + cols[9][1:]
    body[0] = "\t".join(cols)
    sam = tmp_path / "mut.sam"; sam.write_text(hdr + "\n".join(body) + "\n")
    assert verify.sam11_md5(sam) != verify.sam11_md5(BAM)


def test_fastq_md5_gz_and_plain_agree(tmp_path):
    import gzip
    txt = "@r1 extra\nACGT\n+\nIIII\n@r2\nGGCC\n+\n!!!!\n"
    p = tmp_path / "a.fastq"; p.write_text(txt)
    g = tmp_path / "a.fastq.gz"
    with gzip.open(g, "wt") as f: f.write(txt.replace("@r1 extra", "@r1"))
    assert verify.fastq_md5(p) == verify.fastq_md5(g)


def test_mzml_arrays_md5_stable_and_sensitive(tmp_path):
    a = verify.mzml_arrays_md5(MZML)
    assert a == verify.mzml_arrays_md5(MZML)
    assert verify.mzml_max_rel_error(MZML, MZML) == 0.0
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /home/toddw/TTI-O && python/.venv/bin/python -m pytest tools/perf/compression_suite/tests/test_verify.py -q`
Expected: FAIL (`No module named 'verify'`).

- [ ] **Step 3: Implement verify.py**

```python
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
    h = hashlib.md5()
    for sid, mz, it in _iter_mzml(path):
        h.update(sid.encode()); h.update(mz.tobytes()); h.update(it.tobytes())
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
```

- [ ] **Step 4: Install pyteomics and run tests**

Run: `cd /home/toddw/TTI-O && python/.venv/bin/pip install -q pyteomics lxml && python/.venv/bin/python -m pytest tools/perf/compression_suite/tests/test_verify.py -q`
Expected: 4 passed.

- [ ] **Step 5: Commit**

```bash
git add tools/perf/compression_suite/verify.py tools/perf/compression_suite/tests/test_verify.py
git commit -F /home/toddw/msg.txt   # subject: "perf: normalised digests for SAM, FASTQ and mzML verification"
```

---

### Task 3: Format module protocol + BAM/CRAM

**Files:**
- Create: `tools/perf/compression_suite/formats/__init__.py`
- Create: `tools/perf/compression_suite/formats/bam_cram.py`
- Test: `tools/perf/compression_suite/tests/test_bam_cram.py`

**Interfaces:**
- Produces: `formats.Format` protocol: attributes `key: str`, `tier: str`, `lossy: bool`; methods `encode(inp: Path, out_dir: Path, ref: Path | None) -> Path`, `decode(enc: Path, out_dir: Path, ref: Path | None) -> Path`, `version() -> str`. Every `encode`/`decode` returns the produced file path.
- Produces: `formats.REGISTRY: dict[str, Format]` filled by each module at import; keys used everywhere: `bam`, `cram30`, `cram31_normal`, `cram31_small`, `cram31_archive`, `mpegg`, `ttio`, `fastq_gz`, `cram31_small_unaligned`, `mpegg_unaligned`, `ttio_fastq`, `mzml_gz`, `mzml_numpress_gz`, `ttio_mzml`.
- Produces: `formats.load_all()` imports every module so the registry is complete.

- [ ] **Step 1: Write the failing test**

```python
# tools/perf/compression_suite/tests/test_bam_cram.py
import shutil, sys
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import formats, verify  # noqa: E402
from formats import bam_cram  # noqa: E402,F401

REPO = Path(__file__).resolve().parents[4]
BAM = REPO / "python/tests/fixtures/genomic/m87_test.bam"
pytestmark = pytest.mark.skipif(shutil.which("samtools") is None, reason="samtools missing")


@pytest.mark.parametrize("key", ["bam", "cram30", "cram31_normal", "cram31_small", "cram31_archive"])
def test_round_trip_preserves_sam11(key, tmp_path):
    fmt = formats.REGISTRY[key]
    ref = REPO / "python/tests/fixtures/genomic/m87_ref.fa"
    if not ref.exists():
        pytest.skip("m87 reference not present; Task 3 step 3 generates it")
    enc = fmt.encode(BAM, tmp_path, ref)
    assert enc.exists() and enc.stat().st_size > 0
    dec = fmt.decode(enc, tmp_path, ref)
    assert verify.sam11_md5(dec) == verify.sam11_md5(BAM)
    assert fmt.version().startswith("samtools")
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /home/toddw/TTI-O && python/.venv/bin/python -m pytest tools/perf/compression_suite/tests/test_bam_cram.py -q`
Expected: FAIL (`No module named 'formats'`).

- [ ] **Step 3: Check the m87 fixture's reference; generate one if absent**

Run: `cd /home/toddw/TTI-O && ls python/tests/fixtures/genomic/ | grep -i "fa$\|fasta"; samtools view -H python/tests/fixtures/genomic/m87_test.bam | grep "^@SQ"`
If no FASTA exists for the fixture's contigs, write `python/tests/fixtures/genomic/m87_ref.fa` from the `@SQ` lengths with a deterministic random sequence (`python3 - <<EOF` using `random.Random(87)`), and `samtools faidx` it. CRAM with a mismatched reference still round-trips (bases are stored as differences), so any consistent FASTA works for the test.

- [ ] **Step 4: Implement formats/__init__.py and bam_cram.py**

```python
# tools/perf/compression_suite/formats/__init__.py
"""Format modules. Each registers Format objects into REGISTRY at import."""
from __future__ import annotations

import importlib
from pathlib import Path
from typing import Protocol


class Format(Protocol):
    key: str
    tier: str          # aligned | unaligned | ms
    lossy: bool
    def encode(self, inp: Path, out_dir: Path, ref: Path | None) -> Path: ...
    def decode(self, enc: Path, out_dir: Path, ref: Path | None) -> Path: ...
    def version(self) -> str: ...


REGISTRY: dict[str, Format] = {}


def register(fmt: Format) -> Format:
    REGISTRY[fmt.key] = fmt
    return fmt


def load_all() -> dict[str, Format]:
    for mod in ("bam_cram", "mpegg", "ttio_fmt", "fastq", "mzml"):
        importlib.import_module(f"formats.{mod}")
    return REGISTRY
```

```python
# tools/perf/compression_suite/formats/bam_cram.py
"""BAM baseline and CRAM 3.0 / 3.1 profiles via samtools."""
from __future__ import annotations

import subprocess
from pathlib import Path

from formats import register
import common


def _sam(*args) -> None:
    subprocess.run(["samtools", *args], check=True)


class _SamtoolsFormat:
    tier = "aligned"
    lossy = False

    def __init__(self, key: str, out_opts: str, ext: str):
        self.key, self.out_opts, self.ext = key, out_opts, ext

    def encode(self, inp: Path, out_dir: Path, ref: Path | None) -> Path:
        out = out_dir / f"{inp.stem}.{self.key}{self.ext}"
        args = ["view", "-@", "1", "-O", self.out_opts]
        if ref is not None and self.ext == ".cram":
            args += ["-T", str(ref)]
        _sam(*args, "-o", str(out), str(inp))
        return out

    def decode(self, enc: Path, out_dir: Path, ref: Path | None) -> Path:
        out = out_dir / f"{enc.name}.decoded.bam"
        args = ["view", "-@", "1", "-b"]
        if ref is not None and enc.suffix == ".cram":
            args += ["-T", str(ref)]
        _sam(*args, "-o", str(out), str(enc))
        return out

    def version(self) -> str:
        return common.tool_version(["samtools", "--version"])


register(_SamtoolsFormat("bam", "bam", ".bam"))
register(_SamtoolsFormat("cram30", "cram,version=3.0", ".cram"))
register(_SamtoolsFormat("cram31_normal", "cram,version=3.1", ".cram"))
register(_SamtoolsFormat("cram31_small", "cram,version=3.1,small", ".cram"))
register(_SamtoolsFormat("cram31_archive", "cram,version=3.1,archive", ".cram"))


class _UnalignedCram(_SamtoolsFormat):
    """CRAM 3.1 small on unaligned reads: FASTQ -> unaligned BAM -> CRAM."""
    tier = "unaligned"

    def encode(self, inp: Path, out_dir: Path, ref: Path | None) -> Path:
        ubam = out_dir / f"{inp.name}.ubam"
        subprocess.run(["samtools", "import", "-@", "1", "-0", str(inp), "-o", str(ubam)], check=True)
        out = out_dir / f"{inp.name}.{self.key}.cram"
        _sam("view", "-@", "1", "-O", self.out_opts, "-o", str(out), str(ubam))
        ubam.unlink()
        return out

    def decode(self, enc: Path, out_dir: Path, ref: Path | None) -> Path:
        out = out_dir / f"{enc.name}.decoded.fastq"
        with open(out, "w") as f:
            subprocess.run(["samtools", "fastq", "-@", "1", str(enc)], stdout=f, check=True)
        return out


register(_UnalignedCram("cram31_small_unaligned", "cram,version=3.1,small", ".cram"))
```

- [ ] **Step 5: Run tests**

Run: `cd /home/toddw/TTI-O && python/.venv/bin/python -m pytest tools/perf/compression_suite/tests/test_bam_cram.py -q`
Expected: 5 passed.

- [ ] **Step 6: Commit**

```bash
git add tools/perf/compression_suite/formats python/tests/fixtures/genomic/m87_ref.fa* tools/perf/compression_suite/tests/test_bam_cram.py
git commit -F /home/toddw/msg.txt   # subject: "perf: format registry and samtools BAM/CRAM encoders"
```

---

### Task 4: TTI-O format module

**Files:**
- Create: `tools/perf/compression_suite/formats/ttio_fmt.py`
- Test: `tools/perf/compression_suite/tests/test_ttio_fmt.py`

**Interfaces:**
- Consumes: `formats.register`, `common.tool_version`.
- Produces: registry keys `ttio` (aligned; encode `--format bam`, decode `--format bam` via `ttio export`), `ttio_fastq` (unaligned; `--format fastq` both ways), `ttio_mzml` (ms; encode `--format mzml`, decode `--format mzml`).
- Produces: `ttio_fmt.TTIO_CLI` = `/home/toddw/TTI-O/python/.venv/bin/ttio` (overridable by env `TTIO_CLI`).
- Produces: `ttio_fmt.layer_name(tio: Path, tier: str) -> str` (first genomic run name or first MS run name from the container, via `h5py`).

- [ ] **Step 1: Write the failing test**

```python
# tools/perf/compression_suite/tests/test_ttio_fmt.py
import shutil, sys
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import formats, verify  # noqa: E402
from formats import ttio_fmt  # noqa: E402,F401

REPO = Path(__file__).resolve().parents[4]
BAM = REPO / "python/tests/fixtures/genomic/m87_test.bam"
MZML = REPO / "java/src/test/resources/tiny.pwiz.1.1.mzML"


@pytest.mark.skipif(shutil.which("samtools") is None, reason="samtools missing")
def test_ttio_bam_round_trip(tmp_path):
    fmt = formats.REGISTRY["ttio"]
    enc = fmt.encode(BAM, tmp_path, None)
    assert enc.suffix == ".tio" and enc.stat().st_size > 0
    dec = fmt.decode(enc, tmp_path, None)
    assert verify.sam11_md5(dec) == verify.sam11_md5(BAM)
    assert "ttio" in fmt.version()


def test_ttio_mzml_round_trip(tmp_path):
    fmt = formats.REGISTRY["ttio_mzml"]
    enc = fmt.encode(MZML, tmp_path, None)
    dec = fmt.decode(enc, tmp_path, None)
    assert verify.mzml_arrays_md5(dec) == verify.mzml_arrays_md5(MZML)


def test_ttio_fastq_round_trip(tmp_path):
    p = tmp_path / "in.fastq"
    p.write_text("@r1\nACGTACGT\n+\nIIIIIIII\n@r2\nGGCCAATT\n+\n!!!!####\n")
    fmt = formats.REGISTRY["ttio_fastq"]
    enc = fmt.encode(p, tmp_path, None)
    dec = fmt.decode(enc, tmp_path, None)
    assert verify.fastq_md5(dec) == verify.fastq_md5(p)
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /home/toddw/TTI-O && python/.venv/bin/python -m pytest tools/perf/compression_suite/tests/test_ttio_fmt.py -q`
Expected: FAIL (`No module named 'formats.ttio_fmt'`).

- [ ] **Step 3: Implement ttio_fmt.py**

```python
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
        group = "genomic_runs" if tier in ("aligned", "unaligned") else "acquisition_runs"
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
```

- [ ] **Step 4: Run tests; fix the group names if the container layout differs**

Run: `cd /home/toddw/TTI-O && python/.venv/bin/python -m pytest tools/perf/compression_suite/tests/test_ttio_fmt.py -q`
If `layer_name` raises KeyError, list the container: `python/.venv/bin/python -c "import h5py,sys; h5py.File(sys.argv[1]).visit(print)" <tio>` and set the two group names to what the writer uses. Expected after fix: 3 passed.

- [ ] **Step 5: Commit**

```bash
git add tools/perf/compression_suite/formats/ttio_fmt.py tools/perf/compression_suite/tests/test_ttio_fmt.py
git commit -F /home/toddw/msg.txt   # subject: "perf: TTI-O encode/export format module"
```

---

### Task 5: MPEG-G via genie (podman)

**Files:**
- Create: `tools/perf/compression_suite/formats/mpegg.py`
- Create: `tools/perf/compression_suite/tools/genie_image.txt` (pinned image reference incl. digest)
- Test: `tools/perf/compression_suite/tests/test_mpegg.py`

**Interfaces:**
- Consumes: `formats.register`.
- Produces: keys `mpegg` (aligned, reference-based when `ref` given), `mpegg_unaligned` (FASTQ in/out).
- Produces: `mpegg.GENIE_IMAGE` read from `tools/genie_image.txt`; `mpegg.genie(args: list[str], mounts: list[Path]) -> None` runs `podman run --rm -v <dir>:<dir>:Z ... GENIE_IMAGE genie <args>`.

- [ ] **Step 1: Pull the image and pin it**

Run: `podman pull docker.io/muefab/genie:latest && podman image inspect docker.io/muefab/genie:latest --format '{{.Digest}}'`
Write `tools/perf/compression_suite/tools/genie_image.txt` containing `docker.io/muefab/genie@sha256:<digest>` (one line). Then confirm the CLI: `podman run --rm docker.io/muefab/genie:latest genie run --help | head -60` and record the flag names for input, output, reference and threads (expected `-i`, `-o`, `-r`, `-t`/`--threads`; adjust the code below to the printed names).

- [ ] **Step 2: Write the failing test**

```python
# tools/perf/compression_suite/tests/test_mpegg.py
import shutil, sys
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import formats, verify  # noqa: E402
from formats import mpegg  # noqa: E402,F401

REPO = Path(__file__).resolve().parents[4]
BAM = REPO / "python/tests/fixtures/genomic/m87_test.bam"
REF = REPO / "python/tests/fixtures/genomic/m87_ref.fa"
pytestmark = pytest.mark.skipif(shutil.which("podman") is None or shutil.which("samtools") is None,
                                reason="podman/samtools missing")


def test_mpegg_aligned_round_trip(tmp_path):
    fmt = formats.REGISTRY["mpegg"]
    enc = fmt.encode(BAM, tmp_path, REF)
    assert enc.suffix == ".mgb" and enc.stat().st_size > 0
    dec = fmt.decode(enc, tmp_path, REF)
    assert verify.sam11_md5(dec) == verify.sam11_md5(BAM)
    assert "genie" in fmt.version().lower()


def test_mpegg_unaligned_round_trip(tmp_path):
    p = tmp_path / "in.fastq"
    p.write_text("@r1\nACGTACGT\n+\nIIIIIIII\n@r2\nGGCCAATT\n+\n!!!!####\n")
    fmt = formats.REGISTRY["mpegg_unaligned"]
    enc = fmt.encode(p, tmp_path, None)
    dec = fmt.decode(enc, tmp_path, None)
    assert verify.fastq_md5(dec) == verify.fastq_md5(p)
```

- [ ] **Step 3: Run to verify failure**

Run: `cd /home/toddw/TTI-O && python/.venv/bin/python -m pytest tools/perf/compression_suite/tests/test_mpegg.py -q`
Expected: FAIL (`No module named 'formats.mpegg'`).

- [ ] **Step 4: Implement mpegg.py**

```python
# tools/perf/compression_suite/formats/mpegg.py
"""MPEG-G via the genie reference software, run from its container image."""
from __future__ import annotations

import subprocess
from pathlib import Path

from formats import register
import common

HERE = Path(__file__).resolve().parents[1]
GENIE_IMAGE = (HERE / "tools" / "genie_image.txt").read_text().strip()


def genie(args: list[str], mounts: list[Path]) -> None:
    cmd = ["podman", "run", "--rm"]
    for m in sorted({str(p.resolve()) for p in mounts}):
        cmd += ["-v", f"{m}:{m}:Z"]
    cmd += [GENIE_IMAGE, "genie", "run", *args]
    subprocess.run(cmd, check=True)


class _Genie:
    lossy = False

    def __init__(self, key: str, tier: str):
        self.key, self.tier = key, tier

    def encode(self, inp: Path, out_dir: Path, ref: Path | None) -> Path:
        out = out_dir / f"{inp.name}.{self.key}.mgb"
        if out.exists():
            out.unlink()
        # genie reads SAM for aligned input; convert BAM to SAM first.
        src = inp
        if inp.suffix == ".bam":
            src = out_dir / f"{inp.stem}.sam"
            with open(src, "w") as f:
                subprocess.run(["samtools", "view", "-h", str(inp)], stdout=f, check=True)
        args = ["-i", str(src.resolve()), "-o", str(out.resolve()), "--threads", "1"]
        mounts = [inp.parent, out_dir]
        if ref is not None:
            args += ["-r", str(ref.resolve())]; mounts.append(ref.parent)
        genie(args, mounts)
        if src is not inp:
            src.unlink()
        return out

    def decode(self, enc: Path, out_dir: Path, ref: Path | None) -> Path:
        ext = ".sam" if self.tier == "aligned" else ".fastq"
        out = out_dir / f"{enc.name}.decoded{ext}"
        if out.exists():
            out.unlink()
        args = ["-i", str(enc.resolve()), "-o", str(out.resolve()), "--threads", "1"]
        mounts = [enc.parent, out_dir]
        if ref is not None:
            args += ["-r", str(ref.resolve())]; mounts.append(ref.parent)
        genie(args, mounts)
        return out

    def version(self) -> str:
        p = subprocess.run(["podman", "run", "--rm", GENIE_IMAGE, "genie", "--version"],
                           capture_output=True, text=True)
        line = ((p.stdout or p.stderr).strip().splitlines() or ["genie"])[0]
        return f"{line} ({GENIE_IMAGE})"


register(_Genie("mpegg", "aligned"))
register(_Genie("mpegg_unaligned", "unaligned"))
```

- [ ] **Step 5: Run tests; adjust flag names to what `genie run --help` printed in Step 1**

Run: `cd /home/toddw/TTI-O && python/.venv/bin/python -m pytest tools/perf/compression_suite/tests/test_mpegg.py -q`
Expected: 2 passed. If genie rejects `.sam` and wants `.bam`, pass the BAM path directly and drop the conversion; if the reference must be FASTA with `.fai`, run `samtools faidx` on it first.

- [ ] **Step 6: Commit**

```bash
git add tools/perf/compression_suite/formats/mpegg.py tools/perf/compression_suite/tools/genie_image.txt tools/perf/compression_suite/tests/test_mpegg.py
git commit -F /home/toddw/msg.txt   # subject: "perf: MPEG-G encoder via the genie container"
```

---

### Task 6: FASTQ.gz and mzML comparators

**Files:**
- Create: `tools/perf/compression_suite/formats/fastq.py`
- Create: `tools/perf/compression_suite/formats/mzml.py`
- Test: `tools/perf/compression_suite/tests/test_fastq_mzml.py`

**Interfaces:**
- Produces: `fastq_gz` (unaligned; `gzip -6`, decode `gzip -dc`), `mzml_gz` (ms; the mzML re-serialised by psims with zlib arrays, then gzip -6; lossless), `mzml_numpress_gz` (ms; psims with `numpress-linear` m/z and `numpress-slof` intensity, then gzip -6; `lossy = True`).
- Produces: `mzml.rewrite(inp: Path, out: Path, mz_compression: str, it_compression: str) -> None` (pyteomics read, psims write).

- [ ] **Step 1: Write the failing test**

```python
# tools/perf/compression_suite/tests/test_fastq_mzml.py
import sys
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import formats, verify  # noqa: E402
from formats import fastq, mzml  # noqa: E402,F401

REPO = Path(__file__).resolve().parents[4]
MZML = REPO / "java/src/test/resources/tiny.pwiz.1.1.mzML"


def test_fastq_gz_round_trip(tmp_path):
    p = tmp_path / "in.fastq"
    p.write_text("@r1\nACGTACGT\n+\nIIIIIIII\n@r2\nGGCCAATT\n+\n!!!!####\n")
    fmt = formats.REGISTRY["fastq_gz"]
    enc = fmt.encode(p, tmp_path, None)
    assert enc.suffix == ".gz"
    dec = fmt.decode(enc, tmp_path, None)
    assert verify.fastq_md5(dec) == verify.fastq_md5(p)


def test_mzml_gz_lossless(tmp_path):
    fmt = formats.REGISTRY["mzml_gz"]
    enc = fmt.encode(MZML, tmp_path, None)
    dec = fmt.decode(enc, tmp_path, None)
    assert verify.mzml_arrays_md5(dec) == verify.mzml_arrays_md5(MZML)
    assert fmt.lossy is False


def test_mzml_numpress_is_marked_lossy_and_bounded(tmp_path):
    fmt = formats.REGISTRY["mzml_numpress_gz"]
    assert fmt.lossy is True
    enc = fmt.encode(MZML, tmp_path, None)
    dec = fmt.decode(enc, tmp_path, None)
    assert verify.mzml_max_rel_error(MZML, dec) < 1e-3
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /home/toddw/TTI-O && python/.venv/bin/python -m pytest tools/perf/compression_suite/tests/test_fastq_mzml.py -q`
Expected: FAIL (`No module named 'formats.fastq'`).

- [ ] **Step 3: Implement fastq.py and mzml.py**

```python
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
```

```python
# tools/perf/compression_suite/formats/mzml.py
"""mzML comparators: zlib arrays (lossless) and numpress (lossy), gzip -6 outer."""
from __future__ import annotations

import subprocess
from pathlib import Path

from formats import register
import common


def rewrite(inp: Path, out: Path, mz_compression: str, it_compression: str) -> None:
    from psims.mzml import MzMLWriter
    from pyteomics import mzml as pmz
    with pmz.MzML(str(inp)) as reader, MzMLWriter(str(out)) as w:
        w.controlled_vocabularies()
        with w.run(id="run"):
            spectra = list(reader)
            with w.spectrum_list(count=len(spectra)):
                for sp in spectra:
                    ms_level = int(sp.get("ms level", 1))
                    w.write_spectrum(sp["m/z array"], sp["intensity array"],
                                     id=sp["id"], centroided=("centroid spectrum" in sp),
                                     scan_start_time=None,
                                     params=[{"ms level": ms_level}],
                                     compression={"m/z array": mz_compression,
                                                  "intensity array": it_compression})


class _Mzml:
    tier = "ms"

    def __init__(self, key: str, mz_comp: str, it_comp: str, lossy: bool):
        self.key, self.mz_comp, self.it_comp, self.lossy = key, mz_comp, it_comp, lossy

    def encode(self, inp: Path, out_dir: Path, ref: Path | None) -> Path:
        plain = out_dir / f"{inp.stem}.{self.key}.mzML"
        rewrite(inp, plain, self.mz_comp, self.it_comp)
        out = out_dir / f"{plain.name}.gz"
        with open(plain, "rb") as fi, open(out, "wb") as fo:
            subprocess.run(["gzip", "-6", "-c"], stdin=fi, stdout=fo, check=True)
        plain.unlink()
        return out

    def decode(self, enc: Path, out_dir: Path, ref: Path | None) -> Path:
        out = out_dir / f"{enc.name}.decoded.mzML"
        with open(out, "wb") as fo:
            subprocess.run(["gzip", "-dc", str(enc)], stdout=fo, check=True)
        return out

    def version(self) -> str:
        import psims
        return f"psims {psims.__version__}, gzip"


register(_Mzml("mzml_gz", "zlib", "zlib", lossy=False))
register(_Mzml("mzml_numpress_gz", "numpress-linear-zlib", "numpress-slof-zlib", lossy=True))
```

- [ ] **Step 4: Run tests; align psims compression names with what psims registers**

Run: `cd /home/toddw/TTI-O && python/.venv/bin/python -c "import psims.compression as c; print(sorted(c.compression_registry.keys()) if hasattr(c,'compression_registry') else dir(c))"` then the tests. Use the printed names for the two numpress entries. Expected: 3 passed.

- [ ] **Step 5: Commit**

```bash
git add tools/perf/compression_suite/formats/fastq.py tools/perf/compression_suite/formats/mzml.py tools/perf/compression_suite/tests/test_fastq_mzml.py
git commit -F /home/toddw/msg.txt   # subject: "perf: FASTQ.gz and mzML/numpress comparators"
```

---

### Task 7: prepare stage (11-column BAM, references)

**Files:**
- Create: `tools/perf/compression_suite/stages/__init__.py` (empty)
- Create: `tools/perf/compression_suite/stages/prepare.py`
- Test: `tools/perf/compression_suite/tests/test_prepare.py`

**Interfaces:**
- Consumes: `common.Corpus`, `common.data_dir`, `common.sha256_of`.
- Produces: `prepare.run(corpora) -> int` and, per corpus, a `prepared/<id>/plan.json`:
  `{"id", "tier", "input_sha256", "reference": path|null, "inputs": [{"name", "path", "kind": "bam11"|"bam_full"|"fastq"|"mzml"}]}` (an aligned corpus has two inputs, the 11-column BAM and the untouched BAM; the other tiers one).
- Produces: `prepare.eleven_column(bam: Path, out: Path) -> Path` (`samtools view -h | cut -f1-11 | samtools view -b -o out`).
- Produces: `prepare.fastq_plain(fastq_or_gz: Path, out: Path) -> Path` (a gz source is decompressed once so every format starts from the same plain FASTQ).
- Produces: `prepare.reference_for(corpus) -> Path | None` (manifest reference, else the GRCh38/GRCh37 fetched by Task 8 chosen from the BAM's `@SQ` names/lengths).

- [ ] **Step 1: Write the failing tests**

```python
# tools/perf/compression_suite/tests/test_prepare.py
import json, shutil, subprocess, sys
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import common, verify  # noqa: E402
from stages import prepare  # noqa: E402

REPO = Path(__file__).resolve().parents[4]
BAM = REPO / "python/tests/fixtures/genomic/m87_test.bam"
pytestmark = pytest.mark.skipif(shutil.which("samtools") is None, reason="samtools missing")


def test_eleven_column_strips_tags_keeps_header(tmp_path):
    out = prepare.eleven_column(BAM, tmp_path / "x.11col.bam")
    body = subprocess.run(["samtools", "view", str(out)], capture_output=True, text=True).stdout
    assert all(len(l.split("\t")) == 11 for l in body.splitlines())
    hdr = subprocess.run(["samtools", "view", "-H", str(out)], capture_output=True, text=True).stdout
    assert "@SQ" in hdr
    assert verify.sam11_md5(out) == verify.sam11_md5(BAM)


def test_fastq_plain_decompresses_gz(tmp_path):
    import gzip
    text = "".join(f"@r{i}\nACGT\n+\nIIII\n" for i in range(7))
    src = tmp_path / "in.fastq.gz"
    with gzip.open(src, "wt") as f:
        f.write(text)
    out = prepare.fastq_plain(src, tmp_path / "in.fastq")
    assert out.read_text() == text
    plain = tmp_path / "p.fastq"; plain.write_text(text)
    assert prepare.fastq_plain(plain, tmp_path / "p2.fastq").read_text() == text


def test_run_writes_plan(tmp_path, monkeypatch):
    monkeypatch.setenv("TTIO_BENCH_DATA", str(tmp_path))
    c = common.Corpus(id="toy", tier="aligned", source=f"file://{BAM}", sha256=None,
                      reference=f"file://{REPO}/python/tests/fixtures/genomic/m87_ref.fa")
    assert prepare.run([c]) == 0
    plan = json.loads((tmp_path / "prepared/toy/plan.json").read_text())
    kinds = {s["kind"] for s in plan["inputs"]}
    assert kinds == {"bam11", "bam_full"}
    assert len(plan["inputs"]) == 2
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /home/toddw/TTI-O && python/.venv/bin/python -m pytest tools/perf/compression_suite/tests/test_prepare.py -q`
Expected: FAIL (`No module named 'stages'`).

- [ ] **Step 3: Implement stages/prepare.py**

```python
# tools/perf/compression_suite/stages/prepare.py
"""prepare: 11-column BAMs, plain FASTQ, references -> prepared/<id>/plan.json."""
from __future__ import annotations

import gzip
import json
import shutil
import subprocess
from pathlib import Path

import common


def _local(source: str) -> Path:
    if source.startswith("file://"):
        return Path(source[len("file://"):])
    # fetched by Task 8 into raw/<id>/<basename>
    raise ValueError(f"prepare needs a local path; run fetch first: {source}")


def raw_path(corpus: common.Corpus) -> Path:
    if corpus.source.startswith("file://"):
        return _local(corpus.source)
    d = common.data_dir() / "raw" / corpus.id
    files = sorted(p for p in d.iterdir() if p.is_file() and not p.name.endswith((".sha256", ".part")))
    if not files:
        raise FileNotFoundError(f"nothing fetched for {corpus.id} in {d}")
    return files[0]


def eleven_column(bam: Path, out: Path) -> Path:
    out.parent.mkdir(parents=True, exist_ok=True)
    p1 = subprocess.Popen(["samtools", "view", "-h", str(bam)], stdout=subprocess.PIPE)
    p2 = subprocess.Popen(["cut", "-f", "1-11"], stdin=p1.stdout, stdout=subprocess.PIPE)
    p3 = subprocess.run(["samtools", "view", "-b", "-o", str(out)], stdin=p2.stdout, check=True)
    p1.stdout.close(); p2.stdout.close()
    if p1.wait() != 0 or p2.wait() != 0 or p3.returncode != 0:
        raise RuntimeError("eleven_column pipeline failed")
    return out


def _sq(bam: Path) -> list[tuple[str, int]]:
    hdr = subprocess.run(["samtools", "view", "-H", str(bam)], capture_output=True, text=True, check=True).stdout
    out = []
    for line in hdr.splitlines():
        if line.startswith("@SQ"):
            f = dict(x.split(":", 1) for x in line.split("\t")[1:] if ":" in x)
            out.append((f["SN"], int(f["LN"])))
    return out


def fastq_plain(fq: Path, out: Path) -> Path:
    out.parent.mkdir(parents=True, exist_ok=True)
    if fq.name.endswith(".gz"):
        with gzip.open(fq, "rb") as fi, open(out, "wb") as fo:
            shutil.copyfileobj(fi, fo, 1 << 24)
    else:
        shutil.copyfile(fq, out)
    return out


def reference_for(corpus: common.Corpus) -> Path | None:
    if corpus.reference:
        return _local(corpus.reference) if corpus.reference.startswith("file://") \
            else common.data_dir() / "raw" / "reference" / Path(corpus.reference).name
    if corpus.tier != "aligned":
        return None
    bam = raw_path(corpus)
    names = {sn for sn, _ in _sq(bam)}
    refdir = common.data_dir() / "raw" / "reference"
    if names & {"chr1", "chr22"}:
        return refdir / "GRCh38_no_alt.fa"
    return refdir / "hs37d5.fa"


def run(corpora: list[common.Corpus]) -> int:
    for c in corpora:
        src = raw_path(c)
        pdir = common.data_dir() / "prepared" / c.id
        pdir.mkdir(parents=True, exist_ok=True)
        plan_path = pdir / "plan.json"
        sha = common.sha256_of(src)
        if plan_path.exists() and json.loads(plan_path.read_text()).get("input_sha256") == sha:
            print(f"prepare: {c.id} up to date"); continue
        inputs = []
        ref = reference_for(c)
        if c.tier == "aligned":
            inputs.append({"name": src.stem, "path": str(src), "kind": "bam_full"})
            s11 = eleven_column(src, pdir / f"{src.stem}.11col.bam")
            inputs.append({"name": src.stem, "path": str(s11), "kind": "bam11"})
        elif c.tier == "unaligned":
            stem = src.name[:-len(".fastq.gz")] if src.name.endswith(".fastq.gz") else src.stem
            fq = fastq_plain(src, pdir / f"{stem}.fastq")
            inputs.append({"name": stem, "path": str(fq), "kind": "fastq"})
        else:
            inputs.append({"name": src.stem, "path": str(src), "kind": "mzml"})
        plan_path.write_text(json.dumps({"id": c.id, "tier": c.tier, "input_sha256": sha,
                                         "reference": str(ref) if ref else None,
                                         "inputs": inputs}, indent=1))
        print(f"prepare: {c.id}: {len(inputs)} inputs")
    return 0
```

- [ ] **Step 4: Run tests**

Run: `cd /home/toddw/TTI-O && python/.venv/bin/python -m pytest tools/perf/compression_suite/tests/test_prepare.py -q`
Expected: 3 passed.

- [ ] **Step 5: Commit**

```bash
git add tools/perf/compression_suite/stages tools/perf/compression_suite/tests/test_prepare.py
git commit -F /home/toddw/msg.txt   # subject: "perf: prepare stage: 11-column BAMs, plain FASTQ, references"
```

---

### Task 8: fetch stage, sra-tools, corpus discovery and manifest completion

**Files:**
- Create: `tools/perf/compression_suite/stages/fetch.py`
- Create: `tools/perf/compression_suite/tools/install_sra_tools.sh`
- Create: `tools/perf/compression_suite/tools/discover.py`
- Modify: `tools/perf/compression_suite/manifest.yaml` (add fetched corpora + references)
- Test: `tools/perf/compression_suite/tests/test_fetch.py`

**Interfaces:**
- Consumes: `common.Corpus`, `common.data_dir`, `common.sha256_of`.
- Produces: `fetch.run(corpora, manifest_path) -> int`: for `http(s)://` and `ftp://` sources `curl -L -C - --retry 20 -o raw/<id>/<name>.part` then rename; for `sra:<SRR>` sources `prefetch --max-size u <SRR>` then `fasterq-dump --split-3 --outdir raw/<id>` (paired runs are concatenated `_1` then `_2` into `<SRR>.fastq`, so one FASTQ per corpus); computes sha256, writes it into the manifest when `null`, refuses on mismatch. References: entries with `tier: reference` are fetched into `raw/reference/` and `samtools faidx`ed.
- Produces: `discover.py` prints candidate SRA runs for HG002 (`SAMN03283347`) via the ENA portal API and candidate PRIDE projects via the PRIDE API, so the accession choice is recorded, not remembered.

- [ ] **Step 1: Write install_sra_tools.sh and discover.py**

```bash
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
```

```python
# tools/perf/compression_suite/tools/discover.py
"""Print candidate corpora so accession choices are recorded in the manifest.

  python discover.py sra      # HG002 runs from ENA (Illumina + PacBio)
  python discover.py pride    # PRIDE projects with mzML files, Exploris / timsTOF
"""
import json, sys, urllib.parse, urllib.request

HG002 = "SAMN03283347"


def sra():
    q = f'sample_accession="{HG002}"'
    url = ("https://www.ebi.ac.uk/ena/portal/api/search?result=read_run&query="
           + urllib.parse.quote(q)
           + "&fields=run_accession,instrument_platform,instrument_model,library_layout,base_count,read_count,fastq_bytes&format=tsv&limit=0")
    print(urllib.request.urlopen(url).read().decode())


def pride():
    for kw in ("Orbitrap Exploris 480", "timsTOF"):
        url = ("https://www.ebi.ac.uk/pride/ws/archive/v2/search/projects?keyword="
               + urllib.parse.quote(kw) + "&pageSize=25&page=0")
        rows = json.loads(urllib.request.urlopen(url).read().decode())
        for r in rows if isinstance(rows, list) else rows.get("_embedded", {}).get("projects", []):
            print(r.get("accession"), "|", r.get("title"), "|", ",".join(r.get("instruments", []) or []))


if __name__ == "__main__":
    {"sra": sra, "pride": pride}[sys.argv[1]]()
```

- [ ] **Step 2: Run discovery and choose corpora against the spec's criteria**

Run: `bash tools/perf/compression_suite/tools/install_sra_tools.sh` then `python3 tools/perf/compression_suite/tools/discover.py sra | sort -t$'\t' -k6 -n | tail -40` and `python3 tools/perf/compression_suite/tools/discover.py pride`.
Choose: one HG002 ILLUMINA WGS run (paired, base_count in the 30-150 Gbase range) and one HG002 PACBIO_SMRT HiFi run (CCS, largest available); one Orbitrap Exploris DDA project and one timsTOF project that host mzML files of 1-4 GB (list files with `https://www.ebi.ac.uk/pride/ws/archive/v2/files/byProject?accession=<PXD>` and pick the mzML URL). Record each with a one-line rationale in the manifest `notes`.

- [ ] **Step 3: Write the failing test**

```python
# tools/perf/compression_suite/tests/test_fetch.py
import sys, textwrap
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import common  # noqa: E402
from stages import fetch  # noqa: E402


def test_fetch_local_file_records_sha_and_enforces(tmp_path, monkeypatch):
    monkeypatch.setenv("TTIO_BENCH_DATA", str(tmp_path))
    src = tmp_path / "src.bin"; src.write_bytes(b"hello")
    m = tmp_path / "manifest.yaml"
    m.write_text(textwrap.dedent(f"""
        corpora:
          - id: toy
            tier: ms
            source: file://{src}
            sha256: null
            reference: null
    """))
    corpora = common.load_manifest(m)
    assert fetch.run(corpora, m) == 0
    again = common.load_manifest(m)
    assert again[0].sha256 == common.sha256_of(src)
    src.write_bytes(b"changed")
    with pytest.raises(RuntimeError, match="sha256 mismatch"):
        fetch.run(again, m)


def test_http_fetch_uses_curl_resume(monkeypatch, tmp_path):
    monkeypatch.setenv("TTIO_BENCH_DATA", str(tmp_path))
    calls = []
    monkeypatch.setattr(fetch, "_curl", lambda url, dest: (calls.append((url, dest)), dest.write_bytes(b"x")))
    c = common.Corpus(id="h", tier="ms", source="https://example.org/a.mzML", sha256=None, reference=None)
    m = tmp_path / "m.yaml"; m.write_text("corpora:\n  - id: h\n    tier: ms\n    source: https://example.org/a.mzML\n")
    assert fetch.run([c], m) == 0
    assert calls and calls[0][1].name == "a.mzML.part"
    assert (tmp_path / "raw/h/a.mzML").exists()
```

- [ ] **Step 4: Run to verify failure**

Run: `cd /home/toddw/TTI-O && python/.venv/bin/python -m pytest tools/perf/compression_suite/tests/test_fetch.py -q`
Expected: FAIL (`cannot import name 'fetch'`).

- [ ] **Step 5: Implement stages/fetch.py**

```python
# tools/perf/compression_suite/stages/fetch.py
"""fetch: bring every manifest source into raw/<id>/, checksum, pin sha256."""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import yaml

import common

SRA_BIN = Path(os.environ.get("SRA_BIN", str(Path.home() / "tools/sratoolkit/bin")))


def _curl(url: str, dest: Path) -> None:
    subprocess.run(["curl", "-L", "-C", "-", "--retry", "20", "--retry-delay", "15",
                    "-o", str(dest), url], check=True)


def _fetch_sra(acc: str, dest_dir: Path) -> Path:
    prefetch = SRA_BIN / "prefetch"; fqd = SRA_BIN / "fasterq-dump"
    subprocess.run([str(prefetch), "--max-size", "u", "-O", str(dest_dir), acc], check=True)
    subprocess.run([str(fqd), "--split-3", "--threads", "8", "-O", str(dest_dir), str(dest_dir / acc)], check=True)
    parts = sorted(dest_dir.glob(f"{acc}_[12].fastq"))
    single = dest_dir / f"{acc}.fastq"
    if parts:
        with open(single, "wb") as fo:
            for p in parts:
                with open(p, "rb") as fi:
                    shutil.copyfileobj(fi, fo, 1 << 24)
                p.unlink()
    shutil.rmtree(dest_dir / acc, ignore_errors=True)
    return single


def _pin(manifest_path: Path, corpus_id: str, sha: str) -> None:
    doc = yaml.safe_load(manifest_path.read_text())
    for c in doc["corpora"]:
        if c["id"] == corpus_id:
            c["sha256"] = sha
    manifest_path.write_text(yaml.safe_dump(doc, sort_keys=False))


def _dest_for(corpus: common.Corpus) -> Path:
    if corpus.tier == "reference":
        d = common.data_dir() / "raw" / "reference"
    else:
        d = common.data_dir() / "raw" / corpus.id
    d.mkdir(parents=True, exist_ok=True)
    return d


def run(corpora: list[common.Corpus], manifest_path: Path) -> int:
    for c in corpora:
        if c.source.startswith("file://"):
            local = Path(c.source[len("file://"):])
        elif c.source.startswith("sra:"):
            d = _dest_for(c); local = d / f"{c.source[4:]}.fastq"
            if not local.exists():
                local = _fetch_sra(c.source[4:], d)
        else:
            d = _dest_for(c); name = c.source.rsplit("/", 1)[-1]
            local = d / name
            if not local.exists():
                part = d / (name + ".part")
                _curl(c.source, part)
                part.rename(local)
        if c.tier == "reference" and not Path(str(local) + ".fai").exists():
            if local.suffix == ".gz":
                subprocess.run(["gzip", "-d", "-k", str(local)], check=True); local = local.with_suffix("")
            subprocess.run(["samtools", "faidx", str(local)], check=True)
        sha = common.sha256_of(local)
        if c.sha256 is None:
            _pin(manifest_path, c.id, sha); print(f"fetch: {c.id} pinned {sha[:12]}")
        elif c.sha256 != sha:
            raise RuntimeError(f"fetch: {c.id} sha256 mismatch: manifest {c.sha256[:12]} vs file {sha[:12]}")
        else:
            print(f"fetch: {c.id} ok")
    return 0
```

- [ ] **Step 6: Extend the manifest with the fetched corpora and references (values from Step 2)**

Append to `manifest.yaml`:

```yaml
  - id: hg002_2x250_full
    tier: aligned
    source: https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/data/AshkenazimTrio/HG002_NA24385_son/NIST_Illumina_2x250bps/novoalign_bams/HG002.GRCh38.2x250.bam
    sha256: null
    reference: GRCh38_no_alt.fa
    notes: GIAB HG002 Illumina 2x250 whole-genome BAM (GRCh38); the chr22 slice on disk came from it
  - id: hg002_hifi_full
    tier: aligned
    source: <the HiFi GRCh38 BAM URL under ReferenceSamples/giab/.../HG002_NA24385_son/PacBio_CCS_15kb_20kb_chemistry2/GRCh38/ chosen in Step 2>
    sha256: null
    reference: GRCh38_no_alt.fa
    notes: GIAB HG002 PacBio HiFi whole-genome BAM (GRCh38)
  - id: hg002_illumina_wgs_sra
    tier: unaligned
    source: sra:<SRR chosen in Step 2>
    sha256: null
    reference: null
    notes: <one line: platform, layout, base count, why this run>
  - id: hg002_hifi_sra
    tier: unaligned
    source: sra:<SRR chosen in Step 2>
    sha256: null
    reference: null
    notes: <one line>
  - id: orbitrap_exploris
    tier: ms
    source: <PRIDE mzML URL chosen in Step 2>
    sha256: null
    reference: null
    notes: <PXD accession, instrument, size>
  - id: timstof_pasef
    tier: ms
    source: <PRIDE mzML URL chosen in Step 2>
    sha256: null
    reference: null
    notes: <PXD accession, instrument, size>
  - id: GRCh38_no_alt
    tier: reference
    source: https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/000/001/405/GCA_000001405.15_GRCh38/seqs_for_alignment_pipelines.ucsc_ids/GCA_000001405.15_GRCh38_no_alt_analysis_set.fna.gz
    sha256: null
    reference: null
    notes: GRCh38 no-alt analysis set (UCSC names); decompressed to GRCh38_no_alt.fa by fetch
  - id: hs37d5
    tier: reference
    source: https://ftp-trace.ncbi.nlm.nih.gov/1000genomes/ftp/technical/reference/phase2_reference_assembly_sequence/hs37d5.fa.gz
    sha256: null
    reference: null
    notes: 1000 Genomes phase 2 reference (hs37d5)
```

Then make `fetch` name the decompressed reference `GRCh38_no_alt.fa` / `hs37d5.fa` (rename after `gzip -d`), and make `common.load_manifest` accept `tier: reference`. Verify with a `HEAD` request that each URL resolves and record the byte size in `notes`: `curl -sIL <url> | grep -i content-length`.

- [ ] **Step 7: Run tests**

Run: `cd /home/toddw/TTI-O && python/.venv/bin/python -m pytest tools/perf/compression_suite/tests/test_fetch.py -q`
Expected: 2 passed.

- [ ] **Step 8: Commit**

```bash
git add tools/perf/compression_suite/stages/fetch.py tools/perf/compression_suite/tools tools/perf/compression_suite/manifest.yaml tools/perf/compression_suite/tests/test_fetch.py
git commit -F /home/toddw/msg.txt   # subject: "perf: fetch stage with sha256 pinning, sra-tools install, corpus discovery"
```

---

### Task 9: encode stage with decode-verify and resume keys

**Files:**
- Create: `tools/perf/compression_suite/stages/encode.py`
- Test: `tools/perf/compression_suite/tests/test_encode.py`

**Interfaces:**
- Consumes: `formats.load_all()`, `verify.*`, `common.run_timed`, `prepared/<id>/plan.json`.
- Produces: `encode.run(corpora, formats_csv: str, smoke: bool) -> int`; writes `results/<id>/<format>.<kind>.json`:
  ```json
  {"corpus": "...", "tier": "...", "format": "cram31_small", "input": "...", "kind": "bam11",
   "input_bytes": 0, "output_bytes": 0, "encode_s": 0.0, "decode_s": 0.0,
   "encode_rss_mb": 0.0, "decode_rss_mb": 0.0, "verify": "PASS|FAIL",
   "max_rel_error": null, "tool_version": "...", "input_sha256": "...", "lossy": false,
   "breakdown": {}}
  ```
- Produces: `encode.FORMATS_BY_TIER = {"aligned": [...], "unaligned": [...], "ms": [...]}` (which formats run on which input kind: `bam11` gets every aligned key; `bam_full` gets `bam`, `cram30`, `cram31_*`, `mpegg` and never `ttio`).
- Produces: `encode.breakdown(fmt_key, enc_path) -> dict` (TTI-O: `h5ls -rv` storage bytes summed per channel name; CRAM: empty unless `samtools cram_size` exists).
- Resume key: an existing result JSON is skipped when its `input_sha256` and `tool_version` match; the encode runs `run_timed` around `fmt.encode`, then `fmt.decode`, then the tier's verify function.

- [ ] **Step 1: Write the failing test**

```python
# tools/perf/compression_suite/tests/test_encode.py
import json, shutil, sys
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import common  # noqa: E402
from stages import prepare, encode  # noqa: E402

REPO = Path(__file__).resolve().parents[4]
BAM = REPO / "python/tests/fixtures/genomic/m87_test.bam"
REF = REPO / "python/tests/fixtures/genomic/m87_ref.fa"
pytestmark = pytest.mark.skipif(shutil.which("samtools") is None, reason="samtools missing")


def test_encode_writes_verified_results_and_resumes(tmp_path, monkeypatch):
    monkeypatch.setenv("TTIO_BENCH_DATA", str(tmp_path))
    monkeypatch.setattr(encode, "RESULTS", tmp_path / "results")
    c = common.Corpus(id="toy", tier="aligned", source=f"file://{BAM}", sha256=None, reference=f"file://{REF}")
    prepare.run([c])
    assert encode.run([c], "bam,cram31_small,ttio", smoke=True) == 0
    files = sorted((tmp_path / "results/toy").glob("*.json"))
    assert files, "no results written"
    recs = [json.loads(f.read_text()) for f in files]
    assert {r["format"] for r in recs} >= {"bam", "cram31_small", "ttio"}
    assert all(r["verify"] == "PASS" for r in recs)
    assert all(r["output_bytes"] > 0 and r["encode_s"] >= 0 for r in recs)
    ttio = [r for r in recs if r["format"] == "ttio"]
    assert all(r["kind"] == "bam11" for r in ttio)
    # second run reuses everything
    mtimes = {f: f.stat().st_mtime_ns for f in files}
    assert encode.run([c], "bam,cram31_small,ttio", smoke=True) == 0
    assert {f: f.stat().st_mtime_ns for f in files} == mtimes


def test_failed_verify_is_recorded_not_raised(tmp_path, monkeypatch):
    monkeypatch.setenv("TTIO_BENCH_DATA", str(tmp_path))
    monkeypatch.setattr(encode, "RESULTS", tmp_path / "results")
    import verify
    monkeypatch.setattr(verify, "sam11_md5", lambda p: str(p))  # every decode differs from input
    c = common.Corpus(id="toy", tier="aligned", source=f"file://{BAM}", sha256=None, reference=f"file://{REF}")
    prepare.run([c])
    assert encode.run([c], "bam", smoke=True) == 0
    rec = json.loads(next((tmp_path / "results/toy").glob("bam.*.json")).read_text())
    assert rec["verify"] == "FAIL"
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /home/toddw/TTI-O && python/.venv/bin/python -m pytest tools/perf/compression_suite/tests/test_encode.py -q`
Expected: FAIL (`cannot import name 'encode'`).

- [ ] **Step 3: Implement stages/encode.py**

```python
# tools/perf/compression_suite/stages/encode.py
"""encode: every format x every input, timed, decode-verified, resumable."""
from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
from pathlib import Path

import common
import formats
import verify

HERE = Path(__file__).resolve().parents[1]
RESULTS = HERE / "results"

FORMATS_BY_TIER = {
    "aligned": ["bam", "cram30", "cram31_normal", "cram31_small", "cram31_archive", "mpegg", "ttio"],
    "unaligned": ["fastq_gz", "cram31_small_unaligned", "mpegg_unaligned", "ttio_fastq"],
    "ms": ["mzml_gz", "mzml_numpress_gz", "ttio_mzml"],
}
FULL_TAG_FORMATS = {"bam", "cram30", "cram31_normal", "cram31_small", "cram31_archive", "mpegg"}


def breakdown(fmt_key: str, enc: Path) -> dict:
    if fmt_key.startswith("ttio") and shutil.which("h5ls"):
        p = subprocess.run(["h5ls", "-rv", str(enc)], capture_output=True, text=True)
        out, cur = {}, None
        for line in p.stdout.splitlines():
            if line.startswith("/"):
                cur = line.split()[0]
            elif "Storage:" in line and cur:
                # "Storage: <logical> logical bytes, <alloc> allocated bytes, ..."
                toks = line.replace(",", " ").split()
                try:
                    out[cur] = int(toks[toks.index("allocated") - 1])
                except (ValueError, IndexError):
                    pass
        return out
    return {}


def _verify(tier: str, kind: str, inp: Path, dec: Path, lossy: bool):
    if tier in ("aligned",):
        return ("PASS" if verify.sam11_md5(dec) == verify.sam11_md5(inp) else "FAIL"), None
    if tier == "unaligned":
        return ("PASS" if verify.fastq_md5(dec) == verify.fastq_md5(inp) else "FAIL"), None
    if lossy:
        err = verify.mzml_max_rel_error(inp, dec)
        return ("PASS" if err < 1e-3 else "FAIL"), err
    return ("PASS" if verify.mzml_arrays_md5(dec) == verify.mzml_arrays_md5(inp) else "FAIL"), None


def run(corpora: list[common.Corpus], formats_csv: str, smoke: bool) -> int:
    reg = formats.load_all()
    wanted = None if formats_csv == "all" else set(formats_csv.split(","))
    for c in corpora:
        plan_path = common.data_dir() / "prepared" / c.id / "plan.json"
        if not plan_path.exists():
            print(f"encode: {c.id}: no plan (run prepare)"); continue
        if smoke and not c.source.startswith("file://"):
            continue
        plan = json.loads(plan_path.read_text())
        ref = Path(plan["reference"]) if plan.get("reference") else None
        for item in plan["inputs"]:
            for key in FORMATS_BY_TIER[c.tier]:
                if wanted and key not in wanted:
                    continue
                if item["kind"] == "bam_full" and key not in FULL_TAG_FORMATS:
                    continue
                fmt = reg[key]
                out_json = RESULTS / c.id / f"{key}.{item['kind']}.json"
                inp = Path(item["path"]); sha = common.sha256_of(inp); ver = fmt.version()
                if out_json.exists():
                    prev = json.loads(out_json.read_text())
                    if prev.get("input_sha256") == sha and prev.get("tool_version") == ver:
                        continue
                work = Path(tempfile.mkdtemp(prefix=f"{c.id}.{key}.", dir=common.data_dir() / "out"))
                rec = {"corpus": c.id, "tier": c.tier, "format": key, "input": item["name"],
                       "kind": item["kind"], "input_bytes": inp.stat().st_size, "input_sha256": sha,
                       "tool_version": ver, "lossy": fmt.lossy, "breakdown": {}, "max_rel_error": None}
                try:
                    holder = {}
                    t_enc = common.run_timed([sys_executable(), "-c", _ENC_SNIPPET,
                                              key, str(inp), str(work), str(ref or "")])
                    enc = next(p for p in work.iterdir() if not p.name.startswith("dec"))
                    rec.update(output_bytes=enc.stat().st_size, encode_s=t_enc.wall_s,
                               encode_rss_mb=t_enc.peak_rss_mb, breakdown=breakdown(key, enc))
                    dec_dir = work / "dec"; dec_dir.mkdir()
                    t_dec = common.run_timed([sys_executable(), "-c", _DEC_SNIPPET,
                                              key, str(enc), str(dec_dir), str(ref or "")])
                    dec = next(dec_dir.iterdir())
                    rec.update(decode_s=t_dec.wall_s, decode_rss_mb=t_dec.peak_rss_mb)
                    rec["verify"], rec["max_rel_error"] = _verify(c.tier, item["kind"], inp, dec, fmt.lossy)
                except Exception as e:  # a broken encoder is a FAIL row, not a crash of the suite
                    rec.update(verify="FAIL", error=str(e)[-500:])
                    rec.setdefault("output_bytes", 0); rec.setdefault("encode_s", 0.0)
                    rec.setdefault("decode_s", 0.0); rec.setdefault("encode_rss_mb", 0.0)
                    rec.setdefault("decode_rss_mb", 0.0)
                finally:
                    shutil.rmtree(work, ignore_errors=True)
                out_json.parent.mkdir(parents=True, exist_ok=True)
                out_json.write_text(json.dumps(rec, indent=1))
                print(f"encode: {c.id} {item['kind']} {key}: {rec.get('output_bytes')} B {rec['verify']}")
    return 0


def sys_executable() -> str:
    import sys
    return sys.executable


# The encode and decode run in a child process so /usr/bin/time -v measures
# the tool (and any Python importer) rather than the driver.
_ENC_SNIPPET = """
import sys; from pathlib import Path
sys.path.insert(0, %r)
import formats; reg = formats.load_all()
key, inp, work, ref = sys.argv[1:5]
reg[key].encode(Path(inp), Path(work), Path(ref) if ref else None)
""" % str(HERE)

_DEC_SNIPPET = """
import sys; from pathlib import Path
sys.path.insert(0, %r)
import formats; reg = formats.load_all()
key, enc, out, ref = sys.argv[1:5]
reg[key].decode(Path(enc), Path(out), Path(ref) if ref else None)
""" % str(HERE)
```

- [ ] **Step 4: Run tests**

Run: `cd /home/toddw/TTI-O && python/.venv/bin/python -m pytest tools/perf/compression_suite/tests/test_encode.py -q`
Expected: 2 passed. Note the `mkdtemp(dir=data_dir()/"out")` requires that directory: create it in `run` with `(common.data_dir() / "out").mkdir(parents=True, exist_ok=True)` before the loop.

- [ ] **Step 5: Commit**

```bash
git add tools/perf/compression_suite/stages/encode.py tools/perf/compression_suite/tests/test_encode.py
git commit -F /home/toddw/msg.txt   # subject: "perf: encode stage: timed, decode-verified, resumable"
```

---

### Task 10: report.py

**Files:**
- Create: `tools/perf/compression_suite/report.py`
- Test: `tools/perf/compression_suite/tests/test_report.py`

**Interfaces:**
- Consumes: `results/<id>/*.json` records from Task 9.
- Produces: `report.aggregate(results_dir) -> dict[corpus_id, dict[(format, kind), Agg]]` holding one record per (format, kind) with `rss_mb` = max of the encode and decode peak RSS; `report.render(agg, env: dict) -> str` (markdown); `report.run(results_dir, out_md) -> int`.
- Baseline per tier: aligned `bam` (bam11 kind), unaligned `fastq_gz`, ms `mzml_gz`. Ratio = baseline bytes / format bytes. bytes/base uses the base count recorded by `prepare` (add `"bases"` per input to `plan.json` in `prepare.run`: `samtools view <bam> | awk '{s+=length($10)} END{print s}'` for BAM, `awk 'NR%4==2{s+=length($0)} END{print s}'` for FASTQ). Report `bytes/base` for genomic corpora only.

- [ ] **Step 1: Write the failing test**

```python
# tools/perf/compression_suite/tests/test_report.py
import json, sys
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import report  # noqa: E402


def _rec(**kw):
    base = {"corpus": "toy", "tier": "aligned", "format": "bam", "input": "toy", "kind": "bam11",
            "input_bytes": 100, "output_bytes": 50, "encode_s": 1.0, "decode_s": 0.5,
            "encode_rss_mb": 10.0, "decode_rss_mb": 5.0, "verify": "PASS", "max_rel_error": None,
            "tool_version": "samtools 1.19.2", "input_sha256": "x", "lossy": False, "breakdown": {},
            "bases": 1000}
    base.update(kw); return base


def test_aggregate_keeps_one_row_per_format_and_flags_fail(tmp_path):
    d = tmp_path / "toy"; d.mkdir()
    (d / "bam.bam11.json").write_text(json.dumps(_rec(output_bytes=80)))
    (d / "bam.bam_full.json").write_text(json.dumps(_rec(kind="bam_full", output_bytes=120)))
    (d / "ttio.bam11.json").write_text(json.dumps(_rec(format="ttio", output_bytes=20, verify="FAIL")))
    agg = report.aggregate(tmp_path)
    assert agg["toy"][("bam", "bam11")].output_bytes == 80
    assert agg["toy"][("bam", "bam_full")].output_bytes == 120
    assert agg["toy"][("bam", "bam11")].verify == "PASS"
    assert agg["toy"][("ttio", "bam11")].verify == "FAIL"
    md = report.render(agg, {"cpu": "x", "date": "2026-08-16"})
    assert "| ttio" in md and "FAIL" in md
    assert "80" in md
    # ratio column: bam is the baseline -> 1.00
    assert "1.00" in md
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /home/toddw/TTI-O && python/.venv/bin/python -m pytest tools/perf/compression_suite/tests/test_report.py -q`
Expected: FAIL (`No module named 'report'`).

- [ ] **Step 3: Implement report.py**

```python
# tools/perf/compression_suite/report.py
"""Aggregate results/**.json into REPORT.md."""
from __future__ import annotations

import json
import platform
import subprocess
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

BASELINE = {"aligned": ("bam", "bam11"), "unaligned": ("fastq_gz", "fastq"), "ms": ("mzml_gz", "mzml")}
HEADLINE = ["ttio", "cram31_small", "mpegg", "ttio_fastq", "cram31_small_unaligned", "mpegg_unaligned",
            "ttio_mzml", "mzml_gz", "mzml_numpress_gz"]


@dataclass
class Agg:
    tier: str
    input_bytes: int = 0
    output_bytes: int = 0
    encode_s: float = 0.0
    decode_s: float = 0.0
    rss_mb: float = 0.0
    bases: int = 0
    verify: str = "PASS"
    lossy: bool = False
    tool_version: str = ""
    max_rel_error: float | None = None
    breakdown: dict = field(default_factory=dict)


def aggregate(results_dir: Path) -> dict[str, dict[tuple[str, str], Agg]]:
    out: dict[str, dict[tuple[str, str], Agg]] = {}
    for f in sorted(Path(results_dir).glob("*/*.json")):
        r = json.loads(f.read_text())
        a = Agg(tier=r["tier"], input_bytes=r.get("input_bytes", 0), output_bytes=r.get("output_bytes", 0),
                encode_s=r.get("encode_s", 0.0), decode_s=r.get("decode_s", 0.0),
                rss_mb=max(r.get("encode_rss_mb", 0.0), r.get("decode_rss_mb", 0.0)),
                bases=r.get("bases", 0) or 0, verify="PASS" if r.get("verify") == "PASS" else "FAIL",
                lossy=r.get("lossy", False), tool_version=r.get("tool_version", ""),
                max_rel_error=r.get("max_rel_error"), breakdown=dict(r.get("breakdown") or {}))
        out.setdefault(r["corpus"], {})[(r["format"], r["kind"])] = a
    return out


def _fmt_bytes(n: int) -> str:
    return f"{n:,}"


def render(agg: dict, env: dict) -> str:
    lines = ["# Compression benchmark report", "",
             f"Generated {env.get('date')} on {env.get('cpu')}; {env.get('ram', '')} RAM; {env.get('kernel', '')}.",
             "Every size shown has a passing decode-verify. Rows marked FAIL show no size.", ""]
    lines += ["## Headline", "", "| corpus | format | kind | bytes | ratio vs baseline | verify |", "|---|---|---|---:|---:|---|"]
    for cid, table in agg.items():
        tier = next(iter(table.values())).tier
        base = table.get(BASELINE[tier])
        for (key, kind), a in sorted(table.items()):
            if key not in HEADLINE:
                continue
            ratio = f"{base.output_bytes / a.output_bytes:.2f}" if base and a.output_bytes and a.verify == "PASS" else ""
            size = _fmt_bytes(a.output_bytes) if a.verify == "PASS" else ""
            lines.append(f"| {cid} | {key} | {kind} | {size} | {ratio} | {a.verify} |")
    lines.append("")
    for cid, table in agg.items():
        tier = next(iter(table.values())).tier
        base = table.get(BASELINE[tier])
        lines += [f"## {cid}", "",
                  "| format | kind | bytes | ratio | bytes/base | encode s | decode s | peak RSS MB | lossy | tool | verify |",
                  "|---|---|---:|---:|---:|---:|---:|---:|---|---|---|"]
        for (key, kind), a in sorted(table.items()):
            ok = a.verify == "PASS"
            size = _fmt_bytes(a.output_bytes) if ok else ""
            ratio = f"{base.output_bytes / a.output_bytes:.2f}" if ok and base and a.output_bytes else ""
            bpb = f"{a.output_bytes / a.bases:.4f}" if ok and a.bases and tier != "ms" else ""
            lossy = "yes" + (f" (max rel err {a.max_rel_error:.1e})" if a.max_rel_error is not None else "") if a.lossy else "no"
            lines.append(f"| {key} | {kind} | {size} | {ratio} | {bpb} | {a.encode_s:.1f} | {a.decode_s:.1f} | "
                         f"{a.rss_mb:.0f} | {lossy} | {a.tool_version} | {a.verify} |")
        lines.append("")
        for (key, kind), a in sorted(table.items()):
            if a.breakdown and a.verify == "PASS":
                lines += [f"{key} ({kind}) storage by dataset:", "", "| dataset | bytes |", "|---|---:|"]
                for k, v in sorted(a.breakdown.items(), key=lambda kv: -kv[1])[:20]:
                    lines.append(f"| {k} | {_fmt_bytes(v)} |")
                lines.append("")
    return "\n".join(lines) + "\n"


def environment() -> dict:
    cpu = subprocess.run(["sh", "-c", "grep -m1 'model name' /proc/cpuinfo | cut -d: -f2"],
                         capture_output=True, text=True).stdout.strip()
    ram = subprocess.run(["sh", "-c", "free -g | awk '/Mem:/{print $2\" GB\"}'"],
                         capture_output=True, text=True).stdout.strip()
    return {"cpu": cpu, "ram": ram, "kernel": platform.release(), "date": date.today().isoformat()}


def run(results_dir: Path, out_md: Path) -> int:
    out_md.write_text(render(aggregate(results_dir), environment()))
    print(f"report: wrote {out_md}")
    return 0
```

- [ ] **Step 4: Add `bases` to prepare's plan and to encode's record**

In `stages/prepare.py`, after each input is created, count bases: for BAM `int(subprocess.run(["sh","-c",f"samtools view {s} | awk '{{n+=length($10)}} END{{print n+0}}'"], capture_output=True, text=True).stdout)`; for FASTQ `awk 'NR%4==2{n+=length($0)} END{print n+0}'`; store `"bases": n` in each input dict (mzML: 0). In `stages/encode.py`, copy `item.get("bases", 0)` into `rec["bases"]`. Re-run `tests/test_prepare.py` and `tests/test_encode.py`.

- [ ] **Step 5: Run tests**

Run: `cd /home/toddw/TTI-O && python/.venv/bin/python -m pytest tools/perf/compression_suite/tests -q`
Expected: all pass (podman/samtools-dependent tests may skip on a machine without them; here they run).

- [ ] **Step 6: Commit**

```bash
git add tools/perf/compression_suite
git commit -F /home/toddw/msg.txt   # subject: "perf: report generator for the compression suite"
```

---

### Task 11: Smoke run on the on-disk corpora, commit results

**Files:**
- Modify: `tools/perf/compression_suite/results/` (new JSON), `tools/perf/compression_suite/REPORT.md`
- Modify: `tools/perf/compression_suite/README.md` (record smoke runtime and peak RSS)

- [ ] **Step 1: Run fetch (pins sha256 of on-disk files), prepare, encode --smoke, report**

Run:
```bash
cd /home/toddw/TTI-O && export TTIO_BENCH_DATA=$HOME/ttio-bench-data && PY=python/.venv/bin/python
$PY tools/perf/compression_suite/suite.py --corpus na12878_chr22_lowcov --corpus na12878_wes_chr22 --corpus hg002_2x250_chr22 --corpus hg002_hifi_subset --corpus pxd000001_orbitrap fetch
$PY tools/perf/compression_suite/suite.py --corpus na12878_chr22_lowcov --corpus na12878_wes_chr22 --corpus hg002_2x250_chr22 --corpus hg002_hifi_subset --corpus pxd000001_orbitrap prepare
$PY tools/perf/compression_suite/suite.py --corpus na12878_chr22_lowcov --corpus na12878_wes_chr22 --corpus hg002_2x250_chr22 --corpus hg002_hifi_subset --corpus pxd000001_orbitrap encode --smoke
$PY tools/perf/compression_suite/suite.py report
```
Expected: every row `PASS`. If a row is `FAIL`, open its JSON `error` field and fix the format module (a real bug in an encoder or in TTI-O's import/export is a finding; record it in the README's "Known issues" section and keep the FAIL row).

- [ ] **Step 2: Read the TTI-O peak RSS**

Run: `grep -h encode_rss_mb tools/perf/compression_suite/results/*/ttio*.json | sort -t: -k2 -n | tail -3`
The streaming importers keep the TTI-O rows near the block working set (about 2 GB at the default 1 M-read blocks per docs/format-spec.md section 10.12.3). A row far above that is a finding: record it in the README and keep the number.

- [ ] **Step 3: Read REPORT.md, then commit results and report**

```bash
git add tools/perf/compression_suite/results tools/perf/compression_suite/REPORT.md tools/perf/compression_suite/README.md tools/perf/compression_suite/manifest.yaml
git commit -F /home/toddw/msg.txt   # subject: "perf: compression suite smoke results on the chr22 slices and PXD000001"
```

---

### Task 12: Full run and final report

**Files:**
- Modify: `tools/perf/compression_suite/results/`, `REPORT.md`, `manifest.yaml` (pinned sha256), `CHANGELOG.md` (`[Unreleased]` / Internal)

- [ ] **Step 1: Fetch everything (long; run in the background with a log)**

Run: `cd /home/toddw/TTI-O && export TTIO_BENCH_DATA=$HOME/ttio-bench-data && nohup python/.venv/bin/python tools/perf/compression_suite/suite.py fetch > $TTIO_BENCH_DATA/fetch.log 2>&1 &`
Check with `tail -f $TTIO_BENCH_DATA/fetch.log`; `curl -C -` and `prefetch` resume if interrupted, so re-running the same command continues.

- [ ] **Step 2: Prepare and encode everything (long)**

Run: `nohup sh -c 'python/.venv/bin/python tools/perf/compression_suite/suite.py prepare && python/.venv/bin/python tools/perf/compression_suite/suite.py encode' > $TTIO_BENCH_DATA/encode.log 2>&1 &`
The encode stage is resumable: rerun the same command after any interruption.

- [ ] **Step 3: Report, read it, commit**

Run: `python/.venv/bin/python tools/perf/compression_suite/suite.py report && sed -n 1,80p tools/perf/compression_suite/REPORT.md`
Add to `CHANGELOG.md` under `[Unreleased]` / `### Internal` one entry: `tools/perf/compression_suite`: end-to-end compression benchmark of TTI-O against CRAM 3.0/3.1 (samtools 1.19), MPEG-G (genie) and mzML.gz / numpress on whole GIAB, 1000 Genomes, SRA and PRIDE datasets, decode-verified; results and REPORT.md committed. Then:

```bash
git add tools/perf/compression_suite CHANGELOG.md
git commit -F /home/toddw/msg.txt   # subject: "perf: full compression benchmark results and report"
```

- [ ] **Step 4: Open the PR**

Push via Windows git (`"/c/Program Files/Git/bin/git.exe" -C "//wsl.localhost/Ubuntu/home/toddw/TTI-O" push -u origin compression-suite`), then `gh pr create --body-file <gated body>` with the 5-part body under 200 words: what the suite is, how sizes are verified, what it deliberately does not do (no CI, no lossy TTI-O tier), the test path (`tools/perf/compression_suite/tests`), and the headline numbers per corpus.

---

## Self-review

- Spec §2 layout: Tasks 1, 7-10 create every listed file (`stages/` holds fetch/prepare/encode; the spec's `formats/`, `verify.py`, `report.py`, `tools/`, `results/`, `REPORT.md` all appear). `tools/build_genie.sh` from the spec is replaced by the pinned container image (`tools/genie_image.txt`), which the spec's §9 allows ("pin ... record it in tools/").
- Spec §3 corpora: on-disk five in Task 1, fetched six plus two references in Task 8 with the selection criteria and discovery script.
- Spec §4 information constancy: Task 7 (11-column and full-tag inputs), Task 9 (`FULL_TAG_FORMATS`, TTI-O never on full-tag).
- Spec §5 formats: Tasks 3-6 cover every key; threads=1 in samtools and genie; psims numpress names verified at Task 6 step 4.
- Spec §6 measurement: Task 1 `run_timed`, Task 9 child-process timing and verify; FAIL rows carry no size (Task 10 render).
- Spec §7 report: headline + per-corpus tables + environment + breakdown (Task 10); CRAM breakdown omitted since `samtools cram_size` is not in 1.19 (spec §9 says omit).
- Spec §8 validation: unit tests per task, `--smoke` (Task 11), full run (Task 12).
- Type consistency: `Corpus`, `Timed`, `Format` protocol, registry keys, `plan.json` and result JSON field names are identical across Tasks 1, 3-10.
- Revised 2026-08-17: the earlier draft sharded aligned BAMs into 50 Mb windows and FASTQ into 20 M-read chunks because the TTI-O importers held a run in memory. The v1.9 streaming importers and exporters (blocks_v1, PRs #290-#292) removed that limit, so every format now encodes the whole file and the report has one row per format and input kind.
