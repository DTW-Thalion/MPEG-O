"""M90.4: per-AU encryption keyed by chromosome (region-based).

The novel piece of the M90 series. Encrypt chr6 (HLA) with K1, leave
chr1 in clear, encrypt chrX with K2 — all in one .tio file. Per-AU
dispatch on the genomic_index chromosomes column.

Schema: reuses the M90.1 ``<channel>_segments`` compound. Clear AUs
encode as a segment with ``len(iv) == 0`` (empty IV/tag, ciphertext
holds raw plaintext bytes). Encrypted AUs store the standard AES-GCM
12-byte IV + 16-byte tag + AEAD ciphertext. The decoder branches on
``len(iv)`` — old M90.1 files (every IV is 12 bytes) decode unchanged
under the new code path.

API:
    encrypt_per_au_by_region(path, key_map: dict[chr, key])
    decrypt_per_au_by_region(path, key_map: dict[chr, key])

A read whose chromosome has no key_map entry is stored clear. A
read whose chromosome has a key is AES-GCM encrypted with that
key. Caller may supply a key_map subset on decrypt — clear AUs
return plaintext without needing any key; encrypted AUs whose key
isn't supplied fail loudly via InvalidTag.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

pytest.importorskip("cryptography")
pytest.importorskip("h5py")

from ttio import SpectralDataset
from ttio.encryption_per_au import (
    decrypt_per_au_by_region,
    encrypt_per_au_by_region,
)
from ttio.written_genomic_run import WrittenGenomicRun


KEY_HLA = b"\x42" * 32        # for chr6
KEY_X = b"\x77" * 32          # for chrX
WRONG = b"\xFF" * 32


def _make_genomic_dataset(path: Path) -> Path:
    """6 reads: 2 chr1 (clear), 2 chr6 (HLA), 2 chrX."""
    n = 6
    L = 8
    chromosomes = ["chr1", "chr1", "chr6", "chr6", "chrX", "chrX"]
    sequences_concat = (
        b"AAAAAAAA"   # chr1 read 0
        b"TTTTTTTT"   # chr1 read 1
        b"GGGGGGGG"   # chr6 read 0
        b"CCCCCCCC"   # chr6 read 1
        b"NNNNNNNN"   # chrX read 0
        b"ACGTACGT"   # chrX read 1
    )
    qualities_concat = bytes()
    for i in range(n):
        qualities_concat += bytes([20 + i] * L)

    run = WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="NA12878",
        positions=np.array([100, 200, 1000, 1100, 5000, 5100], dtype=np.int64),
        mapping_qualities=np.full(n, 60, dtype=np.uint8),
        flags=np.full(n, 0x0003, dtype=np.uint32),
        sequences=np.frombuffer(sequences_concat, dtype=np.uint8),
        qualities=np.frombuffer(qualities_concat, dtype=np.uint8),
        offsets=np.arange(n, dtype=np.uint64) * L,
        lengths=np.full(n, L, dtype=np.uint32),
        cigars=[f"{L}M"] * n,
        read_names=[f"r{i:03d}" for i in range(n)],
        mate_chromosomes=[""] * n,
        mate_positions=np.full(n, -1, dtype=np.int64),
        template_lengths=np.zeros(n, dtype=np.int32),
        chromosomes=chromosomes,
    )
    SpectralDataset.write_minimal(
        path,
        title="M90.4 region encryption fixture",
        isa_investigation_id="ISA-M90-4",
        runs={},
        genomic_runs={"genomic_0001": run},
    )
    return path


class TestEncryptByRegion:

    def test_clear_chromosomes_have_empty_iv(self, tmp_path):
        """A read on chr1 (no key in map) must be stored as a clear
        segment (empty IV / empty tag / plaintext bytes in ciphertext)."""
        path = _make_genomic_dataset(tmp_path / "src.tio")
        encrypt_per_au_by_region(str(path), {"chr6": KEY_HLA})
        # Inspect raw segments via the IO layer.
        from ttio import _hdf5_io as io
        from ttio.providers.registry import open_provider
        sp = open_provider(str(path), mode="r")
        try:
            sig = sp.root_group().open_group(
                "study"
            ).open_group("genomic_runs").open_group(
                "genomic_0001"
            ).open_group("signal_channels")
            segs = io.read_channel_segments(sig, "sequences_segments")
            # chr1 reads (indices 0,1) -> empty IV.
            assert len(segs[0].iv) == 0, "chr1 read 0 should be clear"
            assert len(segs[1].iv) == 0, "chr1 read 1 should be clear"
            # chr6 reads (2,3) -> 12-byte IV (encrypted).
            assert len(segs[2].iv) == 12
            assert len(segs[3].iv) == 12
            # chrX reads (4,5) -> empty IV (no key supplied).
            assert len(segs[4].iv) == 0
            assert len(segs[5].iv) == 0
        finally:
            sp.close()

    def test_decrypt_with_only_chr6_key_returns_plaintext_for_clear(self, tmp_path):
        """Caller supplies only KEY_HLA. chr1 + chrX reads come back
        as plaintext (no key needed); chr6 reads decrypt with KEY_HLA."""
        path = _make_genomic_dataset(tmp_path / "rt.tio")
        encrypt_per_au_by_region(str(path), {"chr6": KEY_HLA})
        result = decrypt_per_au_by_region(str(path), {"chr6": KEY_HLA})
        seqs = result["genomic_0001"]["sequences"]
        # 6 reads × 8 bases = 48 bytes total.
        assert len(seqs) == 48
        # Bytes 0-7 (chr1 read 0) are 'A's clear.
        assert seqs[0:8].tobytes() == b"AAAAAAAA"
        # Bytes 16-23 (chr6 read 0) decrypted to 'G's.
        assert seqs[16:24].tobytes() == b"GGGGGGGG"
        # Bytes 40-47 (chrX read 1) clear.
        assert seqs[40:48].tobytes() == b"ACGTACGT"

    def test_two_keys_chr6_and_chrx(self, tmp_path):
        """Encrypt chr6 with KEY_HLA, chrX with KEY_X. chr1 stays clear."""
        path = _make_genomic_dataset(tmp_path / "two.tio")
        encrypt_per_au_by_region(
            str(path), {"chr6": KEY_HLA, "chrX": KEY_X},
        )
        result = decrypt_per_au_by_region(
            str(path), {"chr6": KEY_HLA, "chrX": KEY_X},
        )
        seqs = result["genomic_0001"]["sequences"]
        assert seqs[0:8].tobytes() == b"AAAAAAAA"   # chr1 clear
        assert seqs[16:24].tobytes() == b"GGGGGGGG"  # chr6 decrypted
        assert seqs[32:40].tobytes() == b"NNNNNNNN"  # chrX decrypted

    def test_missing_key_for_encrypted_region_fails(self, tmp_path):
        """Encrypted under KEY_HLA, decrypt with empty key_map → fails
        loudly on the chr6 segments (clear segments still decode)."""
        path = _make_genomic_dataset(tmp_path / "miss.tio")
        encrypt_per_au_by_region(str(path), {"chr6": KEY_HLA})
        # Empty key_map: chr1 + chrX clear segments decode fine, but
        # chr6 encrypted segments have no key to use.
        with pytest.raises(Exception):
            decrypt_per_au_by_region(str(path), {})

    def test_wrong_key_fails(self, tmp_path):
        """Encrypted under KEY_HLA, decrypt with wrong key → fails."""
        path = _make_genomic_dataset(tmp_path / "wk.tio")
        encrypt_per_au_by_region(str(path), {"chr6": KEY_HLA})
        with pytest.raises(Exception):
            decrypt_per_au_by_region(str(path), {"chr6": WRONG})

    def test_qualities_dispatch_same_way(self, tmp_path):
        """Both sequences and qualities get the same per-AU dispatch."""
        path = _make_genomic_dataset(tmp_path / "q.tio")
        encrypt_per_au_by_region(str(path), {"chr6": KEY_HLA})
        result = decrypt_per_au_by_region(str(path), {"chr6": KEY_HLA})
        quals = result["genomic_0001"]["qualities"]
        # Per-read distinct: read i has Phred (20+i) repeated.
        assert quals[0:8].tobytes() == bytes([20] * 8)   # chr1 clear
        assert quals[16:24].tobytes() == bytes([22] * 8)  # chr6 decrypted
        assert quals[40:48].tobytes() == bytes([25] * 8)  # chrX clear

    def test_empty_keymap_leaves_everything_clear(self, tmp_path):
        """key_map={} means no chromosome has a key — file should
        still pass through both encrypt + decrypt as a no-op (all
        segments clear)."""
        path = _make_genomic_dataset(tmp_path / "noop.tio")
        encrypt_per_au_by_region(str(path), {})
        result = decrypt_per_au_by_region(str(path), {})
        seqs = result["genomic_0001"]["sequences"]
        # Original concatenated layout preserved end-to-end.
        assert seqs.tobytes() == (
            b"AAAAAAAA" b"TTTTTTTT" b"GGGGGGGG"
            b"CCCCCCCC" b"NNNNNNNN" b"ACGTACGT"
        )
