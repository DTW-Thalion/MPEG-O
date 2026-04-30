"""Dataset descriptors for the M92 compression-benchmark harness.

Each dataset names a BAM file (the canonical uncompressed-ish
input), an associated reference FASTA (required by CRAM and TTI-O
when reference-compressed paths are exercised), and an expected
read count for sanity checks. Paths are resolved relative to the
repo root unless absolute.

Datasets are committed via DVC under ``data/genomic/``; see
``docs/benchmarks/datasets.md`` for the fetch protocol.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Dataset:
    name: str
    bam_path: Path
    reference_fasta: Path
    description: str
    expected_read_count: int | None = None


REPO_ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = REPO_ROOT / "data" / "genomic"


DATASETS: dict[str, Dataset] = {
    "chr22_na12878": Dataset(
        name="chr22_na12878",
        bam_path=DATA_DIR / "na12878" / "na12878.chr22.bam",
        reference_fasta=DATA_DIR / "reference" / "hs37.chr22.fa",
        description=(
            "NA12878 WGS, chr22 only — RAW (full aux tags). Source: "
            "1000 Genomes phase3 low-coverage NA12878. Inflates "
            "CRAM (BQ tag is 100 char/read) — see chr22_na12878_lean."
        ),
    ),
    "chr22_na12878_lean": Dataset(
        name="chr22_na12878_lean",
        bam_path=DATA_DIR / "na12878" / "na12878.chr22.lean.bam",
        reference_fasta=DATA_DIR / "reference" / "hs37.chr22.fa",
        description=(
            "NA12878 chr22 with all aux tags stripped except RG. "
            "Apples-to-apples for TTI-O (whose M82 schema models "
            "only core SAM fields, not aux tags)."
        ),
    ),
    "chr22_na12878_mapped": Dataset(
        name="chr22_na12878_mapped",
        bam_path=DATA_DIR / "na12878" / "na12878.chr22.lean.mapped.bam",
        reference_fasta=DATA_DIR / "reference" / "hs37.chr22.fa",
        description=(
            "NA12878 chr22 lean (aux-stripped) + mapped-only "
            "(samtools view -F 4 → drops 0.82% unmapped reads). "
            "Required for REF_DIFF benchmark — REF_DIFF requires "
            "all reads have aligned cigars; the M93.X sub-channel "
            "routing for unmapped reads ships in a future milestone."
        ),
    ),
    "wgs_na12878_downsampled": Dataset(
        name="wgs_na12878_downsampled",
        bam_path=DATA_DIR / "na12878" / "na12878.wgs.0.05x.bam",
        reference_fasta=DATA_DIR / "reference" / "GRCh38.fa",
        description=(
            "NA12878 WGS at 0.05x — full-genome coverage, downsampled "
            "to keep per-format runs under ~30 minutes. Source: GiaB."
        ),
    ),
    "wes_err194147": Dataset(
        name="wes_err194147",
        bam_path=DATA_DIR / "err194147" / "err194147.bam",
        reference_fasta=DATA_DIR / "reference" / "GRCh38.fa",
        description=(
            "ERR194147 whole-exome capture (Platinum Genomes). "
            "Smaller than WGS; tests the WES path."
        ),
    ),
    "synthetic_mixed_chrom": Dataset(
        name="synthetic_mixed_chrom",
        bam_path=DATA_DIR / "synthetic" / "mixed_chrom.bam",
        reference_fasta=DATA_DIR / "synthetic" / "mixed_chrom.fa",
        description=(
            "Synthetic mixed-chromosome dataset generated from "
            "tools/benchmarks/synthetic.py. Deterministic seed; "
            "exercises every chromosome including the small ones. "
            "Reference is the synthesized FASTA (not real GRCh38)."
        ),
    ),
}


def get(name: str) -> Dataset:
    if name not in DATASETS:
        raise KeyError(
            f"Unknown dataset {name!r}. Available: {sorted(DATASETS)}"
        )
    return DATASETS[name]


def available() -> list[str]:
    return sorted(DATASETS)
