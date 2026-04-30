"""Driver for the M92 compression-benchmark harness."""
from __future__ import annotations

import json
import platform
import socket
import subprocess
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path

from .datasets import Dataset
from .formats import ADAPTERS, Result


@dataclass
class DatasetRunSummary:
    dataset: str
    bam_input_bytes: int
    started_at_unix: float
    host: dict[str, str] = field(default_factory=dict)
    formats: dict[str, dict[str, dict]] = field(default_factory=dict)


def _capture_host_metadata() -> dict[str, str]:
    info: dict[str, str] = {
        "hostname": socket.gethostname(),
        "platform": platform.platform(),
        "python": platform.python_version(),
    }
    try:
        out_bytes = subprocess.check_output(
            ["samtools", "--version"], stderr=subprocess.STDOUT
        )
        out = out_bytes.decode("utf-8", errors="replace")
        info["samtools"] = out.splitlines()[0].strip()
    except (FileNotFoundError, subprocess.CalledProcessError):
        info["samtools"] = "not available"
    try:
        from ttio import __version__ as ttio_version  # type: ignore[attr-defined]
    except ImportError:
        ttio_version = "unknown"
    except AttributeError:
        ttio_version = "unknown"
    info["ttio"] = ttio_version
    return info


def run_one(
    format_name: str,
    dataset: Dataset,
    work_dir: Path,
) -> dict[str, dict]:
    """Run compress + decompress for one format on one dataset.

    Returns a dict with ``compress`` and ``decompress`` sub-dicts.
    """
    if format_name not in ADAPTERS:
        raise KeyError(
            f"Unknown format {format_name!r}. Supported: {sorted(ADAPTERS)}"
        )
    adapter = ADAPTERS[format_name]
    work_dir.mkdir(parents=True, exist_ok=True)

    compressed = work_dir / f"{dataset.name}{adapter['ext']}"
    decompressed = work_dir / f"{dataset.name}.{format_name}.dump.sam"

    out: dict[str, dict] = {}
    try:
        c_result: Result = adapter["compress"](
            dataset.bam_path, dataset.reference_fasta, compressed
        )
        out["compress"] = asdict(c_result)
    except Exception as exc:  # pragma: no cover — surfaced to report
        out["compress"] = {"error": str(exc)}
        return out

    try:
        d_result: Result = adapter["decompress"](
            compressed, dataset.reference_fasta, decompressed
        )
        out["decompress"] = asdict(d_result)
    except Exception as exc:  # pragma: no cover
        out["decompress"] = {"error": str(exc)}

    return out


def run_dataset(
    dataset: Dataset,
    formats: list[str],
    work_dir: Path,
) -> DatasetRunSummary:
    if not dataset.bam_path.exists():
        raise FileNotFoundError(
            f"BAM input missing: {dataset.bam_path}. "
            f"Run `dvc pull data/genomic/{dataset.bam_path.parent.name}/` "
            f"or see docs/benchmarks/datasets.md."
        )

    summary = DatasetRunSummary(
        dataset=dataset.name,
        bam_input_bytes=dataset.bam_path.stat().st_size,
        started_at_unix=time.time(),
        host=_capture_host_metadata(),
    )
    for fmt in formats:
        summary.formats[fmt] = run_one(fmt, dataset, work_dir / fmt)
    return summary


def write_json_report(summary: DatasetRunSummary, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(asdict(summary), indent=2, default=str))
