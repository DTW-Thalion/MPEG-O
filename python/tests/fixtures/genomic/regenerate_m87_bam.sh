#!/usr/bin/env bash
# Regenerate the M87 BAM fixture from the authoritative SAM source.
#
# The .bam file is committed; the .bai index is committed alongside
# because samtools' region-filter requires it for BAM input.
set -euo pipefail
cd "$(dirname "$0")"
# coordinate-sorted output is required for indexing.
samtools sort -O bam -o m87_test.bam m87_test.sam
samtools index m87_test.bam
echo "Regenerated m87_test.bam ($(wc -c < m87_test.bam) bytes)"
echo "Regenerated m87_test.bam.bai ($(wc -c < m87_test.bam.bai) bytes)"
