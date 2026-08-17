# tools/perf/compression_suite/formats/mpegg.py
"""MPEG-G via the genie reference software, run from its container image.

The image's entrypoint is genie. Aligned records go through
transcode-sam (SAM to mgrec, with the reference so classes M, N and P
are generated) and then run (mgrec to mgb); decoding reverses the two
steps. Unaligned FASTQ goes straight through run.
"""
from __future__ import annotations

import subprocess
from pathlib import Path

from formats import register

HERE = Path(__file__).resolve().parents[1]
GENIE_IMAGE = (HERE / "tools" / "genie_image.txt").read_text().strip()


def genie(op: str, args: list[str], mounts: list[Path]) -> None:
    """Run one genie operation. genie exits 0 after printing an
    [ERROR ...] line (transcode-sam on a contig missing from the
    reference, for example), so the log is scanned and any such line
    raises."""
    cmd = ["podman", "run", "--rm"]
    for m in sorted({str(p.resolve()) for p in mounts}):
        cmd += ["-v", f"{m}:{m}:Z"]
    cmd += [GENIE_IMAGE, op, *args]
    p = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
    log = (p.stdout or "") + (p.stderr or "")
    errors = [l for l in log.splitlines() if l.startswith("[ERROR")]
    if p.returncode != 0 or errors:
        raise RuntimeError(f"genie {op} failed (rc={p.returncode}): "
                           + "; ".join(e[:200] for e in errors[:3]))


class _Genie:
    lossy = False

    def __init__(self, key: str, tier: str):
        self.key, self.tier = key, tier

    def encode(self, inp: Path, out_dir: Path, ref: Path | None) -> Path:
        out = out_dir / f"{inp.name}.{self.key}.mgb"
        if out.exists():
            out.unlink()
        work = out_dir / f"{inp.name}.{self.key}.work"
        work.mkdir(exist_ok=True)
        mounts = [inp.parent, out_dir]
        refargs: list[str] = []
        if ref is not None:
            refargs = ["-r", str(ref.resolve())]
            mounts.append(ref.parent)
        if self.tier == "aligned":
            sam = work / f"{inp.stem}.sam"
            with open(sam, "w") as f:
                subprocess.run(["samtools", "view", "-h", str(inp)], stdout=f, check=True)
            mgrec = work / f"{inp.stem}.mgrec"
            genie("transcode-sam", ["-i", str(sam.resolve()), "-o", str(mgrec.resolve()),
                                    "-w", str(work.resolve()), "-t", "1", "-f", *refargs], mounts)
            sam.unlink()
            src = mgrec
        else:
            src = inp
        genie("run", ["-i", str(src.resolve()), "-o", str(out.resolve()),
                      "-w", str(work.resolve()), "-t", "1", "-f", *refargs], mounts)
        for p in work.iterdir():
            p.unlink()
        work.rmdir()
        return out

    def decode(self, enc: Path, out_dir: Path, ref: Path | None) -> Path:
        ext = ".sam" if self.tier == "aligned" else ".fastq"
        out = out_dir / f"{enc.name}.decoded{ext}"
        if out.exists():
            out.unlink()
        work = out_dir / f"{enc.name}.dec.work"
        work.mkdir(exist_ok=True)
        mounts = [enc.parent, out_dir]
        refargs: list[str] = []
        if ref is not None:
            refargs = ["-r", str(ref.resolve())]
            mounts.append(ref.parent)
        if self.tier == "aligned":
            mgrec = work / f"{enc.stem}.dec.mgrec"
            genie("run", ["-i", str(enc.resolve()), "-o", str(mgrec.resolve()),
                          "-w", str(work.resolve()), "-t", "1", "-f", *refargs], mounts)
            genie("transcode-sam", ["-i", str(mgrec.resolve()), "-o", str(out.resolve()),
                                    "-w", str(work.resolve()), "-t", "1", "-f", *refargs], mounts)
        else:
            genie("run", ["-i", str(enc.resolve()), "-o", str(out.resolve()),
                          "-w", str(work.resolve()), "-t", "1", "-f"], mounts)
        for p in work.iterdir():
            p.unlink()
        work.rmdir()
        return out

    def version(self) -> str:
        return f"genie ({GENIE_IMAGE})"


register(_Genie("mpegg", "aligned"))
register(_Genie("mpegg_unaligned", "unaligned"))
