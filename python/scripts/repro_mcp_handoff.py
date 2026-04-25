"""Reproducer for handoff-from-mcp-server-m5-encryption.md.

Run with the in-tree venv:

    cd /home/toddw/TTI-O/python && source .venv/bin/activate
    python scripts/repro_mcp_handoff.py

Walks Issue A (is_encrypted lost on reopen) and Issue B (intensity_array
unreadable after decrypt_with_key). Reports PASS/FAIL per assertion
rather than aborting on the first failure, so we see the full picture.
"""
from __future__ import annotations

import os
import tempfile

import numpy as np

from ttio import AcquisitionMode, SpectralDataset, WrittenRun
from ttio.enums import EncryptionLevel


def _report(label: str, ok: bool, extra: str = "") -> None:
    status = "PASS" if ok else "FAIL"
    suffix = f"  [{extra}]" if extra else ""
    print(f"  {status}: {label}{suffix}")


def main() -> None:
    with tempfile.TemporaryDirectory() as td:
        p = os.path.join(td, "enc.tio")
        n, m = 5, 4
        rng = np.random.default_rng(1)
        run = WrittenRun(
            spectrum_class="TTIOMassSpectrum",
            acquisition_mode=int(AcquisitionMode.MS1_DDA),
            channel_data={
                "mz": np.tile(np.linspace(100, 200, m), n).astype(np.float64),
                "intensity": rng.uniform(0, 1e6, n * m).astype(np.float64),
            },
            offsets=(np.arange(n, dtype=np.uint64) * m),
            lengths=np.full(n, m, dtype=np.uint32),
            retention_times=np.linspace(0, 1, n),
            ms_levels=np.ones(n, dtype=np.int32),
            polarities=np.ones(n, dtype=np.int32),
            precursor_mzs=np.zeros(n),
            precursor_charges=np.zeros(n, dtype=np.int32),
            base_peak_intensities=np.zeros(n),
        )
        SpectralDataset.write_minimal(
            p,
            title="t",
            isa_investigation_id="I",
            runs={"r1": run},
        )

        print("Issue A — is_encrypted / encrypted_algorithm persistence")
        ds = SpectralDataset.open(p, writable=True)
        ds.encrypt_with_key(b"0" * 32, level=EncryptionLevel.DATASET_GROUP)
        _report("is_encrypted == True immediately after encrypt", ds.is_encrypted,
                f"actual={ds.is_encrypted}")
        _report(
            "encrypted_algorithm non-empty immediately after encrypt",
            bool(ds.encrypted_algorithm),
            f"actual={ds.encrypted_algorithm!r}",
        )
        ds.close()

        ds2 = SpectralDataset.open(p)
        _report("is_encrypted == True after reopen", ds2.is_encrypted,
                f"actual={ds2.is_encrypted}")
        _report(
            "encrypted_algorithm non-empty after reopen",
            bool(ds2.encrypted_algorithm),
            f"actual={ds2.encrypted_algorithm!r}",
        )

        print()
        print("Issue B — decrypted intensity_array accessible via normal API")
        ret = ds2.decrypt_with_key(b"0" * 32)
        _report("decrypt_with_key returns a mapping", isinstance(ret, dict))
        # Option 1 of the handoff keeps the `dict[str, bytes]` return shape
        # and rehydrates the in-memory dataset; the value-type check below
        # is informational, not an acceptance gate.
        _report(
            "decrypt_with_key values are bytes or ndarray",
            all(isinstance(v, (bytes, np.ndarray)) for v in ret.values()),
            f"actual types={ {k: type(v).__name__ for k, v in ret.items()} }",
        )
        run2 = ds2.all_runs.get("r1")
        try:
            spec = run2.object_at_index(0)
            arr = spec.intensity_array
            _report(
                "spec.intensity_array accessible after decrypt_with_key",
                arr is not None and len(arr.data) > 0,
                f"len={len(arr.data) if arr is not None else 'n/a'}",
            )
        except Exception as exc:
            _report(
                "spec.intensity_array accessible after decrypt_with_key",
                False,
                f"raised {type(exc).__name__}: {exc}",
            )
        ds2.close()


if __name__ == "__main__":
    main()
