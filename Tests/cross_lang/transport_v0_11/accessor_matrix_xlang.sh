#!/usr/bin/env bash
# v0.11 transport-spec cross-language conformance matrix driver.
#
# Plan §4.2 — for each (writer_lang, reader_lang) ∈ {java, python, objc}²
# and each first-class accessor (REFERENCES, MS_RUNS, GENOMIC_RUNS,
# IMAGE, IDENTIFICATIONS, QUANTIFICATIONS, DATASET_PROVENANCE,
# ENCRYPTION_ALGORITHM, plus Stage 5 / Task 5.6 entries
# MS_IMAGE_PROCESSED, RAMAN_IMAGE, IR_IMAGE, plus Stage 6 / Task 6.6
# entries SUBJECTS, SAMPLES), encode .tio → .tis via the writer's
# CLI, decode .tis → .tio via the reader's CLI, and verify the
# per-accessor comparator passes (logical content equivalence).
#
# 13 accessors × 9 directional pairs = 117 cells per run; plus 3
# bytes-equal-across-decoders cells = 120 total.
#
# Drives the Python pytest harness at
# ``python/tests/conformance/test_transport_v0_11_xlang.py`` (Option B
# of Stage 4 task 4.2). The pytest module is the source of truth for
# fixture builders, comparators, and CLI invocation; this shim keeps
# the plan's "one bash entrypoint" promise.
#
# Usage:
#   bash Tests/cross_lang/transport_v0_11/accessor_matrix_xlang.sh
#
# Exit 0 on success, non-zero on any cell failure or skip-due-to-
# environment-gap that the caller declared not skippable.
#
# Environment knobs:
#   TTIO_RANS_LIB_PATH — absolute path to libttio_rans.so to opt in to
#     GENOMIC_RUNS coverage on the Python side. Without it, the 3
#     GENOMIC_RUNS-involving pairs are skipped, not failed.
#   PYTEST — python interpreter or pytest entrypoint override.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../../.." && pwd)"

PYTEST="${PYTEST:-python3}"

cd "${REPO_ROOT}/python"
exec "${PYTEST}" -m pytest \
    tests/conformance/test_transport_v0_11_xlang.py \
    -v --tb=short \
    "$@"
