#!/usr/bin/env bash
# Phase 3 byte-equality helper: encode each corpus with our auto-tune
# (strategy_hint = -1) and htscodecs's auto-tune (gp == NULL), compare
# bytes. Exit 0 iff all match; non-zero otherwise.
#
# Usage:
#   tools/perf/htscodecs_compare.sh
#
# Prereqs (built in WSL):
#   native/_build/test_fqzcomp_qual_autotune
#   tools/perf/m94z_v4_prototype/fqzcomp_htscodecs_ref_autotune
#   .venv/bin/python with the ttio package importable
set -uo pipefail

REPO=/home/toddw/TTI-O
OUR_BIN=$REPO/native/_build/test_fqzcomp_qual_autotune
HTSCODECS_BIN=$REPO/tools/perf/m94z_v4_prototype/fqzcomp_htscodecs_ref_autotune
PY=$REPO/.venv/bin/python

if [ ! -x "$OUR_BIN" ]; then
    echo "FATAL: $OUR_BIN not found; build native/_build first" >&2
    exit 2
fi
if [ ! -x "$HTSCODECS_BIN" ]; then
    echo "FATAL: $HTSCODECS_BIN not found; compile fqzcomp_htscodecs_ref_autotune.c first" >&2
    exit 2
fi
if [ ! -x "$PY" ]; then
    echo "FATAL: $PY not found; create .venv with ttio installed" >&2
    exit 2
fi

declare -a CORPORA=(
  "chr22:$REPO/data/genomic/na12878/na12878.chr22.lean.mapped.bam"
  "wes:$REPO/data/genomic/na12878_wes/na12878_wes.chr22.bam"
  "hg002_illumina:$REPO/data/genomic/hg002_illumina/hg002_illumina.chr22.subset1m.bam"
  "hg002_pacbio:$REPO/data/genomic/hg002_pacbio/hg002_pacbio.subset.bam"
)

ALL_OK=1
SKIPPED=0
PASSED=0
FAILED=0

for entry in "${CORPORA[@]}"; do
    name="${entry%%:*}"
    bam="${entry#*:}"
    echo "=== $name ==="
    echo "    bam: $bam"
    if [ ! -f "$bam" ]; then
        echo "    SKIP: BAM not present"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Extract inputs (idempotent; overwrites /tmp files).
    cd "$REPO" || exit 2
    if ! "$PY" -m tools.perf.m94z_v4_prototype.extract_chr22_inputs \
            --bam "$bam" --out-prefix "/tmp/${name}_v4" >/dev/null; then
        echo "    FAIL: extraction failed"
        FAILED=$((FAILED + 1))
        ALL_OK=0
        continue
    fi

    qbytes=$(stat -c%s "/tmp/${name}_v4_qual.bin")
    nreads=$(($(stat -c%s "/tmp/${name}_v4_lens.bin") / 4))
    echo "    qualities: $qbytes  reads: $nreads"

    # Our encoder
    if ! "$OUR_BIN" \
            "/tmp/${name}_v4_qual.bin" \
            "/tmp/${name}_v4_lens.bin" \
            "/tmp/${name}_v4_flags.bin" \
            "/tmp/our_${name}_v4.fqz" 2>"/tmp/our_${name}_v4.log"; then
        echo "    FAIL: our encoder failed:"
        sed 's/^/      /' "/tmp/our_${name}_v4.log"
        FAILED=$((FAILED + 1))
        ALL_OK=0
        continue
    fi
    our_bytes=$(stat -c%s "/tmp/our_${name}_v4.fqz")

    # htscodecs auto-tune
    if ! "$HTSCODECS_BIN" \
            "/tmp/${name}_v4_qual.bin" \
            "/tmp/${name}_v4_lens.bin" \
            "/tmp/${name}_v4_flags.bin" \
            "/tmp/htscodecs_${name}_v4.fqz" 2>"/tmp/htscodecs_${name}_v4.log"; then
        echo "    FAIL: htscodecs encoder failed:"
        sed 's/^/      /' "/tmp/htscodecs_${name}_v4.log"
        FAILED=$((FAILED + 1))
        ALL_OK=0
        continue
    fi
    hts_bytes=$(stat -c%s "/tmp/htscodecs_${name}_v4.fqz")

    bpqual=$(awk "BEGIN { printf \"%.4f\", $our_bytes / $qbytes }")
    echo "    our:       $our_bytes bytes (B/qual=$bpqual)"
    echo "    htscodecs: $hts_bytes bytes"

    if cmp -s "/tmp/our_${name}_v4.fqz" "/tmp/htscodecs_${name}_v4.fqz"; then
        echo "    PASS: BYTE-EQUAL + round-trip OK"
        PASSED=$((PASSED + 1))
    else
        echo "    FAIL: DIFFER"
        # First differing byte for debugging
        cmp "/tmp/our_${name}_v4.fqz" "/tmp/htscodecs_${name}_v4.fqz" | sed 's/^/      /'
        FAILED=$((FAILED + 1))
        ALL_OK=0
    fi
done

echo
echo "Summary: passed=$PASSED failed=$FAILED skipped=$SKIPPED"
if [ $ALL_OK -eq 1 ] && [ $PASSED -gt 0 ]; then
    echo "ALL CORPORA: BYTE-EQUAL"
    exit 0
else
    echo "FAILURE: at least one corpus differs (or none ran)"
    exit 1
fi
