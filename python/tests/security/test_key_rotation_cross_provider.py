"""Cross-provider envelope encryption + key rotation (v0.9 M64.5 phase C).

Extends tests/security/test_protection_cross_provider.py with the
rotate path: enable_envelope_encryption, unwrap_dek, rotate_key,
key_history, has_envelope_encryption — all routed through any
provider. HDF5 keeps the legacy uint8 wrapped-blob layout; Memory /
SQLite / Zarr store the 60-byte AES-GCM blob as a padded UINT32
array (the storage protocol has no UINT8 precision).
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import numpy as np
import pytest

from mpeg_o import SpectralDataset, WrittenRun
from mpeg_o.key_rotation import (
    enable_envelope_encryption,
    has_envelope_encryption,
    key_history,
    rotate_key,
    unwrap_dek,
)

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "integration"))
from _provider_matrix import (  # type: ignore[import-not-found]
    PROVIDERS as _PROVIDERS,
    maybe_skip_provider as _maybe_skip_provider,
    provider_url as _provider_url,
)


def _build_dataset(provider: str, tmp_path: Path) -> str:
    """Write a tiny .mpgo and return a URL suitable for open(writable=True)."""
    n = 4
    run = WrittenRun(
        spectrum_class="MPGOMassSpectrum",
        acquisition_mode=0,
        channel_data={
            "mz": np.linspace(100.0, 200.0, n).astype(np.float64),
            "intensity": np.arange(n, dtype=np.float64),
        },
        offsets=np.array([0], dtype=np.uint64),
        lengths=np.array([n], dtype=np.uint32),
        retention_times=np.zeros(1),
        ms_levels=np.ones(1, dtype=np.int32),
        polarities=np.zeros(1, dtype=np.int32),
        precursor_mzs=np.zeros(1),
        precursor_charges=np.zeros(1, dtype=np.int32),
        base_peak_intensities=np.array([4.0]),
    )
    url = _provider_url(provider, tmp_path, "kr")
    SpectralDataset.write_minimal(
        url, title="kr", isa_investigation_id="ISA-KR",
        runs={"run_0001": run}, provider=provider,
    )
    return url


@pytest.mark.parametrize("provider", _PROVIDERS)
def test_enable_unwrap_roundtrip(provider: str, tmp_path: Path) -> None:
    """A DEK wrapped under KEK-1 unwraps to the same plaintext bytes."""
    _maybe_skip_provider(provider)
    url = _build_dataset(provider, tmp_path)
    kek1 = os.urandom(32)

    with SpectralDataset.open(url, writable=True) as ds:
        assert has_envelope_encryption(ds) is False
        dek = enable_envelope_encryption(ds, kek1, kek_id="kek-1")
        assert len(dek) == 32
        assert has_envelope_encryption(ds) is True
        recovered = unwrap_dek(ds, kek1)
        assert recovered == dek


@pytest.mark.parametrize("provider", _PROVIDERS)
def test_wrong_kek_fails_cleanly(provider: str, tmp_path: Path) -> None:
    """The wrong KEK surfaces the AES-GCM auth failure on every backend."""
    _maybe_skip_provider(provider)
    url = _build_dataset(provider, tmp_path)
    kek1 = os.urandom(32)

    with SpectralDataset.open(url, writable=True) as ds:
        enable_envelope_encryption(ds, kek1, kek_id="kek-1")
        with pytest.raises(Exception):
            unwrap_dek(ds, b"\xaa" * 32)


@pytest.mark.parametrize("provider", _PROVIDERS)
def test_rotate_key_appends_history(provider: str, tmp_path: Path) -> None:
    """After KEK-1 → KEK-2 rotation, only KEK-2 unwraps and the old
    entry lives in key_history."""
    _maybe_skip_provider(provider)
    url = _build_dataset(provider, tmp_path)
    kek1 = os.urandom(32)
    kek2 = os.urandom(32)

    with SpectralDataset.open(url, writable=True) as ds:
        dek = enable_envelope_encryption(ds, kek1, kek_id="kek-1")
        rotate_key(ds, old_kek=kek1, new_kek=kek2, new_kek_id="kek-2")

        # Old KEK no longer authenticates.
        with pytest.raises(Exception):
            unwrap_dek(ds, kek1)

        # New KEK recovers the original DEK.
        assert unwrap_dek(ds, kek2) == dek

        history = key_history(ds)
        assert len(history) == 1
        assert history[0]["kek_id"] == "kek-1"
        assert history[0]["kek_algorithm"] == "aes-256-gcm"
