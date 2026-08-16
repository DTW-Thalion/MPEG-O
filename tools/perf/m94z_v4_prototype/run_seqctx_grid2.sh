#!/usr/bin/env bash
# Supplement: the combos the first grid rejected for exceeding the
# 18-bit context cap, rebudgeted to fit (seq bits displace pos bits).
set -u
cd /tmp/v5bake
BIN=./fqzcomp_seqctx_ref
LOG=grid2.log
: > $LOG

run() {
    local c=$1; shift
    echo -n "CORPUS=$c " >> $LOG
    $BIN ${c}_qual.bin ${c}_seq.bin ${c}_lens.bin "$@" >> $LOG \
        || echo "FAILED $c $*" >> $LOG
}

for c in wes chr22 hifi x250; do
    run $c --qbits 8 --qshift 5 --pbits 6 --seq-mode 1 --sbits 4
    run $c --qbits 8 --qshift 5 --pbits 4 --seq-mode 1 --sbits 6
    run $c --qbits 8 --qshift 5 --pbits 6 --seq-mode 2 --sbits 4
    run $c --qbits 8 --qshift 5 --pbits 4 --seq-mode 3 --khash 6 --sbits 6
    run $c --qbits 8 --qshift 5 --pbits 4 --seq-mode 3 --khash 8 --sbits 6
done
echo DONE >> $LOG
