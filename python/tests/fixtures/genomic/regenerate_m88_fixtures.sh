#!/usr/bin/env bash
# Regenerate the M88 test fixtures from the authoritative SAM source
# and the synthetic 2-chromosome reference FASTA.
#
# Inputs (committed):
#   m88_test_reference.fa  -- 2 chromosomes, 1000 bases each
#                             chr1 = "ACGT" repeated, chr2 = "TGCA" repeated
#   m88_test.sam           -- 5 perfect-match reads aligned to that reference
#
# Outputs (committed for offline testing):
#   m88_test_reference.fa.fai    -- samtools faidx index
#   m88_test.bam                 -- coordinate-sorted BAM
#   m88_test.bam.bai             -- BAM index (region filter requires it)
#   m88_test.cram                -- coordinate-sorted CRAM
#   m88_test.cram.crai           -- CRAM index (region filter requires it)
set -euo pipefail
cd "$(dirname "$0")"

# 1) FASTA index (samtools auto-builds if missing; build deterministically here).
samtools faidx m88_test_reference.fa

# 2) BAM: sort by coordinate so samtools index succeeds.
samtools sort -O bam -o m88_test.bam m88_test.sam
samtools index m88_test.bam

# 3) CRAM: reference-compressed, coordinate-sorted.
samtools view -CS --reference m88_test_reference.fa m88_test.sam \
    | samtools sort -O cram --reference m88_test_reference.fa -o m88_test.cram -
samtools index m88_test.cram

echo "Regenerated m88_test_reference.fa.fai ($(wc -c < m88_test_reference.fa.fai) bytes)"
echo "Regenerated m88_test.bam              ($(wc -c < m88_test.bam) bytes)"
echo "Regenerated m88_test.bam.bai          ($(wc -c < m88_test.bam.bai) bytes)"
echo "Regenerated m88_test.cram             ($(wc -c < m88_test.cram) bytes)"
echo "Regenerated m88_test.cram.crai        ($(wc -c < m88_test.cram.crai) bytes)"
