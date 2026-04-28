"""M90.8: encrypted-transport extension for genomic_runs.

The M90.1 file-level per-AU encryption walks /study/genomic_runs/.
The M89.2 transport codec also walks genomic_runs. M90.8 extends the
*encrypted* variant of the transport flow (transport/encrypted.py)
so an encrypted .tio carrying genomic_runs can be streamed through
.tis and re-materialised on the other side preserving the encrypted
ciphertext bytes verbatim (no decrypt in transit, matching the MS
encrypted-transport contract).
"""
from __future__ import annotations

import io
from pathlib import Path

import numpy as np
import pytest

pytest.importorskip("cryptography")
pytest.importorskip("h5py")

from ttio import SpectralDataset
from ttio.encryption_per_au import decrypt_per_au_file, encrypt_per_au_file
from ttio.transport.codec import TransportWriter
from ttio.transport.encrypted import (
    is_per_au_encrypted,
    read_encrypted_to_file,
    write_encrypted_dataset,
)
from ttio.written_genomic_run import WrittenGenomicRun


KEY = b"\x42" * 32


def _make_genomic_dataset(path: Path) -> Path:
    n = 4
    L = 8
    sequences = np.frombuffer(b"ACGTACGT" * n, dtype=np.uint8)
    qualities = np.frombuffer(bytes([30] * (n * L)), dtype=np.uint8)
    run = WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="NA12878",
        positions=np.array([100, 200, 300, 400], dtype=np.int64),
        mapping_qualities=np.full(n, 60, dtype=np.uint8),
        flags=np.full(n, 0x0003, dtype=np.uint32),
        sequences=sequences,
        qualities=qualities,
        offsets=np.arange(n, dtype=np.uint64) * L,
        lengths=np.full(n, L, dtype=np.uint32),
        cigars=[f"{L}M"] * n,
        read_names=[f"read_{i:03d}" for i in range(n)],
        mate_chromosomes=[""] * n,
        mate_positions=np.full(n, -1, dtype=np.int64),
        template_lengths=np.zeros(n, dtype=np.int32),
        chromosomes=["chr1", "chr1", "chr2", "chr2"],
    )
    SpectralDataset.write_minimal(
        path,
        title="M90.8 enc-transport genomic fixture",
        isa_investigation_id="ISA-M90-8",
        runs={},
        genomic_runs={"genomic_0001": run},
    )
    return path


class TestEncryptedTransportGenomic:

    def test_round_trip_preserves_decryptable_ciphertext(self, tmp_path):
        # Build + encrypt source.
        src = _make_genomic_dataset(tmp_path / "src.tio")
        encrypt_per_au_file(str(src), KEY)
        assert is_per_au_encrypted(src)

        # Stream through encrypted transport.
        stream = io.BytesIO()
        with TransportWriter(stream) as tw:
            write_encrypted_dataset(tw, str(src))
        stream.seek(0)

        # Materialise to a new .tio.
        out_path = tmp_path / "rt.tio"
        meta = read_encrypted_to_file(stream, out_path)
        assert "genomic_0001" in meta["runs"], (
            f"genomic_0001 missing; got: {list(meta['runs'].keys())}"
        )

        # Decrypt the output and confirm byte-exact recovery.
        plain = decrypt_per_au_file(str(out_path), KEY)
        assert "genomic_0001" in plain
        np.testing.assert_array_equal(
            plain["genomic_0001"]["sequences"],
            np.frombuffer(b"ACGTACGT" * 4, dtype=np.uint8),
        )
        np.testing.assert_array_equal(
            plain["genomic_0001"]["qualities"],
            np.full(32, 30, dtype=np.uint8),
        )

    def test_mixed_ms_and_genomic_round_trip(self, tmp_path):
        from ttio.spectral_dataset import WrittenRun
        from ttio.enums import AcquisitionMode, Polarity

        # Build mixed fixture (1 MS run + 1 genomic run).
        ms_n = 2
        ms_pts = 4
        mz = np.arange(ms_n * ms_pts, dtype="<f8") + 100.0
        intensity = np.arange(ms_n * ms_pts, dtype="<f8") + 1.0
        ms_run = WrittenRun(
            spectrum_class="TTIOMassSpectrum",
            acquisition_mode=int(AcquisitionMode.MS1_DDA),
            channel_data={"mz": mz, "intensity": intensity},
            offsets=np.array([0, ms_pts], dtype="<u8"),
            lengths=np.full(ms_n, ms_pts, dtype="<u4"),
            retention_times=np.array([1.0, 2.0], dtype="<f8"),
            ms_levels=np.ones(ms_n, dtype="<i4"),
            polarities=np.full(ms_n, int(Polarity.POSITIVE), dtype="<i4"),
            precursor_mzs=np.zeros(ms_n, dtype="<f8"),
            precursor_charges=np.zeros(ms_n, dtype="<i4"),
            base_peak_intensities=np.array(
                [intensity[:ms_pts].max(), intensity[ms_pts:].max()],
                dtype="<f8",
            ),
        )
        g_n = 2
        g_L = 4
        g_run = WrittenGenomicRun(
            acquisition_mode=7,
            reference_uri="GRCh38.p14",
            platform="ILLUMINA",
            sample_name="NA12878",
            positions=np.array([100, 200], dtype=np.int64),
            mapping_qualities=np.full(g_n, 60, dtype=np.uint8),
            flags=np.full(g_n, 0x0003, dtype=np.uint32),
            sequences=np.frombuffer(b"ACGT" * g_n, dtype=np.uint8),
            qualities=np.frombuffer(bytes([30] * (g_n * g_L)), dtype=np.uint8),
            offsets=np.arange(g_n, dtype=np.uint64) * g_L,
            lengths=np.full(g_n, g_L, dtype=np.uint32),
            cigars=[f"{g_L}M"] * g_n,
            read_names=[f"r{i}" for i in range(g_n)],
            mate_chromosomes=[""] * g_n,
            mate_positions=np.full(g_n, -1, dtype=np.int64),
            template_lengths=np.zeros(g_n, dtype=np.int32),
            chromosomes=["chr1", "chr2"],
        )
        path = tmp_path / "mux.tio"
        SpectralDataset.write_minimal(
            path,
            title="M90.8 mux fixture",
            isa_investigation_id="ISA-M90-8-MUX",
            runs={"run_0001": ms_run},
            genomic_runs={"genomic_0001": g_run},
        )
        encrypt_per_au_file(str(path), KEY)

        # Stream through encrypted transport.
        stream = io.BytesIO()
        with TransportWriter(stream) as tw:
            write_encrypted_dataset(tw, str(path))
        stream.seek(0)
        out_path = tmp_path / "rt.tio"
        meta = read_encrypted_to_file(stream, out_path)
        assert "run_0001" in meta["runs"]
        assert "genomic_0001" in meta["runs"]

        # Decrypt + verify both modalities.
        plain = decrypt_per_au_file(str(out_path), KEY)
        np.testing.assert_array_equal(plain["run_0001"]["mz"], mz)
        np.testing.assert_array_equal(plain["run_0001"]["intensity"], intensity)
        np.testing.assert_array_equal(
            plain["genomic_0001"]["sequences"],
            np.frombuffer(b"ACGT" * g_n, dtype=np.uint8),
        )
