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


def test_set_md5_sidecar_cache(tmp_path):
    import hashlib, os, time
    from ttio.genomic.lazy_reference import LazyReference
    fa = tmp_path / "r.fa"
    fa.write_bytes(b">b\nGGGG\n>a\nacgt\n")
    want = hashlib.md5(b"acgt" + b"GGGG").digest()
    ref = LazyReference(fa)
    assert ref.set_md5() == want
    side = tmp_path / "r.fa.ttio-md5"
    st = fa.stat()
    assert side.read_text().split() == [want.hex(), str(st.st_size), str(int(st.st_mtime))]
    # a fresh instance takes the sidecar; a wrong sidecar is recomputed
    assert LazyReference(fa).set_md5() == want
    side.write_text("00" * 16 + f" {st.st_size} {int(st.st_mtime)}\n")
    assert LazyReference(fa).set_md5() == bytes(16)   # trusted while size and mtime match
    side.write_text("00" * 16 + " 1 1\n")
    assert LazyReference(fa).set_md5() == want         # stale stamp: recomputed and rewritten
    assert side.read_text().split()[0] == want.hex()
