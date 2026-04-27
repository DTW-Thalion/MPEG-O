"""M90.1: per-AU encryption on genomic signal channels.

Extends the file-level per-AU AES-256-GCM encryption (M48-M71 wired
for MS) to also walk /study/genomic_runs/<name>/signal_channels/.
After encryption the plaintext sequences_values / qualities_values
datasets are gone, replaced by *_segments compounds; decrypt_per_au
materialises them back to uint8 numpy arrays.

Genomic runs share the same dataset_id space as MS runs (1..N for
MS, N+1..N+M for genomic) — matches the M89.2 transport convention.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

pytest.importorskip("cryptography")
pytest.importorskip("h5py")

from ttio import SpectralDataset
from ttio.encryption_per_au import decrypt_per_au_file, encrypt_per_au_file
from ttio.written_genomic_run import WrittenGenomicRun


KEY = b"\x42" * 32  # 256-bit test key


def _make_genomic_dataset(path: Path) -> Path:
    """Write a small genomic-only .tio for M90.1 round-trip testing."""
    n_reads = 4
    read_length = 8
    sequences = np.frombuffer(b"ACGTACGT" * n_reads, dtype=np.uint8)
    qualities = np.frombuffer(bytes([30] * (n_reads * read_length)), dtype=np.uint8)
    run = WrittenGenomicRun(
        acquisition_mode=7,  # GENOMIC_WGS
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="NA12878",
        positions=np.array([100, 200, 300, 400], dtype=np.int64),
        mapping_qualities=np.full(n_reads, 60, dtype=np.uint8),
        flags=np.array([0x0003, 0x0003, 0x0003, 0x0003], dtype=np.uint32),
        sequences=sequences,
        qualities=qualities,
        offsets=np.arange(n_reads, dtype=np.uint64) * read_length,
        lengths=np.full(n_reads, read_length, dtype=np.uint32),
        cigars=[f"{read_length}M"] * n_reads,
        read_names=[f"read_{i:03d}" for i in range(n_reads)],
        mate_chromosomes=[""] * n_reads,
        mate_positions=np.full(n_reads, -1, dtype=np.int64),
        template_lengths=np.zeros(n_reads, dtype=np.int32),
        chromosomes=["chr1", "chr1", "chr2", "chr2"],
    )
    SpectralDataset.write_minimal(
        path,
        title="M90.1 genomic encryption fixture",
        isa_investigation_id="ISA-M90-1",
        runs={},
        genomic_runs={"genomic_0001": run},
    )
    return path


class TestGenomicPerAuRoundTrip:

    def test_encrypt_strips_plaintext_signal_channels(self, tmp_path):
        path = _make_genomic_dataset(tmp_path / "src.tio")
        encrypt_per_au_file(str(path), KEY)
        # The plaintext _values datasets should be gone; *_segments
        # compounds should be present in their place.
        import h5py
        with h5py.File(path, "r") as f:
            sig = f["/study/genomic_runs/genomic_0001/signal_channels"]
            for cname in ("sequences", "qualities"):
                assert f"{cname}_values" not in sig, (
                    f"plaintext {cname}_values not stripped after encrypt"
                )
                assert f"{cname}_segments" in sig, (
                    f"{cname}_segments compound not written"
                )
                algo = sig.attrs.get(f"{cname}_algorithm")
                if isinstance(algo, bytes):
                    algo = algo.decode()
                assert algo == "aes-256-gcm"

    def test_round_trip_recovers_byte_exact_plaintext(self, tmp_path):
        path = _make_genomic_dataset(tmp_path / "rt.tio")
        encrypt_per_au_file(str(path), KEY)
        plaintext = decrypt_per_au_file(str(path), KEY)
        assert "genomic_0001" in plaintext, (
            f"genomic_0001 missing; got: {sorted(plaintext.keys())}"
        )
        run = plaintext["genomic_0001"]
        # Sequences round-trip byte-exact (uint8).
        np.testing.assert_array_equal(
            run["sequences"],
            np.frombuffer(b"ACGTACGT" * 4, dtype=np.uint8),
        )
        # Qualities round-trip byte-exact (uint8).
        np.testing.assert_array_equal(
            run["qualities"],
            np.full(32, 30, dtype=np.uint8),
        )

    def test_wrong_key_fails(self, tmp_path):
        path = _make_genomic_dataset(tmp_path / "wk.tio")
        encrypt_per_au_file(str(path), KEY)
        with pytest.raises(Exception):
            # Either InvalidTag (cryptography) or a wrapping ValueError;
            # both indicate AES-GCM rejected the wrong key.
            decrypt_per_au_file(str(path), b"\xFF" * 32)

    def test_dataset_id_disjoint_from_ms(self, tmp_path):
        """When a file has both an MS run and a genomic run, the
        genomic run gets dataset_id=2 (MS=1). The AAD for genomic
        AUs must use dataset_id=2 so encrypt+decrypt stay
        symmetric. Tests this by encrypting a mixed file and
        confirming round-trip succeeds — wrong-AAD failures show
        up as InvalidTag exceptions during decrypt."""
        # Build a tiny multiplexed fixture.
        from ttio.spectral_dataset import WrittenRun
        from ttio.enums import AcquisitionMode, Polarity

        path = tmp_path / "mux.tio"
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
        # Build the genomic run inline (smaller than the helper).
        g_n = 2
        g_len = 4
        g_run = WrittenGenomicRun(
            acquisition_mode=7,
            reference_uri="GRCh38.p14",
            platform="ILLUMINA",
            sample_name="NA12878",
            positions=np.array([100, 200], dtype=np.int64),
            mapping_qualities=np.full(g_n, 60, dtype=np.uint8),
            flags=np.array([0x0003, 0x0003], dtype=np.uint32),
            sequences=np.frombuffer(b"ACGT" * g_n, dtype=np.uint8),
            qualities=np.frombuffer(bytes([30] * (g_n * g_len)), dtype=np.uint8),
            offsets=np.arange(g_n, dtype=np.uint64) * g_len,
            lengths=np.full(g_n, g_len, dtype=np.uint32),
            cigars=[f"{g_len}M"] * g_n,
            read_names=[f"r{i}" for i in range(g_n)],
            mate_chromosomes=[""] * g_n,
            mate_positions=np.full(g_n, -1, dtype=np.int64),
            template_lengths=np.zeros(g_n, dtype=np.int32),
            chromosomes=["chr1", "chr2"],
        )
        SpectralDataset.write_minimal(
            path,
            title="M90.1 mux fixture",
            isa_investigation_id="ISA-M90-MUX",
            runs={"run_0001": ms_run},
            genomic_runs={"genomic_0001": g_run},
        )
        encrypt_per_au_file(str(path), KEY)
        plaintext = decrypt_per_au_file(str(path), KEY)
        # Both runs should decrypt cleanly.
        assert "run_0001" in plaintext
        assert "genomic_0001" in plaintext
        np.testing.assert_array_equal(plaintext["run_0001"]["mz"], mz)
        np.testing.assert_array_equal(
            plaintext["genomic_0001"]["sequences"],
            np.frombuffer(b"ACGT" * g_n, dtype=np.uint8),
        )
