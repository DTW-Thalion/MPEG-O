"""Cross-provider protection-class round-trip (v0.9 M64.5 phase B).

Lives under ``tests/security/`` (the M61 home for full security
lifecycle suites) but is scoped narrowly to what M64.5 phase B
unblocks: encryption + signature paths route through the
StorageGroup / StorageDataset protocol on every shipping provider.
The 4-provider parametrize uses the existing
:mod:`_provider_matrix` helper so when phase C lands additional
backends the matrix expands automatically.

Anonymizer is exercised via its existing per-policy tests in
``tests/test_milestone28_anonymization.py`` plus the M58 mzML
matrix; the only new wiring there was the ``provider=`` kwarg
passthrough which is covered indirectly by every round-trip.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pytest

from mpeg_o import SpectralDataset, WrittenRun
from mpeg_o.encryption import read_encrypted_channel
from mpeg_o.signatures import sign_dataset, verify_dataset

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "integration"))
from _provider_matrix import (  # type: ignore[import-not-found]
    PROVIDERS as _PROVIDERS,
    maybe_skip_provider as _maybe_skip_provider,
    provider_url as _provider_url,
)


_KEY = bytes(range(32))  # deterministic AES-256 / HMAC-SHA256 key


def _build_dataset(provider: str, tmp_path: Path) -> str:
    """Write a tiny .mpgo on the requested provider and return its URL."""
    n = 8
    mz = np.linspace(100.0, 200.0, n).astype(np.float64)
    intensity = np.linspace(1.0, 100.0, n).astype(np.float64)
    run = WrittenRun(
        spectrum_class="MPGOMassSpectrum",
        acquisition_mode=0,
        channel_data={"mz": mz, "intensity": intensity},
        offsets=np.array([0], dtype=np.uint64),
        lengths=np.array([n], dtype=np.uint32),
        retention_times=np.zeros(1),
        ms_levels=np.ones(1, dtype=np.int32),
        polarities=np.zeros(1, dtype=np.int32),
        precursor_mzs=np.zeros(1),
        precursor_charges=np.zeros(1, dtype=np.int32),
        base_peak_intensities=np.array([100.0]),
    )
    url = _provider_url(provider, tmp_path, "prot")
    SpectralDataset.write_minimal(
        url, title="prot", isa_investigation_id="ISA-PROT",
        runs={"run_0001": run}, provider=provider,
    )
    return url


# --------------------------------------------------------------------------- #
# Encryption round-trip on every provider.
# --------------------------------------------------------------------------- #

@pytest.mark.parametrize("provider", _PROVIDERS)
def test_encrypt_then_decrypt_roundtrip(provider: str, tmp_path: Path) -> None:
    """Encrypt the intensity channel, decrypt it, recover original bytes."""
    _maybe_skip_provider(provider)
    url = _build_dataset(provider, tmp_path)

    expected_intensity = np.linspace(1.0, 100.0, 8).astype(np.float64)

    with SpectralDataset.open(url, writable=True) as ds:
        run = ds.ms_runs["run_0001"]
        run.encrypt_with_key(_KEY, level=0)
        decrypted = run.decrypt_with_key(_KEY)

    arr = np.frombuffer(decrypted, dtype="<f8")
    np.testing.assert_array_equal(arr, expected_intensity)


@pytest.mark.parametrize("provider", _PROVIDERS)
def test_decrypt_with_wrong_key_fails(provider: str, tmp_path: Path) -> None:
    """A wrong key surfaces the AES-GCM auth failure."""
    _maybe_skip_provider(provider)
    url = _build_dataset(provider, tmp_path)

    with SpectralDataset.open(url, writable=True) as ds:
        run = ds.ms_runs["run_0001"]
        run.encrypt_with_key(_KEY, level=0)
        with pytest.raises(Exception):
            run.decrypt_with_key(b"\xaa" * 32)


# --------------------------------------------------------------------------- #
# Signature round-trip on every provider via the storage-protocol shim.
# --------------------------------------------------------------------------- #

@pytest.mark.parametrize("provider", _PROVIDERS)
def test_sign_verify_storage_dataset(provider: str, tmp_path: Path) -> None:
    """Sign a signal channel and verify it, on every provider."""
    _maybe_skip_provider(provider)
    url = _build_dataset(provider, tmp_path)

    with SpectralDataset.open(url, writable=True) as ds:
        sig_group = ds.ms_runs["run_0001"].group.open_group("signal_channels")
        intensity_ds = sig_group.open_dataset("intensity_values")
        signature = sign_dataset(intensity_ds, _KEY)
        assert signature.startswith("v2:")
        assert verify_dataset(intensity_ds, _KEY) is True
        assert verify_dataset(intensity_ds, b"\xaa" * 32) is False
