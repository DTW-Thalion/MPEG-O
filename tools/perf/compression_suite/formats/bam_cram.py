# tools/perf/compression_suite/formats/bam_cram.py
"""BAM baseline and CRAM 3.0 / 3.1 profiles via samtools."""
from __future__ import annotations

import os
import shutil
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


class _BamBaseline(_SamtoolsFormat):
    """The BAM row is the input as prepared: the 11-column BAM was written
    by `samtools view -b` (the same command this row would run) and the
    full BAM is the file as distributed. Encode and decode hard-link
    the file into the work dir, so a 130 GB input costs no disk and no
    time; the decoded copy still goes through the digest."""

    def _link(self, src: Path, dst: Path) -> Path:
        if dst.exists():
            dst.unlink()
        try:
            os.link(src, dst)
        except OSError:
            shutil.copyfile(src, dst)
        return dst

    def encode(self, inp: Path, out_dir: Path, ref: Path | None) -> Path:
        if inp.suffix != ".bam":
            return super().encode(inp, out_dir, ref)
        return self._link(inp, out_dir / f"{inp.stem}.{self.key}{self.ext}")

    def decode(self, enc: Path, out_dir: Path, ref: Path | None) -> Path:
        return self._link(enc, out_dir / f"{enc.name}.decoded.bam")


register(_BamBaseline("bam", "bam", ".bam"))
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
