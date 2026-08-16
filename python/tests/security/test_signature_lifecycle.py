"""Signature lifecycle matrix (v0.9 M61).

6 scenarios × 4 providers = 24 cells covering canonical-bytes
HMAC-SHA256 (v2:) plus provider-aware signing on every backend.

Scenarios (per HANDOFF M61 §"Signature lifecycle"):

* ``test_sign_verify`` — canonical signature round-trip.
* ``test_tamper_detection`` — modifying a single byte invalidates
  the signature.
* ``test_v2_hmac_backward_compat`` — a v0.3 ``v2:``-prefixed
  signature is still verifiable.
* ``test_v3_mldsa_skipped`` — placeholder, ML-DSA-87 cross-provider
  signing is exercised by ``test_m54_1_provider_pqc.py`` already.
* ``test_unsigned_returns_notsigned`` — verifying an unsigned
  dataset returns ``False`` rather than raising.
* ``test_provenance_chain_signing`` — sign + verify the run-level
  provenance hash on every provider.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pytest

from ttio import (
    Identification,
    SpectralDataset,
    WrittenRun,
)
from ttio.signatures import (
    SIGNATURE_ATTR,
    SIGNATURE_V2_PREFIX,
    sign_dataset,
    verify_dataset,
)

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "integration"))
from _provider_matrix import (  # type: ignore[import-not-found]
    PROVIDERS as _PROVIDERS,
    maybe_skip_provider as _maybe_skip_provider,
    provider_url as _provider_url,
)

_KEY = bytes(range(32))


def _build(provider: str, tmp_path: Path) -> str:
    n = 4
    run = WrittenRun(
        spectrum_class="TTIOMassSpectrum", acquisition_mode=0,
        channel_data={
            "mz": np.linspace(100.0, 200.0, n).astype(np.float64),
            "intensity": np.linspace(1.0, 100.0, n).astype(np.float64),
        },
        offsets=np.array([0], dtype=np.uint64),
        lengths=np.array([n], dtype=np.uint32),
        retention_times=np.zeros(1),
        ms_levels=np.ones(1, dtype=np.int32),
        polarities=np.zeros(1, dtype=np.int32),
        precursor_mzs=np.zeros(1),
        precursor_charges=np.zeros(1, dtype=np.int32),
        base_peak_intensities=np.array([100.0]),
    )
    url = _provider_url(provider, tmp_path, "sig")
    SpectralDataset.write_minimal(
        url, title="sig", isa_investigation_id="ISA-SIG",
        runs={"run_0001": run}, provider=provider,
    )
    return url


@pytest.mark.parametrize("provider", _PROVIDERS)
class TestSignatureLifecycle:

    def test_sign_verify(self, provider: str, tmp_path: Path) -> None:
        _maybe_skip_provider(provider)
        url = _build(provider, tmp_path)
        with SpectralDataset.open(url, writable=True) as ds:
            sig_group = ds.ms_runs["run_0001"].group.open_group("signal_channels")
            ds_handle = sig_group.open_dataset("intensity_values")
            sig = sign_dataset(ds_handle, _KEY)
            assert sig.startswith(SIGNATURE_V2_PREFIX)
            assert verify_dataset(ds_handle, _KEY) is True

    def test_tamper_detection(self, provider: str, tmp_path: Path) -> None:
        _maybe_skip_provider(provider)
        url = _build(provider, tmp_path)
        # Sign in one writable session, mutate intensity in a second.
        with SpectralDataset.open(url, writable=True) as ds:
            ds_handle = ds.ms_runs["run_0001"].group.open_group("signal_channels").open_dataset("intensity_values")
            sign_dataset(ds_handle, _KEY)
        with SpectralDataset.open(url, writable=True) as ds:
            ds_handle = ds.ms_runs["run_0001"].group.open_group("signal_channels").open_dataset("intensity_values")
            # Layout-agnostic mutation: the channel is a uint8 FDZ1
            # stream under the codec-17 default and float64 with
            # opt_disable_float_delta; flip one element either way.
            tampered = np.asarray(ds_handle.read()).copy()
            if tampered.dtype == np.uint8:
                tampered[-1] ^= 0xFF
            else:
                tampered[0] = 999999.0
            ds_handle.write(tampered)
        # Verify through the provider directly: a tampered FDZ1 stream
        # no longer decodes, so the eager codec-17 decode inside
        # SpectralDataset.open raises before verify_dataset could run.
        # Signature verification is exactly the check that must still
        # be reachable on a corrupted file.
        from ttio.providers.registry import open_provider
        sp = open_provider(url, provider=provider, mode="r")
        try:
            ds_handle = (sp.root_group().open_group("study")
                         .open_group("ms_runs").open_group("run_0001")
                         .open_group("signal_channels")
                         .open_dataset("intensity_values"))
            assert verify_dataset(ds_handle, _KEY) is False
        finally:
            sp.close()

    def test_v2_hmac_backward_compat(self, provider: str, tmp_path: Path) -> None:
        """Signatures persisted with the v2 prefix verify on read."""
        _maybe_skip_provider(provider)
        url = _build(provider, tmp_path)
        with SpectralDataset.open(url, writable=True) as ds:
            ds_handle = ds.ms_runs["run_0001"].group.open_group("signal_channels").open_dataset("intensity_values")
            stored = sign_dataset(ds_handle, _KEY)
            assert stored.startswith("v2:")
        # Reopen and verify without resigning.
        with SpectralDataset.open(url) as ds:
            ds_handle = ds.ms_runs["run_0001"].group.open_group("signal_channels").open_dataset("intensity_values")
            assert verify_dataset(ds_handle, _KEY) is True

    def test_unsigned_returns_notsigned(self, provider: str, tmp_path: Path) -> None:
        _maybe_skip_provider(provider)
        url = _build(provider, tmp_path)
        with SpectralDataset.open(url) as ds:
            ds_handle = ds.ms_runs["run_0001"].group.open_group("signal_channels").open_dataset("intensity_values")
            assert verify_dataset(ds_handle, _KEY) is False

    def test_provenance_chain_signing(self, provider: str, tmp_path: Path) -> None:
        """Signature primitive works on an arbitrary StorageDataset —
        here we sign the spectrum_index ``lengths`` dataset to stand
        in for provenance-blob signing on every backend.

        v1.10 #10: switched from ``offsets`` to ``lengths`` since
        ``offsets`` is no longer written on disk by default.
        """
        _maybe_skip_provider(provider)
        url = _build(provider, tmp_path)
        with SpectralDataset.open(url, writable=True) as ds:
            idx_group = ds.ms_runs["run_0001"].group.open_group("spectrum_index")
            lengths_ds = idx_group.open_dataset("lengths")
            sig = sign_dataset(lengths_ds, _KEY)
            assert sig.startswith("v2:")
            assert verify_dataset(lengths_ds, _KEY) is True
            assert verify_dataset(lengths_ds, b"\xbb" * 32) is False
