"""Unit tests for the M93 ReferenceResolver."""
from __future__ import annotations

import contextlib
import hashlib
from pathlib import Path

import h5py
import numpy as np
import pytest

from ttio.genomic.reference_resolver import (
    ReferenceResolver,
    RefMissingError,
)
from ttio.providers.hdf5 import Hdf5Provider


@pytest.fixture
def tmp_h5(tmp_path):
    return tmp_path / "with_ref.tio"


def _seed_embedded_ref(path: Path, uri: str, chrom: str, seq: bytes, md5: bytes):
    with h5py.File(path, "w") as f:
        grp = f.create_group(f"/study/references/{uri}")
        grp.attrs["md5"] = md5.hex()
        grp.attrs["reference_uri"] = uri
        chroms = grp.create_group("chromosomes")
        c = chroms.create_group(chrom)
        c.attrs["length"] = len(seq)
        c.create_dataset("data", data=np.frombuffer(seq, dtype=np.uint8))


@contextlib.contextmanager
def _references_group(path: Path):
    """Yield the ``/study/references`` StorageGroup for a seeded file.

    Yields ``None`` when the file has no ``/study/references`` subtree
    (e.g. an empty file used to exercise the external-FASTA fallback).
    """
    provider = Hdf5Provider.open(str(path))
    try:
        root = provider.root_group()
        if root.has_child("study"):
            study = root.open_group("study")
            if study.has_child("references"):
                yield study.open_group("references")
                return
        yield None
    finally:
        provider.close()


def test_resolver_finds_embedded_reference(tmp_h5):
    seq = b"ACGTACGTAC"
    md5 = hashlib.md5(seq).digest()
    _seed_embedded_ref(tmp_h5, "test-uri", "22", seq, md5)
    with _references_group(tmp_h5) as refs:
        r = ReferenceResolver(refs)
        assert r.resolve(uri="test-uri", expected_md5=md5, chromosome="22") == seq


def test_resolver_md5_mismatch_raises(tmp_h5):
    seq = b"ACGT"
    bad_md5 = b"\x00" * 16
    _seed_embedded_ref(tmp_h5, "test-uri", "22", seq, hashlib.md5(seq).digest())
    with _references_group(tmp_h5) as refs:
        r = ReferenceResolver(refs)
        with pytest.raises(RefMissingError, match="MD5 mismatch"):
            r.resolve(uri="test-uri", expected_md5=bad_md5, chromosome="22")


def test_resolver_chromosome_not_embedded_raises(tmp_h5):
    seq = b"ACGT"
    md5 = hashlib.md5(seq).digest()
    _seed_embedded_ref(tmp_h5, "test-uri", "22", seq, md5)
    with _references_group(tmp_h5) as refs:
        r = ReferenceResolver(refs)
        with pytest.raises(RefMissingError, match="not embedded"):
            r.resolve(uri="test-uri", expected_md5=md5, chromosome="X")


def test_resolver_external_fallback(tmp_h5, tmp_path, monkeypatch):
    # Empty file — no embedded refs.
    with h5py.File(tmp_h5, "w"):
        pass

    fasta_seq = b"ACGTACGT"
    fasta = tmp_path / "ref.fa"
    fasta.write_bytes(b">22\n" + fasta_seq + b"\n")
    monkeypatch.setenv("REF_PATH", str(fasta))

    md5 = hashlib.md5(fasta_seq).digest()
    with _references_group(tmp_h5) as refs:
        r = ReferenceResolver(refs)
        assert r.resolve(uri="any", expected_md5=md5, chromosome="22") == fasta_seq


def test_resolver_external_md5_mismatch_raises(tmp_h5, tmp_path, monkeypatch):
    with h5py.File(tmp_h5, "w"):
        pass
    fasta = tmp_path / "ref.fa"
    fasta.write_bytes(b">22\nACGT\n")
    monkeypatch.setenv("REF_PATH", str(fasta))
    with _references_group(tmp_h5) as refs:
        r = ReferenceResolver(refs)
        with pytest.raises(RefMissingError, match="MD5 mismatch"):
            r.resolve(uri="any", expected_md5=b"\x00" * 16, chromosome="22")


def test_resolver_explicit_external_overrides_env(tmp_path, monkeypatch):
    bogus = tmp_path / "bogus.fa"
    bogus.write_bytes(b">22\nGGGG\n")
    real = tmp_path / "real.fa"
    real_seq = b"ACGTACGT"
    real.write_bytes(b">22\n" + real_seq + b"\n")
    monkeypatch.setenv("REF_PATH", str(bogus))  # should be ignored

    r = ReferenceResolver(references_group=None, external_reference_path=real)
    assert r.resolve(uri="any", expected_md5=hashlib.md5(real_seq).digest(),
                     chromosome="22") == real_seq


def test_resolver_missing_everywhere_raises(monkeypatch):
    monkeypatch.delenv("REF_PATH", raising=False)
    r = ReferenceResolver(references_group=None)
    with pytest.raises(RefMissingError, match="not found"):
        r.resolve(uri="missing", expected_md5=b"\x00" * 16, chromosome="22")


def test_resolver_finds_correct_chrom_in_multi_chrom_fasta(tmp_path, monkeypatch):
    """FASTA reader must skip past unrelated chromosomes."""
    fasta = tmp_path / "multi.fa"
    fasta.write_bytes(
        b">21\nGGGG\n"
        b">22\nACGTACGT\n"
        b">X\nTTTT\n"
    )
    monkeypatch.setenv("REF_PATH", str(fasta))

    expected_seq = b"ACGTACGT"
    md5 = hashlib.md5(expected_seq).digest()
    r = ReferenceResolver(references_group=None)
    assert r.resolve(uri="x", expected_md5=md5, chromosome="22") == expected_seq
