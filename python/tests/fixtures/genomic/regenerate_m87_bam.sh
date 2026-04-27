#!/usr/bin/env bash
# Regenerate the M87 BAM fixture from the authoritative SAM source.
#
# The .bam file is committed; the .bai index is committed alongside
# because samtools' region-filter requires it for BAM input.
#
# Note on read ordering: m87_test.sam declares @HD SO:coordinate, so
# the reads MUST appear in coordinate-sort order
# (r000, r001, r002, r008, r009 on chr1 by position; then r003, r004
# on chr2 by position; then unmapped r005, r006, r007). This
# differs from the source-order layout (r000..r009) that the original
# M87 HANDOFF spec listed; the SAM file is the authoritative ground
# truth — do not "fix" the read order back to source order, that
# would invalidate the SO:coordinate header and break samtools index.
set -euo pipefail
cd "$(dirname "$0")"
# coordinate-sorted output is required for indexing.
samtools sort -O bam -o m87_test.bam m87_test.sam
samtools index m87_test.bam
echo "Regenerated m87_test.bam ($(wc -c < m87_test.bam) bytes)"
echo "Regenerated m87_test.bam.bai ($(wc -c < m87_test.bam.bai) bytes)"
