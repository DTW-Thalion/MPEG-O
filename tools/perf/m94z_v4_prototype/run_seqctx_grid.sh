#!/usr/bin/env bash
# Qualities-V5 bake-off grid. Throwaway; writes /tmp/v5bake/grid.log.
set -u
cd /tmp/v5bake
BIN=./fqzcomp_seqctx_ref
LOG=grid.log
: > $LOG

run() {  # corpus, args...
    local c=$1; shift
    echo -n "CORPUS=$c " >> $LOG
    $BIN ${c}_qual.bin ${c}_seq.bin ${c}_lens.bin "$@" >> $LOG \
        || echo "FAILED $c $*" >> $LOG
}

for c in wes chr22 hifi x250; do
    # baselines
    run $c --qbits 8  --qshift 5 --pbits 7
    run $c --qbits 10 --qshift 5 --pbits 7
    # seq window incl. current base, on the 15-bit base (8+7)
    run $c --qbits 8 --qshift 5 --pbits 7 --seq-mode 1 --sbits 2
    run $c --qbits 8 --qshift 5 --pbits 7 --seq-mode 1 --sbits 3
    # displacement variants: trade qbits for seq bits at 16 total
    run $c --qbits 6 --qshift 5 --pbits 7 --seq-mode 1 --sbits 4
    run $c --qbits 4 --qshift 5 --pbits 7 --seq-mode 1 --sbits 6
    # 18-bit widened: richer q history + seq
    run $c --qbits 10 --qshift 5 --pbits 7 --seq-mode 1 --sbits 1
    run $c --qbits 8 --qshift 5 --pbits 7 --seq-mode 1 --sbits 4
    run $c --qbits 8 --qshift 5 --pbits 7 --seq-mode 1 --sbits 6
    # predecessors-only window
    run $c --qbits 8 --qshift 5 --pbits 7 --seq-mode 2 --sbits 4
    # hashed k-mers
    run $c --qbits 8 --qshift 5 --pbits 7 --seq-mode 3 --khash 6 --sbits 6
    run $c --qbits 8 --qshift 5 --pbits 7 --seq-mode 3 --khash 8 --sbits 6
done
echo DONE >> $LOG
