# M92 Compression Benchmarks

Cross-format compression comparison for genomic data: TTI-O vs
BAM vs CRAM 3.1 vs MPEG-G (Genie). The acceptance gate for v1.2.0
is "TTI-O within 15% of CRAM 3.1 on lossless paths".

> Distinct from [`tools/perf/`](../perf/) — that tree profiles
> read-path latency in the three reference implementations; this
> tree measures end-to-end compressed file size and (de)compression
> throughput across formats on the same inputs.

## Quick start

```bash
# 1. Verify the environment (samtools + Genie + Python ttio).
python -m tools.benchmarks.cli list

# 2. Run all formats on the small chr22 fixture.
python -m tools.benchmarks.cli run \
    --dataset chr22_na12878 \
    --formats bam,cram,ttio,genie \
    --report docs/benchmarks/v1.2.0-report.md \
    --json-out tools/benchmarks/results.json

# 3. Run the full suite (slower — WGS 0.05x can take ~30 min/format).
python -m tools.benchmarks.cli run \
    --dataset all \
    --formats bam,cram,ttio,genie \
    --report docs/benchmarks/v1.2.0-report.md
```

## Datasets

- `chr22_na12878` — NA12878 chr22 only (~50 MB BAM). Iteration default.
- `wgs_na12878_downsampled` — full-genome 0.05x coverage. Headline.
- `wes_err194147` — Platinum Genomes whole-exome capture.
- `synthetic_mixed_chrom` — deterministic synthesis via `synthetic.py`.

Fetch via `dvc pull data/genomic/<dataset>/`. See
[`docs/benchmarks/datasets.md`](../../docs/benchmarks/datasets.md)
for sources, checksums, and downsampling commands.

## Formats

| Adapter | Tooling | Implementation |
|---|---|---|
| `bam` | `samtools view -b` | identity-ish baseline; BGZF re-pack |
| `cram` | `samtools view -C --output-fmt-option version=3.1` | CRAM 3.1 lossless, no embedded reference |
| `ttio` | Python `ttio` package | `BamReader.to_genomic_run` → `SpectralDataset.write_minimal` |
| `genie` | `genie run` | MPEG-G reference. See [environment.md](../../docs/benchmarks/environment.md) for build instructions |

Adapters live in [`formats.py`](formats.py); add a new one by
implementing `compress(bam, ref, out)` and `decompress(in, ref, out)`
returning a `Result` and registering in `ADAPTERS`.

## Output

The runner writes:

- `--json-out` — machine-readable per-(dataset,format,operation)
  records: wall time, sizes, command line, notes, host metadata.
- `--report` — Markdown report with one table per dataset.

The Markdown report is regenerated from JSON; commit only the
JSON if you want to keep history without churning the report.
