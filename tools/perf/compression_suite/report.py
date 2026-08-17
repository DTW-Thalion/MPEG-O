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
    verify_note: str = ""


def aggregate(results_dir: Path) -> dict[str, dict[tuple[str, str], Agg]]:
    out: dict[str, dict[tuple[str, str], Agg]] = {}
    for f in sorted(Path(results_dir).glob("*/*.json")):
        r = json.loads(f.read_text())
        a = Agg(tier=r["tier"], input_bytes=r.get("input_bytes", 0), output_bytes=r.get("output_bytes", 0),
                encode_s=r.get("encode_s", 0.0), decode_s=r.get("decode_s", 0.0),
                rss_mb=max(r.get("encode_rss_mb", 0.0), r.get("decode_rss_mb", 0.0)),
                bases=r.get("bases", 0) or 0, verify="PASS" if r.get("verify") == "PASS" else "FAIL",
                lossy=r.get("lossy", False), tool_version=r.get("tool_version", ""),
                max_rel_error=r.get("max_rel_error"), breakdown=dict(r.get("breakdown") or {}),
                verify_note=r.get("verify_note") or r.get("error") or "")
        out.setdefault(r["corpus"], {})[(r["format"], r["kind"])] = a
    return out


def _fmt_bytes(n: int) -> str:
    return f"{n:,}"


def render(agg: dict, env: dict) -> str:
    lines = ["# Compression benchmark report", "",
             f"Generated {env.get('date')} on {env.get('cpu')}; {env.get('ram', '')} RAM; {env.get('kernel', '')}.",
             "Every size in the headline and per-corpus tables has a passing decode-verify. Rows marked FAIL show no size there; each corpus section lists its failed rows with the reason.", ""]
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
        failed = [(k, a) for k, a in sorted(table.items()) if a.verify != "PASS"]
        if failed:
            lines += ["Rows that failed verification (bytes shown for reference only, not comparable):", "",
                      "| format | kind | bytes | reason |", "|---|---|---:|---|"]
            for (key, kind), a in failed:
                lines.append(f"| {key} | {kind} | {_fmt_bytes(a.output_bytes)} | {a.verify_note or 'decode differs from input'} |")
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
