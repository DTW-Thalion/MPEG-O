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
