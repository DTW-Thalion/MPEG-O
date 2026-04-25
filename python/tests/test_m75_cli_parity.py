"""M75 Python CLI parity — smoke tests for ttio-sign, ttio-verify, ttio-pqc.

Covers:

1. ``[project.scripts]`` entry points are declared and resolve to the
   ``main`` callable in each CLI module (no subprocess needed).
2. ``ttio-sign`` + ``ttio-verify`` round-trip via ``python -m`` on a
   minimal ``.tio`` fixture (no PATH lookup, always portable).
3. ``ttio-verify`` reports ``INVALID`` on a tampered signature and
   ``NOT_SIGNED`` on an unsigned dataset.
4. ``ttio-pqc`` sig-keygen + sig-sign + sig-verify round-trip, gated
   on the ``[pqc]`` extra being installed.

The console-script entry points exercised here are the Python
counterparts of the Objective-C ``TtioVerify`` / ``TtioSign`` /
``TtioPQCTool`` and Java ``TtioVerify`` / ``PQCTool`` binaries. M75
closes that surface gap.
"""
from __future__ import annotations

import importlib.metadata
import importlib.util
import subprocess
import sys
from pathlib import Path

import h5py
import numpy as np
import pytest

from ttio import SpectralDataset, WrittenRun
from ttio.enums import AcquisitionMode


FIXTURE_KEY = bytes((0xA5 ^ (i * 3)) & 0xFF for i in range(32))
FIXTURE_KEY_HEX = FIXTURE_KEY.hex()
DATASET_PATH = "/study/ms_runs/run_0001/signal_channels/intensity_values"


def _build_written_run() -> WrittenRun:
    n_spec, n_pts = 3, 6
    offsets = np.arange(n_spec, dtype=np.uint64) * n_pts
    lengths = np.full(n_spec, n_pts, dtype=np.uint32)
    mz = np.tile(np.linspace(100.0, 200.0, n_pts), n_spec).astype(np.float64)
    intensity = np.tile(np.linspace(1.0, 10.0, n_pts), n_spec).astype(np.float64)
    return WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": mz, "intensity": intensity},
        offsets=offsets,
        lengths=lengths,
        retention_times=np.linspace(0.0, 2.0, n_spec, dtype=np.float64),
        ms_levels=np.ones(n_spec, dtype=np.int32),
        polarities=np.ones(n_spec, dtype=np.int32),
        precursor_mzs=np.zeros(n_spec, dtype=np.float64),
        precursor_charges=np.zeros(n_spec, dtype=np.int32),
        base_peak_intensities=np.full(n_spec, 10.0, dtype=np.float64),
    )


def _make_fixture(path: Path) -> None:
    SpectralDataset.write_minimal(
        path, title="m75", isa_investigation_id="TTIO:m75",
        runs={"run_0001": _build_written_run()},
    )


def _run(*args: str, expect_ok: bool = False) -> subprocess.CompletedProcess:
    """Invoke a CLI entry module via ``python -m``.

    Subprocess keeps the tests hermetic regardless of whether the
    distribution is installed editably or as a wheel.
    """
    proc = subprocess.run(
        [sys.executable, "-m", *args],
        capture_output=True, text=True,
    )
    if expect_ok and proc.returncode != 0:
        pytest.fail(
            f"command failed ({proc.returncode}): "
            f"{' '.join(args)}\n  stdout: {proc.stdout}\n  stderr: {proc.stderr}"
        )
    return proc


# ─── entry-point resolution ──────────────────────────────────────────────


@pytest.mark.parametrize("name,target", [
    ("ttio-sign",   "ttio.tools.ttio_sign_cli:main"),
    ("ttio-verify", "ttio.tools.ttio_verify_cli:main"),
    ("ttio-pqc",    "ttio.tools.ttio_pqc_cli:main"),
])
def test_console_script_entry_point_resolves(name: str, target: str) -> None:
    """Each entry point is declared in ``[project.scripts]`` and loads
    without ImportError."""
    try:
        eps = importlib.metadata.entry_points(group="console_scripts",
                                                 name=name)
    except TypeError:  # pragma: no cover — Python < 3.10 compat
        eps = [ep for ep in importlib.metadata.entry_points()
                ["console_scripts"] if ep.name == name]
    eps = list(eps)
    assert eps, f"missing console_scripts entry for {name!r}"
    ep = eps[0]
    assert ep.value == target, f"{name} points at {ep.value}, expected {target}"
    main = ep.load()
    assert callable(main)


# ─── ttio-sign + ttio-verify round-trip ──────────────────────────────────


def test_sign_verify_roundtrip(tmp_path: Path) -> None:
    fixture = tmp_path / "m75.tio"
    _make_fixture(fixture)

    sign = _run(
        "ttio.tools.ttio_sign_cli",
        str(fixture), DATASET_PATH, FIXTURE_KEY_HEX,
        expect_ok=True,
    )
    assert sign.returncode == 0

    verify = _run(
        "ttio.tools.ttio_verify_cli",
        str(fixture), DATASET_PATH, FIXTURE_KEY_HEX,
    )
    assert verify.returncode == 0, verify.stderr
    assert verify.stdout.strip() == "VALID"


def test_verify_invalid_on_wrong_key(tmp_path: Path) -> None:
    fixture = tmp_path / "m75_invalid.tio"
    _make_fixture(fixture)
    _run("ttio.tools.ttio_sign_cli",
          str(fixture), DATASET_PATH, FIXTURE_KEY_HEX, expect_ok=True)

    wrong_key_hex = ("00" * 32)
    verify = _run(
        "ttio.tools.ttio_verify_cli",
        str(fixture), DATASET_PATH, wrong_key_hex,
    )
    assert verify.returncode == 1
    assert verify.stdout.strip() == "INVALID"


def test_verify_not_signed(tmp_path: Path) -> None:
    fixture = tmp_path / "m75_unsigned.tio"
    _make_fixture(fixture)
    verify = _run(
        "ttio.tools.ttio_verify_cli",
        str(fixture), DATASET_PATH, FIXTURE_KEY_HEX,
    )
    assert verify.returncode == 2
    assert verify.stdout.strip() == "NOT_SIGNED"


def test_sign_rejects_non_hex_key(tmp_path: Path) -> None:
    fixture = tmp_path / "m75_bad_key.tio"
    _make_fixture(fixture)
    proc = _run(
        "ttio.tools.ttio_sign_cli",
        str(fixture), DATASET_PATH, "not-hex-" + "0" * 56,
    )
    assert proc.returncode != 0


def test_sign_rejects_missing_dataset(tmp_path: Path) -> None:
    fixture = tmp_path / "m75_no_ds.tio"
    _make_fixture(fixture)
    proc = _run(
        "ttio.tools.ttio_sign_cli",
        str(fixture), "/does/not/exist", FIXTURE_KEY_HEX,
    )
    assert proc.returncode == 1


# ─── ttio-pqc round-trip (gated on [pqc] extra) ──────────────────────────


skip_no_pqc = pytest.mark.skipif(
    importlib.util.find_spec("oqs") is None,
    reason="liboqs-python not installed ([pqc] extra)",
)


@skip_no_pqc
def test_pqc_sig_roundtrip(tmp_path: Path) -> None:
    pk = tmp_path / "pk.bin"
    sk = tmp_path / "sk.bin"
    msg = tmp_path / "msg.bin"
    sig = tmp_path / "sig.bin"
    msg.write_bytes(b"m75 python cli parity")

    _run("ttio.tools.ttio_pqc_cli",
          "sig-keygen", str(pk), str(sk), expect_ok=True)
    _run("ttio.tools.ttio_pqc_cli",
          "sig-sign", str(sk), str(msg), str(sig), expect_ok=True)
    proc = _run("ttio.tools.ttio_pqc_cli",
                 "sig-verify", str(pk), str(msg), str(sig))
    assert proc.returncode == 0

    bad_sig = tmp_path / "sig_bad.bin"
    bad_sig.write_bytes(b"\x00" * sig.stat().st_size)
    proc = _run("ttio.tools.ttio_pqc_cli",
                 "sig-verify", str(pk), str(msg), str(bad_sig))
    assert proc.returncode == 1


@skip_no_pqc
def test_pqc_kem_roundtrip(tmp_path: Path) -> None:
    pk = tmp_path / "pk.bin"
    sk = tmp_path / "sk.bin"
    ct = tmp_path / "ct.bin"
    ss_enc = tmp_path / "ss_enc.bin"
    ss_dec = tmp_path / "ss_dec.bin"

    _run("ttio.tools.ttio_pqc_cli",
          "kem-keygen", str(pk), str(sk), expect_ok=True)
    _run("ttio.tools.ttio_pqc_cli",
          "kem-encaps", str(pk), str(ct), str(ss_enc), expect_ok=True)
    _run("ttio.tools.ttio_pqc_cli",
          "kem-decaps", str(sk), str(ct), str(ss_dec), expect_ok=True)
    assert ss_enc.read_bytes() == ss_dec.read_bytes()


@skip_no_pqc
def test_pqc_hdf5_sign_verify(tmp_path: Path) -> None:
    fixture = tmp_path / "m75_pqc.tio"
    _make_fixture(fixture)
    pk = tmp_path / "pk.bin"
    sk = tmp_path / "sk.bin"
    _run("ttio.tools.ttio_pqc_cli",
          "sig-keygen", str(pk), str(sk), expect_ok=True)

    _run("ttio.tools.ttio_pqc_cli",
          "hdf5-sign", str(fixture), DATASET_PATH, str(sk), expect_ok=True)
    proc = _run("ttio.tools.ttio_pqc_cli",
                 "hdf5-verify", str(fixture), DATASET_PATH, str(pk))
    assert proc.returncode == 0

    with h5py.File(fixture, "r") as f:
        stored = f[DATASET_PATH].attrs["ttio_signature"]
    assert isinstance(stored, (str, bytes))
    stored_s = stored if isinstance(stored, str) else stored.decode()
    assert stored_s.startswith("v3:")


def test_pqc_unknown_subcommand_exits_2() -> None:
    proc = _run("ttio.tools.ttio_pqc_cli", "bogus-subcmd")
    assert proc.returncode == 2
    assert "unknown subcommand" in proc.stderr


def test_pqc_no_args_exits_2() -> None:
    proc = _run("ttio.tools.ttio_pqc_cli")
    assert proc.returncode == 2
