"""LazyReference index and digest tests."""
from __future__ import annotations


def test_build_fai_text_matches_samtools(tmp_path):
    from ttio.genomic.lazy_reference import LazyReference, build_fai_text
    fa = tmp_path / "r.fa"
    fa.write_bytes(b">chrA desc\nACGTAC\nGTAC\n>chrB\n\n>chrC\nGG\n")
    text = build_fai_text(fa)
    assert text == "chrA\t10\t11\t6\t7\nchrB\t0\t29\t0\t0\nchrC\t2\t36\t2\t3\n"
    (tmp_path / "r.fa.fai").write_text(text)
    ref = LazyReference(fa)
    assert ref["chrA"] == b"ACGTACGTAC" and ref["chrB"] == b"" and ref["chrC"] == b"GG"
    import hashlib
    assert ref.set_md5() == hashlib.md5(b"ACGTACGTAC" + b"" + b"GG").digest()
