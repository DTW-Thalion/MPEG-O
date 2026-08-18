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
        """An aligned run is written against the external reference
        (REF_DIFF_V2 sequences, reference not embedded), the same footing
        as CRAM with an external reference."""
        out = out_dir / f"{inp.name}.{self.key}.tio"
        if out.exists():
            out.unlink()
        cmd = [TTIO_CLI, "encode", "--input", str(inp), "--format", self.in_fmt,
               "--output", str(out)]
        if ref is not None and self.tier == "aligned":
            cmd += ["--reference", str(ref)]
        subprocess.run(cmd, check=True)
        return out

    def decode(self, enc: Path, out_dir: Path, ref: Path | None) -> Path:
        """REF_PATH is the reader's external-reference hook
        (ttio.genomic.reference_resolver.ReferenceResolver)."""
        out = out_dir / f"{enc.name}.decoded{self.out_ext}"
        if out.exists():
            out.unlink()
        env = dict(os.environ)
        if ref is not None:
            env["REF_PATH"] = str(ref)
        subprocess.run([TTIO_CLI, "export", "--input", str(enc), "--layer",
                        layer_name(enc, self.tier), "--format", self.out_fmt,
                        "--output", str(out)], check=True, env=env)
        return out

    # Source paths whose content decides what this tier writes and reads.
    # The version string carries git's tree/blob hashes of these paths, so
    # a row re-runs when the code it depends on changed and only then: a
    # rebase over unrelated commits keeps every result.
    _SOURCE_PATHS = {
        "aligned": ["native/src", "python/src/ttio/codecs", "python/src/ttio/genomic",
                    "python/src/ttio/_dataset_write_genomic.py", "python/src/ttio/genomic_run.py",
                    "python/src/ttio/written_genomic_run.py", "python/src/ttio/importers/bam.py",
                    "python/src/ttio/importers/import_result.py", "python/src/ttio/exporters/bam.py",
                    "python/src/ttio/spectral_dataset.py"],
        "unaligned": ["native/src", "python/src/ttio/codecs", "python/src/ttio/genomic",
                      "python/src/ttio/_dataset_write_genomic.py", "python/src/ttio/genomic_run.py",
                      "python/src/ttio/written_genomic_run.py", "python/src/ttio/importers/fastq.py",
                      "python/src/ttio/importers/import_result.py", "python/src/ttio/exporters/fastq.py",
                      "python/src/ttio/tools/fastq_import_cli.py", "python/src/ttio/tools/fastq_export_cli.py",
                      "python/src/ttio/spectral_dataset.py"],
        "ms": ["native/src", "python/src/ttio/codecs", "python/src/ttio/importers/mzml.py",
               "python/src/ttio/importers/_base64_zlib.py", "python/src/ttio/importers/import_result.py",
               "python/src/ttio/exporters/mzml.py", "python/src/ttio/spectral_stream_writer.py",
               "python/src/ttio/acquisition_run.py", "python/src/ttio/spectral_dataset.py"],
    }

    def version(self) -> str:
        """The CLI version plus a digest of the tree hashes of the source
        paths this tier depends on (and a dirty mark when any of them has
        uncommitted changes)."""
        import hashlib
        ver = common.tool_version([TTIO_CLI, "--version"])
        repo = Path(__file__).resolve().parents[4]
        paths = self._SOURCE_PATHS[self.tier]
        try:
            h = hashlib.sha256()
            for rel in paths:
                obj = subprocess.run(["git", "-C", str(repo), "rev-parse", f"HEAD:{rel}"],
                                     capture_output=True, text=True)
                h.update(rel.encode()); h.update(b"="); h.update(obj.stdout.strip().encode()); h.update(b"\n")
            dirty = subprocess.run(["git", "-C", str(repo), "status", "--porcelain", "--", *paths],
                                   capture_output=True, text=True).stdout.strip()
            return f"{ver} src:{h.hexdigest()[:12]}{'+' if dirty else ''}"
        except OSError:
            return ver


register(_Ttio("ttio", "aligned", "bam", "bam", ".bam"))
register(_Ttio("ttio_fastq", "unaligned", "fastq", "fastq", ".fastq"))
register(_Ttio("ttio_mzml", "ms", "mzml", "mzml", ".mzML"))
