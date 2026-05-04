"""Layer 2 — ref_diff v2 v1↔v2 oracle for chr22.

Extract sequences + cigars + positions from chr22 BAM. Encode + decode
through ref_diff_v2; assert byte-exact equality with the original
sequences.
"""
from __future__ import annotations

import hashlib
from pathlib import Path

import numpy as np
import pytest

from ttio.codecs import ref_diff_v2 as rdv2

if not rdv2.HAVE_NATIVE_LIB:
    pytest.skip("requires native libttio_rans.so via TTIO_RANS_LIB_PATH",
                allow_module_level=True)

from ._mate_info_corpus import (
    extract_sequences_for_ref_diff,
    load_chr22_reference,
)

CORPORA = {
    "chr22": (
        "data/genomic/na12878/na12878.chr22.lean.mapped.bam",
        "data/genomic/reference/hs37.chr22.fa",
    ),
}


@pytest.mark.integration
@pytest.mark.parametrize("corpus_name,paths", list(CORPORA.items()))
def test_ref_diff_v2_round_trip(corpus_name, paths):
    bam_rel, fasta_rel = paths
    repo = Path(__file__).parents[3]
    bam = repo / bam_rel
    fasta = repo / fasta_rel
    if not bam.exists():
        pytest.skip(f"corpus not on disk: {bam}")
    if not fasta.exists():
        pytest.skip(f"reference not on disk: {fasta}")

    seq, off, pos, cigars = extract_sequences_for_ref_diff(bam)
    n = pos.shape[0]
    assert n > 0, f"empty corpus {corpus_name}"

    reference = load_chr22_reference(fasta)
    md5 = hashlib.md5(reference).digest()

    encoded = rdv2.encode(seq, off, pos, cigars, reference, md5,
                          reference_uri=corpus_name)
    assert encoded[:4] == b"RDF2"

    out_seq, out_off = rdv2.decode(encoded, pos, cigars, reference,
                                    n_reads=n, total_bases=int(off[n]))

    np.testing.assert_array_equal(seq, out_seq,
        err_msg=f"{corpus_name}: sequences mismatch")
    np.testing.assert_array_equal(off, out_off,
        err_msg=f"{corpus_name}: offsets mismatch")

    raw_size = int(off[n])
    print(f"\n{corpus_name}: n={n:,}, total_bases={raw_size:,}, "
          f"encoded={len(encoded):,}, ratio={raw_size / len(encoded):.2f}x  "
          f"({len(encoded)/raw_size:.4f} B/base)")
