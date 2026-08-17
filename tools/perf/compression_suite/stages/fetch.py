# tools/perf/compression_suite/stages/fetch.py
"""fetch: bring every manifest source into raw/<id>/, checksum, pin sha256.

A tier: reference entry lands in raw/reference/ and is decompressed to
<id>.fa with a samtools .fai beside it; the sha256 pinned is that of the
file as fetched."""
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
    text = manifest_path.read_text()
    header = []
    for line in text.splitlines(keepends=True):
        if line.startswith("#") or not line.strip():
            header.append(line)
        else:
            break
    doc = yaml.safe_load(text)
    for c in doc["corpora"]:
        if c["id"] == corpus_id:
            c["sha256"] = sha
    manifest_path.write_text("".join(header) + yaml.safe_dump(doc, sort_keys=False, width=1000))


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
        if c.tier == "reference":
            fa = _dest_for(c) / f"{c.id}.fa"
            if not Path(str(fa) + ".fai").exists():
                if local.suffix == ".gz":
                    with open(fa, "wb") as fo:
                        subprocess.run(["gzip", "-d", "-c", str(local)], stdout=fo, check=True)
                elif local != fa:
                    shutil.copyfile(local, fa)
                subprocess.run(["samtools", "faidx", str(fa)], check=True)
        sha = common.sha256_of(local)
        if c.sha256 is None:
            _pin(manifest_path, c.id, sha); print(f"fetch: {c.id} pinned {sha[:12]}")
        elif c.sha256 != sha:
            raise RuntimeError(f"fetch: {c.id} sha256 mismatch: manifest {c.sha256[:12]} vs file {sha[:12]}")
        else:
            print(f"fetch: {c.id} ok")
    return 0
