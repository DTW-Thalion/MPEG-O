"""Format adapters for the M92 compression-benchmark harness.

Each adapter exposes ``compress(bam_path, ref_fasta, out_path)``
and ``decompress(in_path, ref_fasta, out_bam_path)``. Both return
a :class:`Result` capturing wall time, output size, and the exact
command line used (for reproducibility in the published report).

Adapters dispatched by ``run_one(format_name, ...)`` in
:mod:`tools.benchmarks.runner`.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class Result:
    format_name: str
    operation: str  # "compress" or "decompress"
    wall_seconds: float
    output_size_bytes: int
    command: list[str] = field(default_factory=list)
    notes: str = ""


def _require(binary: str) -> str:
    path = shutil.which(binary)
    if path is None:
        raise RuntimeError(
            f"Required binary {binary!r} not on PATH. See "
            f"docs/benchmarks/environment.md for setup."
        )
    return path


def _find_user_genie() -> str | None:
    """Look in the user-local install prefix used by the build script."""
    candidate = os.path.expanduser("~/genie/install/bin/genie")
    return candidate if os.path.isfile(candidate) and os.access(candidate, os.X_OK) else None


def _run(cmd: list[str], stdin: bytes | None = None) -> tuple[float, bytes]:
    t0 = time.perf_counter()
    proc = subprocess.run(
        cmd,
        input=stdin,
        capture_output=True,
        check=False,
    )
    elapsed = time.perf_counter() - t0
    if proc.returncode != 0:
        raise RuntimeError(
            f"{' '.join(cmd)} exited {proc.returncode}: "
            f"{proc.stderr.decode('utf-8', 'replace')[:500]}"
        )
    return elapsed, proc.stdout


# ---------------------------------------------------------------------------
# BAM (identity for compress; samtools view for decompress to SAM)
# ---------------------------------------------------------------------------

def bam_compress(bam_path: Path, ref_fasta: Path, out_path: Path) -> Result:
    # BAM is the input; "compressing to BAM" is a no-op copy that we
    # measure for fairness against the other formats' overhead.
    samtools = _require("samtools")
    cmd = [samtools, "view", "-b", "-o", str(out_path), str(bam_path)]
    elapsed, _ = _run(cmd)
    return Result(
        format_name="bam",
        operation="compress",
        wall_seconds=elapsed,
        output_size_bytes=out_path.stat().st_size,
        command=cmd,
        notes="samtools view -b (BGZF re-pack)",
    )


def bam_decompress(in_path: Path, ref_fasta: Path, out_sam_path: Path) -> Result:
    samtools = _require("samtools")
    cmd = [samtools, "view", "-h", "-o", str(out_sam_path), str(in_path)]
    elapsed, _ = _run(cmd)
    return Result(
        format_name="bam",
        operation="decompress",
        wall_seconds=elapsed,
        output_size_bytes=out_sam_path.stat().st_size,
        command=cmd,
    )


# ---------------------------------------------------------------------------
# CRAM 3.1
# ---------------------------------------------------------------------------

def cram_compress(bam_path: Path, ref_fasta: Path, out_path: Path) -> Result:
    samtools = _require("samtools")
    cmd = [
        samtools, "view",
        "-C",
        "-T", str(ref_fasta),
        "--output-fmt-option", "version=3.1",
        "--output-fmt-option", "embed_ref=0",
        "-o", str(out_path),
        str(bam_path),
    ]
    elapsed, _ = _run(cmd)
    return Result(
        format_name="cram",
        operation="compress",
        wall_seconds=elapsed,
        output_size_bytes=out_path.stat().st_size,
        command=cmd,
        notes="CRAM 3.1, no embedded reference",
    )


def cram_decompress(in_path: Path, ref_fasta: Path, out_sam_path: Path) -> Result:
    samtools = _require("samtools")
    cmd = [
        samtools, "view",
        "-h",
        "-T", str(ref_fasta),
        "-o", str(out_sam_path),
        str(in_path),
    ]
    elapsed, _ = _run(cmd)
    return Result(
        format_name="cram",
        operation="decompress",
        wall_seconds=elapsed,
        output_size_bytes=out_sam_path.stat().st_size,
        command=cmd,
    )


# ---------------------------------------------------------------------------
# TTI-O
# ---------------------------------------------------------------------------

def _load_reference_chroms(ref_fasta: Path, chroms_used: set[str]) -> dict[str, bytes]:
    """Read only the chromosomes touched by the run from the FASTA file.

    Loads each chromosome's sequence as uppercase ACGTN bytes. Skips
    chromosomes not in ``chroms_used`` to keep memory bounded.
    """
    out: dict[str, bytes] = {}
    if not chroms_used:
        return out
    target_set = {c.encode("ascii") for c in chroms_used}
    current = None
    buf = bytearray()
    with ref_fasta.open("rb") as fh:
        for line in fh:
            if line.startswith(b">"):
                if current is not None:
                    out[current.decode("ascii")] = bytes(buf).upper()
                hdr = line[1:].split()[0] if len(line) > 1 else b""
                current = hdr if hdr in target_set else None
                buf.clear()
            elif current is not None:
                buf.extend(line.strip())
        if current is not None:
            out[current.decode("ascii")] = bytes(buf).upper()
    return out


def ttio_compress(bam_path: Path, ref_fasta: Path, out_path: Path) -> Result:
    # In-process via the Python reference — Java/ObjC paths produce
    # byte-identical output by construction (M82.4 conformance).
    # Enables the full M83–M86 + M93 codec stack on every applicable
    # channel; lossless throughout (no QUALITY_BINNED).
    #
    # M94.Z dispatch detection (for the notes string only — the codec
    # itself reads its own env vars when invoked).
    #   - V4 (CRAM 3.1 fqzcomp port, the default since Stage 2/M94.Z)
    #     activates when libttio_rans is loadable: TTIO_RANS_LIB_PATH
    #     set + the .so present.
    #   - V2 (older native rANS path) activates via TTIO_M94Z_USE_NATIVE
    #     when V4 is not chosen — only relevant if a caller forces
    #     TTIO_M94Z_VERSION=2.
    #   - V1 is the pure-Python fallback when no native lib is available.
    _have_rans_lib = os.environ.get("TTIO_RANS_LIB_PATH", "").strip() != ""
    _force_pre_v4 = os.environ.get("TTIO_M94Z_VERSION", "").strip() in ("1", "2", "3")
    _use_native_v2 = os.environ.get("TTIO_M94Z_USE_NATIVE", "").strip().lower() in (
        "1", "true", "yes", "on"
    )
    if _have_rans_lib and not _force_pre_v4:
        _quality_codec_label = "V4/CRAM 3.1 fqzcomp byte-equal"
    elif _have_rans_lib and _use_native_v2:
        _quality_codec_label = "V2/native rANS"
    else:
        _quality_codec_label = "V1/pure-Python"

    from ttio import SpectralDataset
    from ttio.enums import Compression
    from ttio.importers.bam import BamReader
    from dataclasses import replace

    # v1.10 — let the v2 codecs default themselves. Setting
    # signal_codec_overrides[sequences|read_names] to the v1 codec ids
    # (REF_DIFF=9, NAME_TOKENIZED=8) BYPASSES the v1.8 / v1.9 dispatch
    # that picks REF_DIFF_V2 (id 14) and NAME_TOKENIZED_V2 (id 15) by
    # default. Pre-v1.10 versions of this harness pinned id 8 / id 9
    # explicitly, which silently disabled v2 wins (~4 MB on chr22).
    # Cigars stays on RANS_ORDER1 per WORKPLAN — v2 has no equivalent.
    # Qualities at FQZCOMP_NX16_Z (id 12) dispatches to V4 native when
    # the lib is loaded.
    codec_overrides = {
        "qualities":          Compression.FQZCOMP_NX16_Z,
        "cigars":             Compression.RANS_ORDER1,
    }

    t0 = time.perf_counter()
    written = BamReader(bam_path).to_genomic_run(name="run_0001")

    # M93 v1.2: load the chromosomes touched by the run from the
    # benchmark's reference FASTA so REF_DIFF can apply. Falls back
    # to BASE_PACK silently if the reference can't be loaded.
    # L3 (Task #82 Phase B.1, 2026-05-01): we no longer embed the
    # reference in the .tio file by default — it's a 9-10 MB blob
    # for chr22 that CRAM 3.1 doesn't carry by default either. The
    # reference path is stamped into external_reference_path so
    # the read side can resolve via REF_PATH or the path metadata.
    chroms_used = set(written.chromosomes) - {"*"}
    try:
        chrom_seqs = _load_reference_chroms(ref_fasta, chroms_used)
    except Exception:
        chrom_seqs = {}

    # signal_compression="gzip" gives the non-codec channels
    # (positions, flags, mapping_qualities, mate_info_pos,
    # template_lengths) HDF5 zlib compression. Per Binding
    # Decision §87 the writer skips zlib on codec-overridden
    # channels (no double-compression).
    written = replace(
        written,
        signal_compression="gzip",
        signal_codec_overrides=codec_overrides,
        # L3: chrom_seqs is still passed (REF_DIFF needs them at
        # encode time to compute the diff against), but we do NOT
        # embed them in the file. Reader resolves via the FASTA
        # path stamped in external_reference_path.
        embed_reference=False,
        reference_chrom_seqs=chrom_seqs if chrom_seqs else None,
        external_reference_path=ref_fasta if chrom_seqs else None,
    )
    SpectralDataset.write_minimal(
        out_path,
        title=f"benchmark:{bam_path.name}",
        isa_investigation_id="TTIO:bench:m93",
        runs={"run_0001": written},
    )
    elapsed = time.perf_counter() - t0
    return Result(
        format_name="ttio",
        operation="compress",
        wall_seconds=elapsed,
        output_size_bytes=out_path.stat().st_size,
        command=["<in-process: BamReader.to_genomic_run + SpectralDataset.write_minimal>"],
        notes=(
            "Python reference path, v1.10 default codec stack: "
            "REF_DIFF_V2 (id 14) on sequences (falls back to BASE_PACK if "
            "ref load fails), FQZCOMP_NX16_Z V4 "
            f"({_quality_codec_label}) on qualities, RANS_ORDER1 on cigars, "
            "NAME_TOKENIZED_V2 (id 15) on read_names, MATE_INLINE_V2 (id 13) "
            "on mate_info. v1.10 #10 drops genomic_index/spectrum_index/"
            "chromatogram_index offsets columns. Lossless throughout."
        ),
    )


def ttio_decompress(in_path: Path, ref_fasta: Path, out_sam_path: Path) -> Result:
    # Walk every read to force full decode of every channel; emit a
    # minimal SAM-like dump so output_size_bytes is comparable.
    # L3 (Task #82 Phase B.1, 2026-05-01): the .tio file no longer
    # embeds the reference by default — stamp REF_PATH so the
    # REF_DIFF reference resolver can find the FASTA.
    from ttio import SpectralDataset
    prev_ref_path = os.environ.get("REF_PATH")
    os.environ["REF_PATH"] = str(ref_fasta)

    t0 = time.perf_counter()
    n_reads = 0
    n_bytes_dumped = 0
    with SpectralDataset.open(in_path) as ds, open(out_sam_path, "wb") as out:
        for run_name, run in ds.runs.items():
            for i in range(len(run)):
                read = run[i]
                # SAM-shaped tab-separated dump — keeps the
                # decompress measurement honest by touching every
                # field, not just the index.
                line = (
                    f"{getattr(read, 'read_name', '')}\t"
                    f"{getattr(read, 'flags', 0)}\t"
                    f"{getattr(read, 'chromosome', '*')}\t"
                    f"{getattr(read, 'position', 0)}\t"
                    f"{getattr(read, 'mapping_quality', 0)}\t"
                    f"{getattr(read, 'cigar', '*')}\n"
                ).encode("ascii", "replace")
                out.write(line)
                n_bytes_dumped += len(line)
                n_reads += 1
    elapsed = time.perf_counter() - t0
    if prev_ref_path is None:
        os.environ.pop("REF_PATH", None)
    else:
        os.environ["REF_PATH"] = prev_ref_path
    return Result(
        format_name="ttio",
        operation="decompress",
        wall_seconds=elapsed,
        output_size_bytes=n_bytes_dumped,
        command=["<in-process: SpectralDataset.open + per-read AlignedRead access>"],
        notes=f"Touched {n_reads:,} reads to force lazy decode of every channel.",
    )


# ---------------------------------------------------------------------------
# MPEG-G via Genie
# ---------------------------------------------------------------------------

def _resolve_genie() -> str:
    genie = (
        os.environ.get("GENIE_BIN")
        or shutil.which("genie")
        or _find_user_genie()
    )
    if genie is None:
        raise RuntimeError(
            "Genie not found. Set GENIE_BIN to the genie binary or "
            "install it per docs/benchmarks/environment.md §Genie."
        )
    return genie


def genie_compress(bam_path: Path, ref_fasta: Path, out_path: Path) -> Result:
    # Genie's `run` command dispatches on file extension and only
    # accepts sam/fastq/fasta/mgrec on the third-party side. We add
    # a SAM intermediate (samtools view -h) and time both stages.
    genie = _resolve_genie()
    samtools = _require("samtools")
    sam_intermediate = out_path.with_suffix(".sam")
    cmd_sam = [samtools, "view", "-h", "-o", str(sam_intermediate), str(bam_path)]
    cmd_genie = [genie, "run", "-i", str(sam_intermediate), "-o", str(out_path), "-f"]

    t0 = time.perf_counter()
    e1, _ = _run(cmd_sam)
    e2, _ = _run(cmd_genie)
    elapsed = time.perf_counter() - t0
    sam_intermediate.unlink(missing_ok=True)

    return Result(
        format_name="genie",
        operation="compress",
        wall_seconds=elapsed,
        output_size_bytes=out_path.stat().st_size,
        command=cmd_sam + ["&&"] + cmd_genie,
        notes=(
            f"MPEG-G via Genie (default profile). BAM→SAM intermediate "
            f"({e1:.2f}s) + genie run ({e2:.2f}s); SAM removed after."
        ),
    )


def genie_decompress(in_path: Path, ref_fasta: Path, out_sam_path: Path) -> Result:
    genie = _resolve_genie()
    cmd = [genie, "run", "-i", str(in_path), "-o", str(out_sam_path), "-f"]
    elapsed, _ = _run(cmd)
    return Result(
        format_name="genie",
        operation="decompress",
        wall_seconds=elapsed,
        output_size_bytes=out_sam_path.stat().st_size,
        command=cmd,
    )


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

ADAPTERS: dict[str, dict[str, callable]] = {
    "bam":   {"compress": bam_compress,   "decompress": bam_decompress,   "ext": ".bam"},
    "cram":  {"compress": cram_compress,  "decompress": cram_decompress,  "ext": ".cram"},
    "ttio":  {"compress": ttio_compress,  "decompress": ttio_decompress,  "ext": ".tio"},
    "genie": {"compress": genie_compress, "decompress": genie_decompress, "ext": ".mgb"},
}


def supported() -> list[str]:
    return sorted(ADAPTERS)
