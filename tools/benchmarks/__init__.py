"""M92 compression-benchmark harness.

Cross-format compression comparison for genomic data: TTI-O vs BAM
vs CRAM 3.1 vs MPEG-G (Genie). Distinct from ``tools/perf/`` —
that tree profiles read-path latency in the three reference
implementations; this tree measures compressed file size and
end-to-end (de)compression throughput across formats on the same
inputs.

Usage::

    python -m tools.benchmarks.cli run \\
        --dataset chr22_na12878 \\
        --formats ttio,bam,cram,genie \\
        --report docs/benchmarks/v1.2.0-report.md

See ``docs/benchmarks/datasets.md`` for dataset acquisition and
``docs/benchmarks/environment.md`` for Genie + samtools setup.
"""
