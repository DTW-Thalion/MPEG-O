"""Layer 2 — v1<->v2 oracle for mate_info v2 (chr22).

For each corpus, extract the mate triple from the BAM, encode through
mate_info_v2, decode, assert byte-exact equality.

Catches encoder/decoder asymmetry without an external reference
implementation. Other 3 corpora (WES, HG002 Illumina, HG002 PacBio)
will be wired in T11 when the cross-language gate lands.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ttio.codecs import mate_info_v2 as miv2

if not miv2.HAVE_NATIVE_LIB:
    pytest.skip("requires native libttio_rans.so via TTIO_RANS_LIB_PATH",
                allow_module_level=True)

# Reuse the corpus helper.
from ._mate_info_corpus import extract_mate_triples

CORPORA = {
    "chr22":          "data/genomic/na12878/na12878.chr22.lean.mapped.bam",
    "wes":            "data/genomic/na12878_wes/na12878_wes.chr22.bam",
    "hg002_illumina": "data/genomic/hg002_illumina/hg002_illumina.chr22.subset1m.bam",
    "hg002_pacbio":   "data/genomic/hg002_pacbio/hg002_pacbio.subset.bam",
}


@pytest.mark.integration
@pytest.mark.parametrize("corpus_name,corpus_path", list(CORPORA.items()))
def test_v1_v2_oracle(corpus_name, corpus_path):
    bam = Path(__file__).parents[3] / corpus_path
    if not bam.exists():
        pytest.skip(f"corpus not on disk: {bam}")

    mc, mp, ts, oc, op = extract_mate_triples(bam)
    n = mc.shape[0]
    assert n > 0, f"empty corpus {corpus_name}"

    encoded = miv2.encode(mc, mp, ts, oc, op)
    mc2, mp2, ts2 = miv2.decode(encoded, oc, op, n_records=n)

    np.testing.assert_array_equal(mc, mc2,
        err_msg=f"{corpus_name}: mate_chrom_ids mismatch")
    np.testing.assert_array_equal(mp, mp2,
        err_msg=f"{corpus_name}: mate_positions mismatch")
    np.testing.assert_array_equal(ts, ts2,
        err_msg=f"{corpus_name}: template_lengths mismatch")

    # Log compression ratio so the test output documents the benefit.
    raw_size = n * (4 + 8 + 4)  # int32 + int64 + int32 per record
    print(f"\n{corpus_name}: n={n}, raw={raw_size:,}, encoded={len(encoded):,}, "
          f"ratio={raw_size / len(encoded):.2f}x  ({len(encoded)/n:.2f} B/rec)")
