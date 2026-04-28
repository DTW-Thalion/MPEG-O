"""M90.12: uint8-aware MPAD format in per_au_cli.

Closes gap #6 from the post-M90 analysis. The pre-M90.12 MPAD format
cast every channel to float64 — fine for MS (already float64), but
inflates uint8 genomic sequences/qualities 8x, blocking the literal
3x3 cross-language matrix on genomic data.

M90.12 bumps the magic from "MPAD" to "MPA1" and adds a per-entry
dtype code (mirrors the existing Precision enum: 0=f4, 1=f8, 2=i4,
3=i8, 4=u4, 6=u1, 9=u8). Reader infers per-element width from the
dtype code; writer no longer pre-casts.

Backward compat: pre-M90.12 MPAD readers fail at the magic check.
The only consumers are the per-AU cross-language test harnesses
(controlled within this repo); a coordinated bump is acceptable.
"""
from __future__ import annotations

import io as _io
import shutil
import struct
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

pytest.importorskip("cryptography")
pytest.importorskip("h5py")

from ttio import SpectralDataset
from ttio.encryption_per_au import encrypt_per_au_file
from ttio.spectral_dataset import WrittenRun
from ttio.enums import AcquisitionMode, Polarity
from ttio.written_genomic_run import WrittenGenomicRun


KEY = b"\x77" * 32
MPAD_V1_MAGIC = b"MPA1"


def _key_file(tmp_path: Path) -> Path:
    p = tmp_path / "key.bin"
    p.write_bytes(KEY)
    return p


def _make_ms_dataset(path: Path) -> Path:
    n = 3
    n_pts = 4
    mz = np.tile(np.linspace(100.0, 200.0, n_pts), n).astype(np.float64)
    intensity = (np.arange(n * n_pts, dtype=np.float64) + 1.0) * 1000.0
    run = WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": mz, "intensity": intensity},
        offsets=np.arange(n, dtype=np.uint64) * n_pts,
        lengths=np.full(n, n_pts, dtype=np.uint32),
        retention_times=np.linspace(0.0, 4.0, n),
        ms_levels=np.ones(n, dtype=np.int32),
        polarities=np.full(n, int(Polarity.POSITIVE), dtype=np.int32),
        precursor_mzs=np.zeros(n),
        precursor_charges=np.zeros(n, dtype=np.int32),
        base_peak_intensities=intensity.reshape(n, n_pts).max(axis=1),
    )
    SpectralDataset.write_minimal(
        path, title="x", isa_investigation_id="x",
        runs={"run_0001": run},
    )
    return path


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
        read_names=[f"r{i:03d}" for i in range(n)],
        mate_chromosomes=[""] * n,
        mate_positions=np.full(n, -1, dtype=np.int64),
        template_lengths=np.zeros(n, dtype=np.int32),
        chromosomes=["chr1", "chr1", "chr2", "chr2"],
    )
    SpectralDataset.write_minimal(
        path, title="x", isa_investigation_id="x",
        runs={}, genomic_runs={"genomic_0001": run},
    )
    return path


def _run_cli(*args: str) -> None:
    proc = subprocess.run(
        [sys.executable, "-m", "ttio.tools.per_au_cli", *args],
        capture_output=True, text=True, timeout=60,
    )
    if proc.returncode != 0:
        pytest.fail(f"per_au_cli {' '.join(args)} exit "
                     f"{proc.returncode}: {proc.stderr.strip()}")


def _parse_mpad_v1(raw: bytes) -> list[tuple[str, int, bytes]]:
    """Return [(key, dtype_code, value_bytes), ...]. Asserts the new
    "MPA1" magic."""
    assert raw[:4] == MPAD_V1_MAGIC, (
        f"expected MPAD v1 magic 'MPA1', got {raw[:4]!r}"
    )
    (n,) = struct.unpack_from("<I", raw, 4)
    off = 8
    out: list[tuple[str, int, bytes]] = []
    for _ in range(n):
        (klen,) = struct.unpack_from("<H", raw, off); off += 2
        key = raw[off:off + klen].decode("utf-8"); off += klen
        dtype_code = raw[off]; off += 1
        (vlen,) = struct.unpack_from("<I", raw, off); off += 4
        value = raw[off:off + vlen]; off += vlen
        out.append((key, dtype_code, value))
    return out


class TestMsRoundTrip:
    """MS still works — float64 channels stay float64 (dtype code 1)."""

    def test_ms_decrypt_emits_v1_with_float64(self, tmp_path):
        src = _make_ms_dataset(tmp_path / "src.tio")
        enc = tmp_path / "enc.tio"
        shutil.copyfile(src, enc)
        encrypt_per_au_file(str(enc), KEY)
        keyf = _key_file(tmp_path)
        out = tmp_path / "out.mpad"
        _run_cli("decrypt", str(enc), str(out), str(keyf))
        entries = _parse_mpad_v1(out.read_bytes())
        # Two entries: run_0001__mz, run_0001__intensity. Both float64.
        names = {k for k, _, _ in entries}
        assert "run_0001__mz" in names
        assert "run_0001__intensity" in names
        for key, dtype_code, value in entries:
            assert dtype_code == 1, (  # FLOAT64
                f"{key}: expected dtype 1 (float64), got {dtype_code}"
            )
            assert len(value) % 8 == 0
        # Decoded mz matches source.
        for key, _, value in entries:
            if key == "run_0001__mz":
                arr = np.frombuffer(value, dtype="<f8")
                np.testing.assert_array_almost_equal(
                    arr,
                    np.tile(np.linspace(100.0, 200.0, 4), 3),
                )


class TestGenomicRoundTrip:
    """Genomic uint8 channels now ride as uint8 (dtype code 6) instead
    of being inflated to float64."""

    def test_genomic_decrypt_emits_uint8_for_sequences(self, tmp_path):
        src = _make_genomic_dataset(tmp_path / "src.tio")
        enc = tmp_path / "enc.tio"
        shutil.copyfile(src, enc)
        encrypt_per_au_file(str(enc), KEY)
        keyf = _key_file(tmp_path)
        out = tmp_path / "out.mpad"
        _run_cli("decrypt", str(enc), str(out), str(keyf))
        entries = _parse_mpad_v1(out.read_bytes())
        seq_entry = next(
            (e for e in entries if e[0] == "genomic_0001__sequences"), None,
        )
        assert seq_entry is not None
        key, dtype_code, value = seq_entry
        assert dtype_code == 6, (  # UINT8
            f"sequences: expected dtype 6 (uint8), got {dtype_code}"
        )
        # 4 reads × 8 bases = 32 bytes. NOT 32 × 8 = 256 (the pre-M90.12
        # float64-cast bug).
        assert len(value) == 32
        assert value == b"ACGTACGT" * 4

    def test_genomic_qualities_are_uint8(self, tmp_path):
        src = _make_genomic_dataset(tmp_path / "src.tio")
        enc = tmp_path / "enc.tio"
        shutil.copyfile(src, enc)
        encrypt_per_au_file(str(enc), KEY)
        keyf = _key_file(tmp_path)
        out = tmp_path / "out.mpad"
        _run_cli("decrypt", str(enc), str(out), str(keyf))
        entries = _parse_mpad_v1(out.read_bytes())
        q_entry = next(
            (e for e in entries if e[0] == "genomic_0001__qualities"), None,
        )
        assert q_entry is not None
        _, dtype_code, value = q_entry
        assert dtype_code == 6
        assert len(value) == 32
        assert value == bytes([30] * 32)


class TestMixedRoundTrip:
    """Mixed MS + genomic dataset — MS entries get float64 (1),
    genomic entries get uint8 (6), in the same MPAD."""

    def test_mixed_dtype_codes(self, tmp_path):
        # Build a mixed file inline.
        path = tmp_path / "mixed.tio"
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
        SpectralDataset.write_minimal(
            path, title="x", isa_investigation_id="x",
            runs={"run_0001": ms_run},
            genomic_runs={"genomic_0001": g_run},
        )
        encrypt_per_au_file(str(path), KEY)
        keyf = _key_file(tmp_path)
        out = tmp_path / "out.mpad"
        _run_cli("decrypt", str(path), str(out), str(keyf))
        entries = _parse_mpad_v1(out.read_bytes())
        by_key = {k: (dt, v) for k, dt, v in entries}
        # MS channels: float64 (dtype code 1).
        assert by_key["run_0001__mz"][0] == 1
        assert by_key["run_0001__intensity"][0] == 1
        # Genomic channels: uint8 (dtype code 6).
        assert by_key["genomic_0001__sequences"][0] == 6
        assert by_key["genomic_0001__qualities"][0] == 6
