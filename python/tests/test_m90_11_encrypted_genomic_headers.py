"""M90.11: encrypted genomic AU headers with per-region key map.

Closes gap #5 from the post-M90 analysis: the genomic_index columns
(chromosomes, positions, mapping_qualities, flags) stayed PLAINTEXT
under M90.1/M90.4, so a reader without any signal-channel key could
still see read locations + counts + mate-pair structure. M90.11
adds the option to encrypt those columns under a separate
``"_headers"`` key in the key_map.

Threat model (option Q2 (b) from gap analysis): an analyst with
``K_HLA`` can decrypt chr6 sequences (M90.4) but cannot see chr1
positions unless they ALSO hold ``K_HEADERS``.

API:
    encrypt_per_au_by_region(path, key_map={
        "_headers": K_HEADERS,    # encrypts genomic_index columns
        "chr6":     K_HLA,        # encrypts chr6 sequences/qualities
    })

The presence of the reserved ``"_headers"`` entry is the opt-in
signal. Decrypt requires the ``"_headers"`` key on files carrying
``opt_encrypted_au_headers``; missing it raises a clear error.

offsets and lengths stay plaintext under all paths — they are
structural framing, not semantic PHI.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

pytest.importorskip("cryptography")
pytest.importorskip("h5py")

import h5py

from ttio import SpectralDataset
from ttio.encryption_per_au import (
    decrypt_per_au_by_region,
    encrypt_per_au_by_region,
)
from ttio.feature_flags import OPT_ENCRYPTED_AU_HEADERS
from ttio.written_genomic_run import WrittenGenomicRun


KEY_HEADERS = b"\x11" * 32
KEY_HLA = b"\x42" * 32
KEY_X = b"\x77" * 32


def _make_genomic_dataset(path: Path) -> Path:
    """4 reads: 2 chr1, 2 chr6."""
    n = 4
    L = 8
    chromosomes = ["chr1", "chr1", "chr6", "chr6"]
    positions = np.array([100, 200, 1000, 1100], dtype=np.int64)
    flags = np.array([0x0003, 0x0083, 0x0003, 0x0083], dtype=np.uint32)
    mapqs = np.array([60, 55, 40, 50], dtype=np.uint8)
    sequences = np.frombuffer(b"AAAAAAAA" b"TTTTTTTT" b"GGGGGGGG" b"CCCCCCCC",
                                dtype=np.uint8)
    qualities = np.frombuffer(bytes([20] * (n * L)), dtype=np.uint8)
    run = WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="NA12878",
        positions=positions,
        mapping_qualities=mapqs,
        flags=flags,
        sequences=sequences,
        qualities=qualities,
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
        title="M90.11 encrypted-headers fixture",
        isa_investigation_id="ISA-M90-11",
        runs={},
        genomic_runs={"genomic_0001": run},
    )
    return path


class TestEncryptHeaders:

    def test_headers_key_strips_plaintext_index_columns(self, tmp_path):
        path = _make_genomic_dataset(tmp_path / "src.tio")
        encrypt_per_au_by_region(str(path), {"_headers": KEY_HEADERS})
        with h5py.File(path, "r") as f:
            idx = f["/study/genomic_runs/genomic_0001/genomic_index"]
            # Plaintext columns should be gone.
            assert "positions" not in idx, "positions should be encrypted"
            assert "mapping_qualities" not in idx
            assert "flags" not in idx
            assert "chromosomes" not in idx
            # Encrypted blobs should be present.
            assert "positions_encrypted" in idx
            assert "mapping_qualities_encrypted" in idx
            assert "flags_encrypted" in idx
            assert "chromosomes_encrypted" in idx
            # offsets/lengths stay plaintext (structural framing).
            assert "offsets" in idx
            assert "lengths" in idx
            # opt_encrypted_au_headers feature flag set.
            features = f["/"].attrs.get("ttio_features") or ""
            if isinstance(features, bytes):
                features = features.decode("utf-8")
            assert OPT_ENCRYPTED_AU_HEADERS in str(features)

    def test_round_trip_recovers_index_columns(self, tmp_path):
        path = _make_genomic_dataset(tmp_path / "rt.tio")
        encrypt_per_au_by_region(str(path), {"_headers": KEY_HEADERS})
        plain = decrypt_per_au_by_region(
            str(path), {"_headers": KEY_HEADERS},
        )
        # Decrypt returns the index columns alongside any decrypted
        # signal channels (no signal keys in this test → no signal data).
        idx = plain["genomic_0001"]["__index__"]
        assert idx["chromosomes"] == ["chr1", "chr1", "chr6", "chr6"]
        np.testing.assert_array_equal(
            idx["positions"],
            np.array([100, 200, 1000, 1100], dtype=np.int64),
        )
        np.testing.assert_array_equal(
            idx["mapping_qualities"],
            np.array([60, 55, 40, 50], dtype=np.uint8),
        )
        np.testing.assert_array_equal(
            idx["flags"],
            np.array([0x0003, 0x0083, 0x0003, 0x0083], dtype=np.uint32),
        )

    def test_decrypt_without_headers_key_fails(self, tmp_path):
        path = _make_genomic_dataset(tmp_path / "no.tio")
        encrypt_per_au_by_region(str(path), {"_headers": KEY_HEADERS})
        with pytest.raises(ValueError, match=r"_headers"):
            decrypt_per_au_by_region(str(path), {})

    def test_decrypt_with_wrong_headers_key_fails(self, tmp_path):
        path = _make_genomic_dataset(tmp_path / "wk.tio")
        encrypt_per_au_by_region(str(path), {"_headers": KEY_HEADERS})
        with pytest.raises(Exception):
            decrypt_per_au_by_region(str(path), {"_headers": b"\xFF" * 32})


class TestComposeWithRegionEncryption:
    """M90.11 + M90.4 compose: caller can encrypt headers AND
    encrypt chr6 sequences with a separate region key."""

    def test_combined_headers_and_region_encryption(self, tmp_path):
        path = _make_genomic_dataset(tmp_path / "combo.tio")
        encrypt_per_au_by_region(
            str(path),
            {"_headers": KEY_HEADERS, "chr6": KEY_HLA},
        )
        # Decrypt with both keys recovers everything.
        plain = decrypt_per_au_by_region(
            str(path),
            {"_headers": KEY_HEADERS, "chr6": KEY_HLA},
        )
        idx = plain["genomic_0001"]["__index__"]
        assert idx["chromosomes"] == ["chr1", "chr1", "chr6", "chr6"]
        # Sequences for ALL reads come back (chr1 clear, chr6
        # decrypted with KEY_HLA). 4 reads × 8 bases = 32 bytes.
        seqs = plain["genomic_0001"]["sequences"]
        assert len(seqs) == 32
        assert seqs[0:8].tobytes() == b"AAAAAAAA"   # chr1 clear
        assert seqs[16:24].tobytes() == b"GGGGGGGG"  # chr6 decrypted

    def test_partial_keys_cannot_recover_index(self, tmp_path):
        """Holding only K_HLA (no _headers) cannot recover positions
        even if chr6 sequences are still decryptable in principle."""
        path = _make_genomic_dataset(tmp_path / "partial.tio")
        encrypt_per_au_by_region(
            str(path),
            {"_headers": KEY_HEADERS, "chr6": KEY_HLA},
        )
        with pytest.raises(ValueError, match=r"_headers"):
            decrypt_per_au_by_region(str(path), {"chr6": KEY_HLA})


class TestNoOpWithoutHeadersKey:
    """When key_map has region keys but no '_headers', the index
    columns must STAY plaintext — preserves M90.4 backward
    compatibility."""

    def test_region_only_keymap_preserves_plaintext_index(self, tmp_path):
        path = _make_genomic_dataset(tmp_path / "noheaders.tio")
        encrypt_per_au_by_region(str(path), {"chr6": KEY_HLA})
        with h5py.File(path, "r") as f:
            idx = f["/study/genomic_runs/genomic_0001/genomic_index"]
            assert "positions" in idx
            assert "mapping_qualities" in idx
            assert "flags" in idx
            assert "chromosomes" in idx
            assert "positions_encrypted" not in idx
            features = f["/"].attrs.get("ttio_features") or ""
            if isinstance(features, bytes):
                features = features.decode("utf-8")
            assert OPT_ENCRYPTED_AU_HEADERS not in str(features)
