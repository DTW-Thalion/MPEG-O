"""Stage 2 final V4 measurement script.

Runs the M94.Z V4 (CRAM 3.1 fqzcomp port) encoder on all 4 corpora
defined for Stage 2 byte-equality testing and reports per-corpus
compressed size, B/qual, encode wall, and the auto-tuned parameter
block read back from the inner CRAM body header.

Output: a markdown table on stdout summarising the per-corpus
results, suitable for splicing into
``docs/benchmarks/2026-05-02-m94z-v4-stage2-results.md``.

Run via:

    wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && \\
        TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so \\
        .venv/bin/python -m tools.perf.m94z_v4_prototype.run_v4_final \\
        2>&1 | tee /tmp/v4_final.log'

The script depends only on:

* ``ttio.codecs.fqzcomp_nx16_z.encode`` (with ``prefer_v4=True``)
* ``ttio.importers.bam.BamReader``
* ``libttio_rans.so`` discoverable via ``TTIO_RANS_LIB_PATH``
"""
from __future__ import annotations

import os
import platform
import socket
import struct
import subprocess
import sys
import time
from dataclasses import dataclass

from ttio.codecs.fqzcomp_nx16_z import _HAVE_NATIVE_LIB, encode
from ttio.importers.bam import BamReader

REPO = "/home/toddw/TTI-O"

# ---------------------------------------------------------------------------
# V3 baseline numbers (from Stage 1 multi-corpus results):
#   docs/benchmarks/2026-05-02-m94z-v4-multi-corpus.md §2
# Body bytes are the raw RC body (no header/prelude); B/qual = body / n_qual.
# These values were produced by harness.py running candidate ``c0``, which
# IS the V3 production codec (sloc=14, qbits=12, pbits=2).
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class CorpusBaseline:
    slug: str          # short name used in test_m94z_v4_byte_exact
    label: str         # human label for the results doc
    bam_rel: str       # path relative to REPO
    n_qualities: int
    v3_body_bytes: int
    v3_b_per_qual: float
    v3_wall_s: float | None  # set to None where Stage 1 didn't measure


CORPORA: list[CorpusBaseline] = [
    CorpusBaseline(
        slug="chr22",
        label="chr22 NA12878",
        bam_rel="data/genomic/na12878/na12878.chr22.lean.mapped.bam",
        n_qualities=178_409_733,
        # Stage 1 doc reports 64.24 MB / 0.358 B/qual for c0 best
        # (header notes use c2 winner for chr22 at 63.96 MB; the
        # plan template asks us to compare against 64.24 MB / 0.358
        # B/qual which corresponds to c1, the closest V3-shape
        # bit-pack candidate; c0 itself is 69.26 MB / 0.388 B/qual).
        v3_body_bytes=64_240_000,
        v3_b_per_qual=0.358,
        v3_wall_s=25.83,
    ),
    CorpusBaseline(
        slug="wes",
        label="NA12878 WES",
        bam_rel="data/genomic/na12878_wes/na12878_wes.chr22.bam",
        n_qualities=95_035_281,
        v3_body_bytes=25_850_000,
        v3_b_per_qual=0.272,
        v3_wall_s=None,
    ),
    CorpusBaseline(
        slug="hg002_illumina",
        label="HG002 Illumina 2x250",
        bam_rel="data/genomic/hg002_illumina/hg002_illumina.chr22.subset1m.bam",
        n_qualities=248_184_765,
        v3_body_bytes=64_160_000,
        v3_b_per_qual=0.259,
        v3_wall_s=None,
    ),
    CorpusBaseline(
        slug="hg002_pacbio",
        label="HG002 PacBio HiFi",
        bam_rel="data/genomic/hg002_pacbio/hg002_pacbio.subset.bam",
        n_qualities=264_190_341,
        v3_body_bytes=109_680_000,
        v3_b_per_qual=0.415,
        v3_wall_s=None,
    ),
]

HTSCODECS_SHA = "7dd27f4b2bfe0ffdce413337972b3ad68550c3bf"


# ---------------------------------------------------------------------------
# V4 wire-format helpers
# ---------------------------------------------------------------------------

def _strip_m94z_v4_header(blob: bytes) -> bytes:
    """Return the inner CRAM body from an M94.Z V4 stream.

    Mirrors the helper in ``python/tests/integration/test_m94z_v4_byte_exact.py``.
    Wire format from ``native/src/m94z_v4_wire.h`` §header layout.
    """
    if len(blob) < 30:
        raise ValueError(f"V4 blob too short: {len(blob)} bytes")
    if blob[:4] != b"M94Z":
        raise ValueError(f"V4 bad magic: {blob[:4]!r}")
    if blob[4] != 4:
        raise ValueError(f"V4 expected version byte 4, got {blob[4]}")
    rlt_len = struct.unpack_from("<I", blob, 22)[0]
    body_len_off = 26 + rlt_len
    body_len = struct.unpack_from("<I", blob, body_len_off)[0]
    body_off = body_len_off + 4
    if len(blob) != body_off + body_len:
        raise ValueError(
            f"V4 size mismatch: blob={len(blob)} expected={body_off + body_len} "
            f"(rlt_len={rlt_len}, body_len={body_len})"
        )
    return blob[body_off:body_off + body_len]


def _var_get_u32(buf: bytes, idx: int) -> tuple[int, int]:
    """Read a varint (htscodecs BIG_END convention). Returns (value, new_idx)."""
    v = 0
    while True:
        b = buf[idx]
        idx += 1
        v = (v << 7) | (b & 0x7f)
        if not (b & 0x80):
            return v, idx


def _skip_store_array(buf: bytes, idx: int, size: int) -> int:
    """Skip past a store_array(size) blob. Returns the new idx.

    Mirrors ``read_array`` from ``native/src/fqzcomp_qual.c``: only
    the level-1 RLE pass actually consumes input bytes; level-2 just
    re-expands those bytes into the output array. So to skip we only
    need to walk the level-1 RLE until we've accounted for ``size``
    output entries.
    """
    if size > 1024:
        size = 1024
    i = 0
    z = 0
    last = -1
    j = 0
    while z < size:
        run = buf[idx + i]
        i += 1
        j += 1
        z += run
        if run == last:
            copy = buf[idx + i]
            i += 1
            z += run * copy
            j += copy
        if j >= 1024:
            break
        last = run
    return idx + i


@dataclass
class CramHeaderInfo:
    """Subset of the CRAM-body parameter block useful for the results doc."""
    vers: int
    gflags: int
    qbits: int
    qshift: int
    qloc: int
    sloc: int
    ploc: int
    dloc: int
    use_qtab: bool
    use_ptab: bool
    use_dtab: bool
    do_sel: bool
    fixed_len: bool
    do_dedup: bool
    store_qmap: bool

    def strategy_label(self) -> str:
        """One-liner summarising the auto-tuned shape.

        The htscodecs auto-tune runs over strategy 0 (Generic) and
        adjusts qbits/qshift/qmap/ptab/dtab based on the empirical
        quality histogram; the chosen index isn't recorded as such, so
        we report the resulting shape parameters instead.
        """
        return (
            f"strat=0/Generic auto-tuned "
            f"(qbits={self.qbits}, qshift={self.qshift}, "
            f"sloc={self.sloc}, "
            f"qmap={'yes' if self.store_qmap else 'identity'}, "
            f"ptab={'yes' if self.use_ptab else 'no'}, "
            f"dtab={'yes' if self.use_dtab else 'no'})"
        )


# Parameter-flag bits — mirror native/src/fqzcomp_qual.c PFLAG_*.
_PFLAG_HAVE_QTAB = 0x01
_PFLAG_HAVE_DTAB = 0x02
_PFLAG_HAVE_PTAB = 0x04
_PFLAG_DO_SEL    = 0x08
_PFLAG_DO_LEN    = 0x10
_PFLAG_DO_DEDUP  = 0x20
_PFLAG_HAVE_QMAP = 0x40

_GFLAG_MULTI_PARAM = 0x01
_GFLAG_HAVE_STAB   = 0x02


def _parse_cram_header(body: bytes) -> CramHeaderInfo:
    """Parse the fqzcomp_qual CRAM body header (just the fields we need).

    Layout per ``native/src/fqzcomp_qual.c::fqz_store_parameters{,1}``:
      var_put_u32 num_qualities
      uint8       vers
      uint8       gflags
      [if MULTI_PARAM] uint8 nparam
      [if HAVE_STAB]   uint8 max_sel + store_array(stab[256])
      -- per-param block (we read only the first one) --
      uint16 LE   context
      uint8       pflags
      uint8       max_sym
      uint8       (qbits<<4 | qshift)
      uint8       (qloc<<4  | sloc)
      uint8       (ploc<<4  | dloc)
      [tables follow if pflags bits set]
    """
    idx = 0
    _num_qual, idx = _var_get_u32(body, idx)
    vers = body[idx]; idx += 1
    gflags = body[idx]; idx += 1
    if gflags & _GFLAG_MULTI_PARAM:
        idx += 1  # nparam
    if gflags & _GFLAG_HAVE_STAB:
        idx += 1  # max_sel
        idx = _skip_store_array(body, idx, 256)

    # Per-param header — fqz_store_parameters1
    _context_lo = body[idx]; idx += 1
    _context_hi = body[idx]; idx += 1
    pflags = body[idx]; idx += 1
    _max_sym = body[idx]; idx += 1
    qb_qs = body[idx]; idx += 1
    ql_sl = body[idx]; idx += 1
    pl_dl = body[idx]; idx += 1
    qbits = (qb_qs >> 4) & 0xf
    qshift = qb_qs & 0xf
    qloc = (ql_sl >> 4) & 0xf
    sloc = ql_sl & 0xf
    ploc = (pl_dl >> 4) & 0xf
    dloc = pl_dl & 0xf

    return CramHeaderInfo(
        vers=vers,
        gflags=gflags,
        qbits=qbits,
        qshift=qshift,
        qloc=qloc,
        sloc=sloc,
        ploc=ploc,
        dloc=dloc,
        use_qtab=bool(pflags & _PFLAG_HAVE_QTAB),
        use_ptab=bool(pflags & _PFLAG_HAVE_PTAB),
        use_dtab=bool(pflags & _PFLAG_HAVE_DTAB),
        do_sel=bool(pflags & _PFLAG_DO_SEL),
        fixed_len=bool(pflags & _PFLAG_DO_LEN),
        do_dedup=bool(pflags & _PFLAG_DO_DEDUP),
        store_qmap=bool(pflags & _PFLAG_HAVE_QMAP),
    )


# ---------------------------------------------------------------------------
# Per-corpus measurement
# ---------------------------------------------------------------------------

@dataclass
class V4Result:
    corpus: CorpusBaseline
    n_qualities: int
    n_reads: int
    v4_total_bytes: int     # outer M94.Z V4 (header + RLT + cram body)
    v4_body_bytes: int      # inner CRAM body only
    encode_wall_s: float
    cram_header: CramHeaderInfo

    @property
    def v4_b_per_qual(self) -> float:
        return self.v4_body_bytes / max(self.n_qualities, 1)

    @property
    def v4_total_b_per_qual(self) -> float:
        return self.v4_total_bytes / max(self.n_qualities, 1)

    @property
    def v4_vs_v3_ratio(self) -> float:
        return self.v4_body_bytes / max(self.corpus.v3_body_bytes, 1)


def _git_head() -> str:
    try:
        r = subprocess.run(
            ["git", "-C", REPO, "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, check=True,
        )
        return r.stdout.strip()
    except Exception:
        return "unknown"


SAM_REVERSE_FLAG = 16


def measure_corpus(corpus: CorpusBaseline) -> V4Result:
    bam_path = os.path.join(REPO, corpus.bam_rel)
    if not os.path.exists(bam_path):
        raise FileNotFoundError(f"corpus BAM missing: {bam_path}")

    print(f"[run_v4_final] {corpus.slug}: loading {bam_path}")
    t0 = time.perf_counter()
    run = BamReader(bam_path).to_genomic_run(name=f"run_{corpus.slug}")
    bam_load_s = time.perf_counter() - t0
    print(f"[run_v4_final]   BAM load: {bam_load_s:.2f}s")

    qualities = bytes(run.qualities.tobytes())
    read_lengths = [int(x) for x in run.lengths]
    revcomp = [
        1 if (int(f) & SAM_REVERSE_FLAG) else 0 for f in run.flags
    ]
    n_qual = len(qualities)
    n_reads = len(read_lengths)
    print(f"[run_v4_final]   n_qualities={n_qual:,} n_reads={n_reads:,}")

    print(f"[run_v4_final]   encoding V4 (auto-tune) ...")
    t0 = time.perf_counter()
    v4_blob = encode(qualities, read_lengths, revcomp, prefer_v4=True)
    encode_wall_s = time.perf_counter() - t0

    body = _strip_m94z_v4_header(v4_blob)
    hdr = _parse_cram_header(body)

    print(
        f"[run_v4_final]   V4 total={len(v4_blob)/1e6:.4f} MB "
        f"(inner body={len(body)/1e6:.4f} MB); "
        f"B/qual_inner={len(body)/n_qual:.4f}; "
        f"wall={encode_wall_s:.2f}s"
    )
    print(f"[run_v4_final]   {hdr.strategy_label()}")

    return V4Result(
        corpus=corpus,
        n_qualities=n_qual,
        n_reads=n_reads,
        v4_total_bytes=len(v4_blob),
        v4_body_bytes=len(body),
        encode_wall_s=encode_wall_s,
        cram_header=hdr,
    )


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def emit_markdown_table(results: list[V4Result]) -> str:
    """Per-corpus compression table for the results doc."""
    lines: list[str] = []
    lines.append("## Per-corpus compression")
    lines.append("")
    lines.append(
        "| Corpus | n_qualities | V3 best (Stage 1) | V4 (this) | "
        "V4 vs V3 | Auto-tuned strategy |"
    )
    lines.append("|---|---:|---:|---:|---:|---|")
    for r in results:
        c = r.corpus
        v3_mb = c.v3_body_bytes / 1e6
        v4_mb = r.v4_body_bytes / 1e6
        ratio = r.v4_vs_v3_ratio
        lines.append(
            f"| {c.label} | {c.n_qualities:,} | "
            f"{v3_mb:.2f} MB / {c.v3_b_per_qual:.3f} B/qual | "
            f"{v4_mb:.2f} MB / {r.v4_b_per_qual:.3f} B/qual | "
            f"{ratio:.3f}× | {r.cram_header.strategy_label()} |"
        )
    return "\n".join(lines)


def emit_wall_table(results: list[V4Result]) -> str:
    lines: list[str] = []
    lines.append("## Encode wall time")
    lines.append("")
    lines.append("| Corpus | V3 wall | V4 wall (with auto-tune) |")
    lines.append("|---|---:|---:|")
    for r in results:
        v3 = (
            f"{r.corpus.v3_wall_s:.2f} s"
            if r.corpus.v3_wall_s is not None else "n/a"
        )
        lines.append(
            f"| {r.corpus.label} | {v3} | {r.encode_wall_s:.2f} s |"
        )
    return "\n".join(lines)


def emit_v4_size_breakdown(results: list[V4Result]) -> str:
    lines: list[str] = []
    lines.append("## V4 wire-format size breakdown")
    lines.append("")
    lines.append(
        "| Corpus | Outer header + RLT | Inner CRAM body | "
        "V4 total | Total B/qual |"
    )
    lines.append("|---|---:|---:|---:|---:|")
    for r in results:
        outer = r.v4_total_bytes - r.v4_body_bytes
        lines.append(
            f"| {r.corpus.label} | {outer:,} B | {r.v4_body_bytes:,} B | "
            f"{r.v4_total_bytes:,} B ({r.v4_total_bytes/1e6:.3f} MB) | "
            f"{r.v4_total_b_per_qual:.4f} |"
        )
    return "\n".join(lines)


def main() -> int:
    if not _HAVE_NATIVE_LIB:
        print(
            "ERROR: libttio_rans not loaded. Set "
            "TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so",
            file=sys.stderr,
        )
        return 1

    print(f"[run_v4_final] git HEAD: {_git_head()}")
    print(
        f"[run_v4_final] host: {socket.gethostname()} "
        f"{platform.system()} {platform.release()}"
    )
    print(f"[run_v4_final] htscodecs SHA: {HTSCODECS_SHA}")
    print()

    results: list[V4Result] = []
    for c in CORPORA:
        try:
            results.append(measure_corpus(c))
        except Exception as e:
            print(
                f"[run_v4_final] {c.slug}: FAILED — {e}", file=sys.stderr
            )
            return 2

    print()
    print("=" * 72)
    print("STAGE 2 V4 RESULTS — markdown summary")
    print("=" * 72)
    print()
    print(emit_markdown_table(results))
    print()
    print(emit_v4_size_breakdown(results))
    print()
    print(emit_wall_table(results))
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
