"""Chr22 harness for M94.Z V4 candidate prototype.

Loads chr22 BAM once, runs all 5 candidates from
:mod:`candidates`, measures compressed body bytes + encode wall +
per-candidate diagnostics, applies the §5 decision rule from the
Stage 1 spec, and emits a markdown results doc.

Invoke:

    TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so \\
        .venv/bin/python -m tools.perf.m94z_v4_prototype.harness
"""

from __future__ import annotations

import os
import platform
import socket
import subprocess
import sys
import time
from dataclasses import dataclass, field

import numpy as np

from ttio.codecs.fqzcomp_nx16_z import _HAVE_NATIVE_LIB
from ttio.importers.bam import BamReader
from tools.perf.m94z_v4_prototype.candidates import CANDIDATES
from tools.perf.m94z_v4_prototype.encode_pipeline import (
    encode_with_kernel,
    pad_count_for,
)

# --- Constants -----------------------------------------------------------

CHR22_BAM = "/home/toddw/TTI-O/data/genomic/na12878/na12878.chr22.lean.mapped.bam"
CRAM_BYTES = 86_094_472  # CRAM 3.1 chr22 reference, from prior measurements
SAM_REVERSE_FLAG = 16
GATE_RATIO = 1.15  # hard gate: TTI-O / CRAM <= 1.15 to "pass"
RESULTS_PATH = "docs/benchmarks/2026-05-02-m94z-v4-candidates.md"


@dataclass
class CandidateResult:
    name: str
    sloc: int
    description: str
    body_bytes: int
    n_active: int
    encode_wall_s: float
    distinct_ctx_count: int
    mean_symbols_per_ctx: float
    top10_ctx: list[tuple[int, int]] = field(default_factory=list)
    error: str | None = None


# --- Decision rule (spec §5) ---------------------------------------------

def classify_outcome(results: list[CandidateResult]) -> tuple[str, str]:
    """Return (case_label, narrative) per spec §5."""
    valid = [r for r in results if r.error is None]
    by_name = {r.name: r for r in valid}
    if "c0" not in by_name:
        return ("error",
                "c0 baseline failed; aborting decision rule.")
    c0 = by_name["c0"]
    # Compute size for each candidate (just the body; full file size
    # would add HDF5 framing + non-quality bytes).
    # We compare CANDIDATE qualities body vs CRAM TOTAL FILE SIZE,
    # extrapolating the rest of the .tio (non-qualities) via the
    # known L1+L3 baseline from chr22-byte-breakdown.md §7:
    #   pre-L2 file = 113.72 MB; qualities = 69.73 MB; non-quals = 44.0 MB
    #   For each candidate: total = qualities_body + 44.0 MB (approx)
    NON_QUALS_BYTES = 113_720_000 - 69_730_000  # ~44 MB
    def total_for(r: CandidateResult) -> int:
        return r.body_bytes + NON_QUALS_BYTES
    def ratio_for(r: CandidateResult) -> float:
        return total_for(r) / CRAM_BYTES

    # Sort by total ascending
    sorted_results = sorted(valid, key=total_for)
    best = sorted_results[0]
    best_ratio = ratio_for(best)

    bit_pack_winners = [r for r in valid
                        if r.name in {"c1", "c2", "c3"}
                        and ratio_for(r) <= GATE_RATIO]
    c4_passes = "c4" in by_name and ratio_for(by_name["c4"]) <= GATE_RATIO
    c0_ratio = ratio_for(c0)

    if bit_pack_winners:
        winner = min(bit_pack_winners, key=total_for)
        return ("bit_pack_winner",
                f"Bit-pack candidate **{winner.name}** hits "
                f"{ratio_for(winner):.4f}x CRAM <= 1.15x. "
                f"Stage 2 spec around {winner.name}'s bit budget + "
                f"feature set. Bit-pack discipline preserved.")
    if c4_passes:
        return ("hash_only",
                f"Only c4 (SplitMix64 hash) hits "
                f"{ratio_for(by_name['c4']):.4f}x CRAM <= 1.15x; no "
                f"bit-pack candidate does. Escalate Stage 2 to hash "
                f"discipline (Option A in brainstorming).")
    if best_ratio < c0_ratio - 1e-4:
        return ("all_fail_recharter",
                f"Best candidate **{best.name}** lands at "
                f"{best_ratio:.4f}x CRAM, between V3's "
                f"{c0_ratio:.4f}x and the 1.15x target. All "
                f"candidates fail the hard gate. Re-charter Task #84: "
                f"extend feature set (distance_from_end, mate-pair, "
                f"error-context) or renegotiate the v1.2.0 gate.")
    return ("no_improvement",
            f"Best candidate **{best.name}** at "
            f"{best_ratio:.4f}x CRAM matches or exceeds c0's "
            f"{c0_ratio:.4f}x. Fundamental model wrong; brainstorm "
            f"again from scratch.")


# --- Main ----------------------------------------------------------------

def _git_head() -> str:
    try:
        r = subprocess.run(
            ["git", "-C", "/home/toddw/TTI-O", "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, check=True,
        )
        return r.stdout.strip()
    except Exception:
        return "unknown"


def _diagnostic_stats(sparse_seq: np.ndarray) -> tuple[int, float, list[tuple[int,int]]]:
    """Return (distinct_ctx_count, mean_symbols_per_ctx, top10)."""
    if sparse_seq.size == 0:
        return (0, 0.0, [])
    vals, counts = np.unique(sparse_seq, return_counts=True)
    distinct = int(vals.shape[0])
    mean_per = float(sparse_seq.size) / max(distinct, 1)
    order = np.argsort(-counts)[:10]
    top10 = [(int(vals[i]), int(counts[i])) for i in order]
    return (distinct, mean_per, top10)


def main() -> int:
    if not _HAVE_NATIVE_LIB:
        print("ERROR: libttio_rans not loaded. Set "
              "TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so",
              file=sys.stderr)
        return 1

    print(f"[harness] git HEAD: {_git_head()}")
    print(f"[harness] host: {socket.gethostname()} {platform.system()} {platform.release()}")
    print(f"[harness] loading {CHR22_BAM} ...")
    t0 = time.perf_counter()
    run = BamReader(CHR22_BAM).to_genomic_run(name="run_0001")
    bam_load_s = time.perf_counter() - t0
    print(f"[harness] BAM->GenomicRun: {bam_load_s:.2f}s")

    qualities = bytes(run.qualities.tobytes())
    read_lengths = np.asarray([int(x) for x in run.lengths], dtype=np.int64)
    revcomp_flags = np.asarray(
        [1 if (int(f) & SAM_REVERSE_FLAG) else 0 for f in run.flags],
        dtype=np.int64,
    )
    n = len(qualities)
    pad = pad_count_for(n)
    n_padded = n + pad
    print(f"[harness] n_qualities={n:,} n_reads={read_lengths.shape[0]:,} "
          f"pad={pad}")

    results: list[CandidateResult] = []
    for name, sloc, derive, desc in CANDIDATES:
        print(f"[harness] running {name} (sloc={sloc}) ...")
        t0 = time.perf_counter()
        try:
            sparse, _ = derive(qualities, read_lengths, revcomp_flags, n_padded)
            er = encode_with_kernel(qualities, sparse, n_padded, sloc)
            wall = time.perf_counter() - t0
            distinct, mean_per, top10 = _diagnostic_stats(sparse)
            results.append(CandidateResult(
                name=name, sloc=sloc, description=desc,
                body_bytes=len(er.body_bytes),
                n_active=er.n_active,
                encode_wall_s=wall,
                distinct_ctx_count=distinct,
                mean_symbols_per_ctx=mean_per,
                top10_ctx=top10,
            ))
            print(f"[harness]   {name}: body={len(er.body_bytes)/1e6:.4f} MB "
                  f"n_active={er.n_active} wall={wall:.2f}s")
        except Exception as e:
            print(f"[harness]   {name}: FAILED — {e}", file=sys.stderr)
            results.append(CandidateResult(
                name=name, sloc=sloc, description=desc,
                body_bytes=0, n_active=0, encode_wall_s=0.0,
                distinct_ctx_count=0, mean_symbols_per_ctx=0.0,
                error=str(e),
            ))

    case, narrative = classify_outcome(results)
    write_results_doc(results, case, narrative, bam_load_s)
    print(f"[harness] §5 outcome: {case}")
    print(f"[harness] {narrative}")
    print(f"[harness] results doc: {RESULTS_PATH}")
    return 0


def write_results_doc(
    results: list[CandidateResult],
    case: str,
    narrative: str,
    bam_load_s: float,
) -> None:
    head = _git_head()
    host = socket.gethostname()
    NON_QUALS_BYTES = 113_720_000 - 69_730_000
    lines: list[str] = []
    lines.append("# M94.Z V4 candidate prototype — chr22 results")
    lines.append("")
    lines.append(f"- Date: 2026-05-02")
    lines.append(f"- Host: {host} ({platform.system()} {platform.release()})")
    lines.append(f"- Git HEAD: `{head}`")
    lines.append(f"- BAM load: {bam_load_s:.2f}s")
    lines.append(f"- Spec: `docs/superpowers/specs/2026-05-02-l2x-m94z-richer-context-stage1-design.md`")
    lines.append("")
    lines.append("## Per-candidate compression")
    lines.append("")
    lines.append("Total file size = qualities body + ~44 MB non-qualities "
                 "(constant across candidates, from chr22 L1+L3 baseline). "
                 "Ratio is total / CRAM 3.1 (86.094 MB).")
    lines.append("")
    lines.append("| Candidate | Description | Body MB | Total MB | × CRAM | Pass 1.15x | Encode s |")
    lines.append("|---|---|---:|---:|---:|---|---:|")
    for r in results:
        if r.error:
            lines.append(f"| {r.name} | {r.description} | — | — | — | error | — |")
            continue
        body_mb = r.body_bytes / 1e6
        total_mb = (r.body_bytes + NON_QUALS_BYTES) / 1e6
        ratio = total_mb / 86.094
        passes = "✓" if ratio <= 1.15 else "✗"
        lines.append(
            f"| {r.name} | {r.description} | {body_mb:.4f} | {total_mb:.4f} | "
            f"{ratio:.4f} | {passes} | {r.encode_wall_s:.2f} |"
        )
    lines.append("")
    lines.append("## Per-candidate diagnostics")
    lines.append("")
    lines.append("| Candidate | sloc | n_active | distinct_ctx | symbols/ctx |")
    lines.append("|---|---:|---:|---:|---:|")
    for r in results:
        if r.error:
            continue
        lines.append(
            f"| {r.name} | {r.sloc} | {r.n_active} | {r.distinct_ctx_count} | "
            f"{r.mean_symbols_per_ctx:.0f} |"
        )
    lines.append("")
    lines.append("## Top-10 most-frequent contexts per candidate")
    lines.append("")
    for r in results:
        if r.error or not r.top10_ctx:
            continue
        lines.append(f"### {r.name}")
        lines.append("")
        lines.append("| Rank | Context ID | Count |")
        lines.append("|---:|---:|---:|")
        for rank, (ctx_id, count) in enumerate(r.top10_ctx, 1):
            lines.append(f"| {rank} | {ctx_id} | {count:,} |")
        lines.append("")
    lines.append("## §5 decision-rule outcome")
    lines.append("")
    lines.append(f"**Case:** `{case}`")
    lines.append("")
    lines.append(narrative)
    lines.append("")
    lines.append("## Errors")
    lines.append("")
    any_err = False
    for r in results:
        if r.error:
            any_err = True
            lines.append(f"- {r.name}: `{r.error}`")
    if not any_err:
        lines.append("(none)")
    lines.append("")
    lines.append("## Deferred verification")
    lines.append("")
    lines.append("Round-trip verification (decode + byte-equality of recovered")
    lines.append("qualities vs input, per spec §6.4 + §8 acceptance criterion #3)")
    lines.append("was not run in Stage 1. The compressed-size numbers are")
    lines.append("indicative — they reflect what the V3 RC kernel produced for")
    lines.append("each candidate's sparse_seq, not whether decode-side context")
    lines.append("re-derivation can recover the input. **If Stage 2 ever opens,")
    lines.append("the winning candidate must be round-trip-verified before any")
    lines.append("production work.**")
    lines.append("")
    os.makedirs(os.path.dirname(RESULTS_PATH), exist_ok=True)
    with open(RESULTS_PATH, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
