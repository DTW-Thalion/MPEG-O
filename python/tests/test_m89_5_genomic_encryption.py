"""M89.5: per-AU encryption verified on the GenomicRead suffix.

The transport-spec §4.3.2/3 channel-level AES-GCM doesn't care about
AU semantics — it operates on opaque payload bytes. M89.5 closes the
loop by exercising the full encrypt → wire → decrypt → parse pipeline
for genomic AUs (and a mixed MS+genomic batch) so any sequence-class-
specific bug in encryption gets caught here.

These tests use the low-level encrypt_bytes/decrypt_bytes primitives
directly against AccessUnit.to_bytes() output. The file-level
encrypt_per_au_file does not yet support genomic_runs in the writer
(scope: deferred to M90); this test is the unit-level proof that
nothing in the AU codec assumes a particular spectrum_class for
encryption.
"""
from __future__ import annotations

import pytest

pytest.importorskip("cryptography")

from ttio.encryption import SealedBlob, decrypt_bytes, encrypt_bytes
from ttio.transport.packets import AccessUnit, ChannelData


KEY = b"\x42" * 32  # 256-bit test key
IV = b"\x11" * 12   # deterministic nonce for repeatability


def _genomic_au(
    *, chromosome: str, position: int, mapq: int, flags: int,
    sequence: bytes, qualities: bytes,
) -> AccessUnit:
    return AccessUnit(
        spectrum_class=5,
        acquisition_mode=0, ms_level=0, polarity=2,
        retention_time=0.0, precursor_mz=0.0, precursor_charge=0,
        ion_mobility=0.0, base_peak_intensity=0.0,
        channels=[
            ChannelData("sequences", 6, 0, len(sequence), sequence),
            ChannelData("qualities", 6, 0, len(qualities), qualities),
        ],
        chromosome=chromosome, position=position,
        mapping_quality=mapq, flags=flags,
    )


def _ms_au(*, rt: float, ms_level: int) -> AccessUnit:
    return AccessUnit(
        spectrum_class=0,
        acquisition_mode=0, ms_level=ms_level, polarity=0,
        retention_time=rt, precursor_mz=0.0, precursor_charge=0,
        ion_mobility=0.0, base_peak_intensity=100.0,
        channels=[],
    )


def _round_trip(plaintext: bytes) -> bytes:
    blob = encrypt_bytes(plaintext, KEY, iv=IV)
    return decrypt_bytes(blob, KEY)


class TestGenomicAuEncryption:

    def test_round_trip_preserves_suffix(self):
        au = _genomic_au(
            chromosome="chr1", position=123_456_789,
            mapq=60, flags=0x0003,
            sequence=b"ACGTACGT", qualities=bytes([30] * 8),
        )
        decoded = AccessUnit.from_bytes(_round_trip(au.to_bytes()))
        assert decoded.chromosome == "chr1"
        assert decoded.position == 123_456_789
        assert decoded.mapping_quality == 60
        assert decoded.flags == 0x0003
        assert decoded.spectrum_class == 5

    def test_round_trip_preserves_channels(self):
        au = _genomic_au(
            chromosome="chr2", position=42, mapq=55, flags=0x0001,
            sequence=b"AAAANNNN", qualities=bytes([20] * 8),
        )
        decoded = AccessUnit.from_bytes(_round_trip(au.to_bytes()))
        assert len(decoded.channels) == 2
        assert decoded.channels[0].name == "sequences"
        assert decoded.channels[0].data == b"AAAANNNN"
        assert decoded.channels[1].name == "qualities"
        assert decoded.channels[1].data == bytes([20] * 8)

    def test_round_trip_unmapped_read(self):
        au = _genomic_au(
            chromosome="*", position=-1, mapq=0, flags=0x0004,
            sequence=b"NNNNNN", qualities=bytes([2] * 6),
        )
        decoded = AccessUnit.from_bytes(_round_trip(au.to_bytes()))
        assert decoded.chromosome == "*"
        assert decoded.position == -1
        assert decoded.flags == 0x0004

    def test_long_chromosome_round_trip(self):
        long_chr = "chr22_KI270739v1_random"
        au = _genomic_au(
            chromosome=long_chr, position=1000, mapq=40, flags=0x0001,
            sequence=b"GGGG", qualities=bytes([35] * 4),
        )
        decoded = AccessUnit.from_bytes(_round_trip(au.to_bytes()))
        assert decoded.chromosome == long_chr

    def test_tampered_ciphertext_rejected(self):
        au = _genomic_au(
            chromosome="chr1", position=100, mapq=60, flags=0x0003,
            sequence=b"ACGT", qualities=bytes([30] * 4),
        )
        blob = encrypt_bytes(au.to_bytes(), KEY, iv=IV)
        # Flip one bit in the ciphertext — AES-GCM's tag MUST detect it.
        tampered_ct = bytes([blob.ciphertext[0] ^ 0x01]) + blob.ciphertext[1:]
        tampered = SealedBlob(tampered_ct, blob.iv, blob.tag)
        with pytest.raises(Exception):
            decrypt_bytes(tampered, KEY)

    def test_wrong_key_rejected(self):
        au = _genomic_au(
            chromosome="chr1", position=100, mapq=60, flags=0x0003,
            sequence=b"ACGT", qualities=bytes([30] * 4),
        )
        blob = encrypt_bytes(au.to_bytes(), KEY, iv=IV)
        with pytest.raises(Exception):
            decrypt_bytes(blob, b"\x00" * 32)


class TestMixedBatchEncryption:
    """Confirms encryption is sequence-class-agnostic: MS and genomic
    AUs both round-trip through the same AES-GCM primitive without
    any class-specific code path."""

    def test_ms_and_genomic_both_round_trip(self):
        ms_au = _ms_au(rt=1.5, ms_level=2)
        gen_au = _genomic_au(
            chromosome="chr3", position=500, mapq=50, flags=0x0001,
            sequence=b"TTTT", qualities=bytes([15] * 4),
        )
        ms_decoded = AccessUnit.from_bytes(_round_trip(ms_au.to_bytes()))
        gen_decoded = AccessUnit.from_bytes(_round_trip(gen_au.to_bytes()))
        assert ms_decoded.spectrum_class == 0
        assert ms_decoded.retention_time == pytest.approx(1.5)
        assert ms_decoded.ms_level == 2
        assert gen_decoded.spectrum_class == 5
        assert gen_decoded.chromosome == "chr3"
        assert gen_decoded.position == 500

    def test_ciphertext_lengths_differ_appropriately(self):
        # Genomic AUs are larger than MS-only AUs by the suffix size
        # (chromosome string + 11 bytes fixed). Encrypted lengths
        # mirror the plaintext lengths (AES-GCM is a stream cipher).
        ms_pt = _ms_au(rt=0.0, ms_level=1).to_bytes()
        gen_pt = _genomic_au(
            chromosome="chr1", position=0, mapq=0, flags=0,
            sequence=b"", qualities=b"",
        ).to_bytes()
        # Genomic AU has 2 extra empty channels (sequences, qualities)
        # AND the genomic suffix; expected delta:
        #   2 channels × (2 namelen + name_bytes + 10 suffix) + suffix
        #   = 2 * (2 + 9 + 10)  + (2 + len("chr1") + 8 + 1 + 2)
        #   = 42 + 17 = 59 bytes longer than MS-only.
        assert len(gen_pt) > len(ms_pt)
        ms_blob = encrypt_bytes(ms_pt, KEY, iv=IV)
        gen_blob = encrypt_bytes(gen_pt, KEY, iv=IV)
        assert len(gen_blob.ciphertext) - len(ms_blob.ciphertext) == \
            len(gen_pt) - len(ms_pt)
